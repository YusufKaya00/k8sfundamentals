# SRE Incident Post-Mortem & Comprehensive Networking Guide
## Lab 21 — NetCore v5.0 Kubernetes Networking Mesh Root Cause Analysis

---

# 🇬🇧 English Documentation

## Executive Summary
Following the release of **NetCore v5.0**, the entire microservices mesh suffered a total communication breakdown. External requests through Ingress received `502 Bad Gateway` and `404 Not Found`, intra-cluster services reported `Connection Refused` or `Dial Timeout`, cross-namespace authentication failed, and the automated network verification handshake Job failed repeatedly.

This post-mortem details the 10 distinct networking defects embedded in the Kubernetes objects, explains the underlying Linux networking, iptables, CNI, and CoreDNS mechanics, and provides the step-by-step resolution.

---

## Detailed Root Cause Analysis & Resolution

### Fault 1: IngressClass Misconfiguration & Missing Rewrite
* **Affected File:** `helm/netcore/templates/07-ingress.yaml`
* **Symptoms:**
  * External HTTP traffic to `http://<INGRESS_IP>/` or `/api/v1/network/status` fails or returns default 404.
  * Ingress controller logs show the resource is ignored.
* **Linux / K8s Mechanism:**
  * Kubernetes 1.18+ uses `spec.ingressClassName` to bind Ingress manifests to an Ingress Controller instance. Setting `ingressClassName: edge-nginx` causes standard controllers (`ingress-nginx` which listens for `nginx`) to completely ignore the routing rules.
  * The path `/api/v1/network/status` passes the full URI to the backend gateway. Because `netcore-gateway` serves the status page at `/` (or handles subpaths differently), requests without `nginx.ingress.kubernetes.io/rewrite-target: /` fail with 404.
* **Fix:**
  * Change `spec.ingressClassName` to `nginx`.
  * Ensure the rewrite annotation is present:
    ```yaml
    nginx.ingress.kubernetes.io/rewrite-target: /
    ```

---

### Fault 2: Named TargetPort Indirection Mismatch
* **Affected File:** `helm/netcore/templates/05-gateway-deployment.yaml`
* **Symptoms:**
  * `kubectl get endpoints netcore-gateway -n netcore-prod` displays `<none>`.
  * Ingress routes return `503 Service Temporarily Unavailable` because the Service has no healthy endpoints.
* **Linux / K8s Mechanism:**
  * Kubernetes Services support named ports (e.g. `targetPort: http-gateway`). The Endpoints controller resolves the string `http-gateway` against the target Pod's `containerPort` definitions.
  * In `05-gateway-deployment.yaml`, the container port was named `gateway-http`, whereas the Service looked for `http-gateway`.
  * When no containerPort matches the string, the Endpoints controller cannot resolve the integer port number, resulting in 0 active endpoints.
* **Fix:**
  * In `Service/netcore-gateway`, set `targetPort: gateway-http` (or directly integer `8080`).

---

### Fault 3: Zero-Trust NetworkPolicy CoreDNS Egress Block
* **Affected File:** `helm/netcore/templates/06-network-policies.yaml` (`gateway-egress-policy`)
* **Symptoms:**
  * Gateway Pod logs show: `dial tcp: lookup netcore-api.netcore-prod.svc.cluster.local: i/o timeout`.
  * `nslookup` inside the gateway pod hangs for 30 seconds before failing.
* **Linux / K8s Mechanism:**
  * When a `NetworkPolicy` specifies `policyTypes: ["Egress"]`, the CNI (e.g., Azure CNI, Calico, Cilium) places a default DROP rule on all egress connections from selected pods.
  * DNS resolution requires sending UDP (and sometimes TCP) packets to the CoreDNS service IP (`10.0.0.10` or kube-dns) on port 53.
  * Because the policy only allowed egress to port 8000 and 80/443, port 53 packets are silently dropped by kernel iptables/eBPF filter chains.
* **Fix:**
  * Add an egress rule for port 53 UDP and TCP to `kube-system` CoreDNS:
    ```yaml
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
    ```

---

### Fault 4: Cross-Namespace DNS FQDN Missing
* **Affected File:** `helm/netcore/templates/01-config-and-secrets.yaml`
* **Symptoms:**
  * `netcore-gateway` fails to authenticate with `auth-vault`, logging: `dial tcp: lookup auth-vault: no such host`.
* **Linux / K8s Mechanism:**
  * Inside a Pod's `/etc/resolv.conf`, the search domains are configured as:
    `search <namespace>.svc.cluster.local svc.cluster.local cluster.local`
  * When resolving an unqualified short name like `auth-vault`, CoreDNS appends the pod's local namespace (`netcore-prod`).
  * Since `auth-vault` resides in `netcore-secure`, CoreDNS queries `auth-vault.netcore-prod.svc.cluster.local` which does not exist (`NXDOMAIN`).
* **Fix:**
  * In `netcore-gateway-config`, change:
    `GATEWAY_VAULT_ADDR: "http://auth-vault:8443"`
    to:
    `GATEWAY_VAULT_ADDR: "http://auth-vault.netcore-secure.svc.cluster.local:8443"`

---

### Fault 5: Multi-Namespace NetworkPolicy Array Syntax Trap (OR vs AND) & Port Mismatch
* **Affected File:** `helm/netcore/templates/06-network-policies.yaml` (`vault-isolation-policy`)
* **Symptoms:**
  * All HTTP requests from `netcore-gateway` to `auth-vault:8443` hang and time out with `SYN_SENT`.
* **Linux / K8s Mechanism:**
  * In Kubernetes NetworkPolicy YAML:
    ```yaml
    from:
    - namespaceSelector: ...
    - podSelector: ...
    ```
    Having two separate list items (`-`) evaluates as **OR** logic:
    Allow ALL pods from namespace `netcore-prod` OR allow pods labeled `app.kubernetes.io/name: netcore-gateway` in the LOCAL namespace (`netcore-secure`).
    To enforce **AND** (only `netcore-gateway` pods from `netcore-prod`), both selectors must be combined under a SINGLE list item.
  * In addition, the policy allowed port `9443`, but `auth-vault` listens on port `8443`.
* **Fix:**
  * Combine selectors under a single list item and correct the port:
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: netcore-prod
        podSelector:
          matchLabels:
            app.kubernetes.io/name: netcore-gateway
      ports:
      - protocol: TCP
        port: 8443
    ```

---

### Fault 6: Loopback / Localhost Bind Address (`127.0.0.1` vs `0.0.0.0`)
* **Affected File:** `helm/netcore/templates/04-api-deployment.yaml`
* **Symptoms:**
  * `netcore-api` pod is running, but calls to its ClusterIP or Pod IP return `curl: (7) Failed to connect to netcore-api port 8000: Connection refused`.
  * Local exec inside container `curl 127.0.0.1:8000` succeeds!
* **Linux / K8s Mechanism:**
  * When a socket binds to `127.0.0.1`, it only binds to the Linux `lo` (loopback) interface.
  * Incoming packets from other pods or the node route through `eth0` (the veth pair connected to the pod network namespace).
  * The Linux network stack rejects incoming TCP packets arriving on `eth0` destined for `127.0.0.1` with a TCP RST (Reset) packet (`Connection refused`).
* **Fix:**
  * In `Deployment/netcore-api`, change the environment variable:
    `BIND_HOST: "0.0.0.0"`

---

### Fault 7: Layer 4 Transport Protocol Mismatch (UDP vs TCP)
* **Affected File:** `helm/netcore/templates/04-api-deployment.yaml`
* **Symptoms:**
  * Service `netcore-api` exists and has valid endpoints, but HTTP requests to the Service ClusterIP hang and fail.
* **Linux / K8s Mechanism:**
  * The Service port configuration specified `protocol: UDP`.
  * `kube-proxy` writes iptables/IPVS rules specifically matching `protocol udp` for the virtual ClusterIP.
  * HTTP traffic uses TCP. When a TCP SYN packet arrives at the node directed to the ClusterIP, no iptables rule matches, so the packet is dropped or rejected.
* **Fix:**
  * In `Service/netcore-api`, change `protocol: UDP` to `protocol: TCP`.

---

### Fault 8: StatefulSet Headless Service Name Mismatch (DNS Drift)
* **Affected File:** `helm/netcore/templates/02-cache-statefulset.yaml`
* **Symptoms:**
  * `nslookup netcore-cache-0.netcore-cache.netcore-prod.svc.cluster.local` fails.
  * Clustered Redis/Cache cannot form peer discovery.
* **Linux / K8s Mechanism:**
  * A StatefulSet relies on a governing Headless Service (`clusterIP: None`) to assign deterministic network identities to each pod:
    `<pod-name>.<serviceName>.<namespace>.svc.cluster.local`
  * The Headless Service was created with `metadata.name: netcore-cache`.
  * The StatefulSet specified `serviceName: netcore-cache-headless`.
  * CoreDNS only creates DNS SRV and A records for stateful pods when the pod's `serviceName` matches the actual Headless Service name.
* **Fix:**
  * In `StatefulSet/netcore-cache`, update:
    `serviceName: netcore-cache`

---

### Fault 9: `externalTrafficPolicy: Local` on Single-Replica Service
* **Affected File:** `helm/netcore/templates/05-gateway-deployment.yaml`
* **Symptoms:**
  * Intermittent timeouts when accessing the gateway via Ingress or NodePort. Traffic fails from 1 node while succeeding from another.
* **Linux / K8s Mechanism:**
  * `externalTrafficPolicy: Local` instructs kube-proxy to only route traffic to local Pods on the node receiving the packet, preserving client source IP and avoiding extra network hops.
  * If a request lands on a node that does NOT host an instance of `netcore-gateway`, kube-proxy does not forward the packet to other nodes. The packet is dropped.
  * In a multi-node cluster with 1 replica, requests arriving at any other node are blackholed.
* **Fix:**
  * Change `externalTrafficPolicy: Local` to `externalTrafficPolicy: Cluster` (or scale the deployment across all nodes with pod anti-affinity).

---

### Fault 10: DaemonSet Missing NodeSelector & Selector Drift
* **Affected File:** `helm/netcore/templates/08-telemetry-daemonset.yaml`
* **Symptoms:**
  * `kubectl get ds -n netcore-prod` shows `DESIRED: 0, CURRENT: 0, READY: 0`.
  * Service `netcore-telemetry` has `Endpoints: <none>`.
* **Linux / K8s Mechanism:**
  * The DaemonSet spec contained `nodeSelector: network.infrastructure.azure.com/telemetry: "enabled"`.
  * Because standard Kubernetes nodes do not have this arbitrary label, the scheduler matches 0 nodes.
  * In addition, the Service selector was set to `tier: metrics-agent`, but the DaemonSet pod template labels were `app.kubernetes.io/name: netcore-telemetry` and `role: packet-probe`.
* **Fix:**
  * Remove the non-existent `nodeSelector` (or label the nodes).
  * Update the Service selector to match the DaemonSet pod labels:
    ```yaml
    selector:
      app.kubernetes.io/name: netcore-telemetry
      role: packet-probe
    ```

---

# 🇹🇷 Türkçe Dokümantasyon

## Yönetici Özeti (SRE Post-Mortem)
**NetCore v5.0** sürüm dağıtımının hemen ardından, kümedeki tüm mikroservis iletişim hatları koptu. Dış dünyadan Ingress üzerinden gelen istekler `502 Bad Gateway` ve `404 Not Found` ile reddedildi, servisler arası DNS ve TCP bağlantıları `Connection Refused` ve `i/o timeout` hatalarına düştü, cross-namespace kimlik doğrulama çöktü ve otomatik ağ doğrulama Job'ı (`netcore-network-handshake`) başarısız oldu.

Bu kılavuz, mimaride yer alan 10 kritik ağ hatasını, çekirdek Linux ağ katmanını (iptables, CNI, CoreDNS, socket binding) ve bunların kalıcı çözümlerini açıklamaktadır.

---

## Detaylı Kök Neden Analizi ve Çözümler

### Hata 1: Ingress Sınıfı Uyuşmazlığı ve Rewrite Eksikliği
* **İlgili Dosya:** `helm/netcore/templates/07-ingress.yaml`
* **Belirtiler:**
  * Dış IP üzerinden `http://<INGRESS_IP>/` veya `/api/v1/network/status` adresine yapılan istekler 404 döner.
  * Ingress-nginx controller loglarında bu Ingress objesi hiç işlenmez.
* **Ağ Mekanizması:**
  * `spec.ingressClassName: edge-nginx` olarak tanımlanmıştır. Kümedeki standart NGINX Ingress Controller `nginx` sınıfını dinlediği için bu objeyi yok sayar.
  * `/api/v1/network/status` yoluna gelen istekler arkadaki Gateway poduna ham URI olarak iletilir. Podun bu subpath'i karşılayabilmesi için rewrite kuralı gerekir.
* **Çözüm:**
  * `spec.ingressClassName: nginx` yap.
  * `nginx.ingress.kubernetes.io/rewrite-target: /` annotation'ını ekle.

---

### Hata 2: İsimlendirilmiş Port (Named TargetPort) Uyuşmazlığı
* **İlgili Dosya:** `helm/netcore/templates/05-gateway-deployment.yaml`
* **Belirtiler:**
  * `kubectl get endpoints netcore-gateway -n netcore-prod` komutu `<none>` gösterir.
  * Ingress `503 Service Temporarily Unavailable` döner.
* **Ağ Mekanizması:**
  * Kubernetes Service objesi `targetPort: http-gateway` beklemektedir.
  * Ancak Deployment pod şablonunda container portunun adı `gateway-http` olarak verilmiştir.
  * Endpoints Controller bu iki ismi eşleştiremediği için Pod IP'sini Service arkasına bağlayamaz.
* **Çözüm:**
  * `Service/netcore-gateway` içinde `targetPort: gateway-http` (veya direkt `8080`) olarak düzelt.

---

### Hata 3: Zero-Trust NetworkPolicy CoreDNS Port 53 Egress Engeli
* **İlgili Dosya:** `helm/netcore/templates/06-network-policies.yaml` (`gateway-egress-policy`)
* **Belirtiler:**
  * Gateway podu `dial tcp: lookup netcore-api...: i/o timeout` hatası verir. Pod içinde hiçbir DNS kaydı çözülemez.
* **Ağ Mekanizması:**
  * `policyTypes: ["Egress"]` tanımlandığı anda CNI (Azure CNI, Calico) podun tüm dışarı giden paketlerini varsayılan olarak DROP eder.
  * Çıkış kurallarında CoreDNS'in çalıştığı 53 numaralı UDP ve TCP portuna izin verilmediği için DNS sorguları sessizce düşürülür.
* **Çözüm:**
  * `gateway-egress-policy` içine port 53 (UDP ve TCP) egress kuralını ekle:
    ```yaml
    - to:
      - namespaceSelector: {}
      ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
    ```

---

### Hata 4: Farklı Namespace İletişiminde Kısa İsim (FQDN Eksikliği)
* **İlgili Dosya:** `helm/netcore/templates/01-config-and-secrets.yaml`
* **Belirtiler:**
  * `netcore-gateway` podu `auth-vault` servisine erişemez (`no such host`).
* **Ağ Mekanizması:**
  * Pod `/etc/resolv.conf` dosyasında varsayılan olarak podun kendi namespace'i aranır (`netcore-prod.svc.cluster.local`).
  * `auth-vault` servisi `netcore-secure` namespace'inde olduğu için kısa isim (`http://auth-vault:8443`) bulunamaz.
* **Çözüm:**
  * `GATEWAY_VAULT_ADDR` değerini FQDN formatına çevir:
    `http://auth-vault.netcore-secure.svc.cluster.local:8443`

---

### Hata 5: NetworkPolicy Liste Dizilimi (OR vs AND) ve Port Yanlışlığı
* **İlgili Dosya:** `helm/netcore/templates/06-network-policies.yaml` (`vault-isolation-policy`)
* **Belirtiler:**
  * Gateway'den Vault servisine giden istekler `SYN_SENT` aşamasında takılır.
* **Ağ Mekanizması:**
  * `from` altında iki ayrı `-` kullanıldığında kural **VEYA (OR)** mantığıyla çalışır. İstenen "netcore-prod namespace'indeki netcore-gateway podu" kuralını (**VE / AND**) uygulamak için iki seçici tek bir tire altında toplanmalıdır.
  * Ayrıca kuralda port `9443` yazılmıştır ancak Vault servisi `8443` portunu dinlemektedir.
* **Çözüm:**
  * Seçicileri tek liste elemanında birleştir ve portu `8443` yap:
    ```yaml
    ingress:
    - from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: netcore-prod
        podSelector:
          matchLabels:
            app.kubernetes.io/name: netcore-gateway
      ports:
      - protocol: TCP
        port: 8443
    ```

---

### Hata 6: Loopback / Localhost Bind Tuzağı (`127.0.0.1` vs `0.0.0.0`)
* **İlgili Dosya:** `helm/netcore/templates/04-api-deployment.yaml`
* **Belirtiler:**
  * Pod `Running` görünür, podun içine girip `curl 127.0.0.1:8000` yapıldığında çalışır; fakat dışarıdan pod IP'sine veya Service ClusterIP'sine yapılan istekler `Connection refused` alır.
* **Ağ Mekanizması:**
  * Bir uygulama soketini `127.0.0.1` adresine bağlarsa (`bind`), Linux çekirdeği gelen istekleri yalnızca `lo` (loopback) arabiriminden kabul eder.
  * Pod dışından `eth0` arabirimine gelen paketler çekirdek tarafından TCP RST ile reddedilir.
* **Çözüm:**
  * `BIND_HOST: "0.0.0.0"` olarak değiştirerek tüm ağ arabirimlerini dinlemesini sağla.

---

### Hata 7: 4. Katman İletim Protokolü Uyuşmazlığı (UDP vs TCP)
* **İlgili Dosya:** `helm/netcore/templates/04-api-deployment.yaml`
* **Belirtiler:**
  * `Service/netcore-api` ClusterIP adresine HTTP istekleri atıldığında istekler zaman aşımına uğrar.
* **Ağ Mekanizması:**
  * Service tanımında `protocol: UDP` yazılmıştır.
  * `kube-proxy`, ClusterIP için yalnızca UDP paketlerini yönlendiren iptables/IPVS kuralları yazar.
  * HTTP bir TCP protokolü olduğu için TCP SYN paketleri eşleşmez ve bağlantı kurulamaz.
* **Çözüm:**
  * `Service/netcore-api` port tanımında `protocol: TCP` yap.

---

### Hata 8: StatefulSet Headless Service İsim Uyuşmazlığı
* **İlgili Dosya:** `helm/netcore/templates/02-cache-statefulset.yaml`
* **Belirtiler:**
  * `netcore-cache-0.netcore-cache.netcore-prod.svc.cluster.local` DNS kaydı çözülemez.
* **Ağ Mekanizması:**
  * StatefulSet objeleri podlarına sabit ağ kimliği sağlamak için `serviceName` alanında tanımlı Headless Service'i referans alır.
  * Headless Service adı `netcore-cache` iken StatefulSet'te `serviceName: netcore-cache-headless` yazılmıştır.
  * İsim eşleşmediği için CoreDNS ilgili SRV ve A kayıtlarını türetmez.
* **Çözüm:**
  * `StatefulSet/netcore-cache` içinde `serviceName: netcore-cache` yap.

---

### Hata 9: Tek Replikalı Serviste `externalTrafficPolicy: Local`
* **İlgili Dosya:** `helm/netcore/templates/05-gateway-deployment.yaml`
* **Belirtiler:**
  * Ingress üzerinden Gateway'e erişim rastgele düşer veya tek bir node üzerinden çalışıp diğerinde kesilir.
* **Ağ Mekanizması:**
  * `externalTrafficPolicy: Local`, gelen trafiğin sadece o düğümdeki yerel podlara yönlendirilmesini zorunlu kılar (node'lar arası sekme yapmaz).
  * Tek replikalı pod Node-1'deyse ve Ingress veya LoadBalancer trafiği Node-2'ye yönlendirirse, Node-2 üzerinde lokal pod olmadığı için paket düşürülür.
* **Çözüm:**
  * `externalTrafficPolicy: Cluster` yap (veya pod replikasını tüm node'lara yay).

---

### Hata 10: DaemonSet Geçersiz NodeSelector ve Service Etiket Kayması
* **İlgili Dosya:** `helm/netcore/templates/08-telemetry-daemonset.yaml`
* **Belirtiler:**
  * `kubectl get ds -n netcore-prod` çıktısında `DESIRED: 0, READY: 0` görünür.
  * `Service/netcore-telemetry` servisinde hiçbir endpoint oluşmaz.
* **Ağ Mekanizması:**
  * DaemonSet `nodeSelector: network.infrastructure.azure.com/telemetry: "enabled"` etiketini arar, kümede böyle bir etiketli düğüm yoktur.
  * Ayrıca Service seçicisinde `tier: metrics-agent` aranırken pod etiketlerinde `role: packet-probe` vardır.
* **Çözüm:**
  * DaemonSet'ten geçersiz `nodeSelector`'ı kaldır.
  * Servisin etiket seçicisini DaemonSet pod etiketleriyle uyumlu hale getir (`role: packet-probe`).

---

## Doğrulama ve Tamamlanma Kontrolü (Verification)

Tüm düzeltmeler uygulandıktan sonra aşağıdaki komutları çalıştır:

```bash
# 1. Helm ile Güncelle
helm upgrade --install netcore ./helm/netcore

# 2. Doğrulama Job'ını Yeniden Başlat
kubectl delete job netcore-network-handshake -n netcore-prod --ignore-not-found
helm upgrade --install netcore ./helm/netcore

# 3. Kontrol Et
kubectl get pods,svc,ep,sts,ds,jobs,ingress,netpol -n netcore-prod
kubectl get pods,svc,ep,netpol -n netcore-secure

# 4. Job Loglarını Doğrula
kubectl logs -n netcore-prod job/netcore-network-handshake
```

Tüm servisler `Running`, endpoint'ler dolu ve `netcore-network-handshake` job'ı `1/1 Completed` olduğunda lab başarıyla tamamlanmıştır!
