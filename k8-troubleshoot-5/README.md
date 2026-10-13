# 🚨 SRE Incident Lab 5: ApexPay Core Banking & Service Mesh Triage

This workspace serves as the active Incident Triage War Room during the production go-live failure of **ApexPay Global**, a mission-critical real-time payment settlement and fraud detection engine.

All manifests deployed to the cluster were **100% schema-compliant** and successfully accepted by the Kubernetes API server without syntax or validation errors. However, critical networking and service discovery defects—including **Headless Service DNS contracts, multi-label selector mismatches, port vs targetPort indirection, transport protocol mismatch (TCP vs UDP), and `externalTrafficPolicy: Local` packet blackholing**—have brought down transaction processing across the entire platform.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Senior SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Cluster Topology & Infrastructure Constraints

The incident scenario is grounded strictly in the following 3-node cluster topology:

| Node Name | IP | Label | Constraint / Taint | Allocated Tier Role |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-2** | `10.0.10.208` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Database Workloads Only (Isolated) |

* **Target Namespace:** `apex-pay`
* **Networking Plane:** OCI VCN-Native Pod Networking, kube-proxy (iptables mode), CoreDNS.

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all broken manifests to the cluster:

```bash
kubectl apply -f manifests/
```

Watch initial deployment status:
```bash
kubectl get pods,svc,endpointslices -n apex-pay -o wide
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the tickets sequentially:

---

### [INC-501] Database Headless Service DNS Resolution Failure — NXDOMAIN & Empty Endpoints
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] StatefulSet apex-pay/ledger-db pod ledger-db-0 cannot be resolved by internal microservices. CoreDNS queries for ledger-db-0.ledger-db return NXDOMAIN.`
* **Symptoms:**
  `ledger-db-0` is scheduled on `Node-3` (`10.0.10.78`) and is `1/1 Running`. However, downstream services attempting to connect to `ledger-db-0.ledger-db.apex-pay.svc.cluster.local` fail with name resolution errors. The existing service has `Endpoints: <none>`.
* **Underlying K8s Mechanism:**
  Kubernetes StatefulSet deterministic DNS records (`<pod-name>.<service-name>.<namespace>.svc.cluster.local`) require a Headless Service (`clusterIP: None`) whose `metadata.name` matches the StatefulSet's `spec.serviceName`, and whose `spec.selector` matches the Pod template labels.
* **Triage & Control Commands:**
  ```bash
  # 1. Inspect Service configuration and selector
  kubectl describe svc ledger-service -n apex-pay

  # 2. Inspect Pod labels and StatefulSet serviceName
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=ledger-db --show-labels
  kubectl get statefulset ledger-db -n apex-pay -o jsonpath='{.spec.serviceName}{"\n"}'

  # 3. Check Endpoints and EndpointSlices
  kubectl get endpoints,endpointslices -n apex-pay -l app.kubernetes.io/name=ledger-db

  # 4. Test DNS resolution inside the cluster
  kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local

  # 5. Verify database connectivity once resolved
  kubectl run db-check --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
  ```

---

### [INC-502] Fraud Engine Endpoints Missing — Over-Specified Service Selector
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service apex-pay/fraud-engine-svc has 0 active endpoints. Downstream payment processing is halted.`
* **Symptoms:**
  Both `fraud-engine` pods are `1/1 Running` and healthy on worker nodes. Yet `kubectl get endpoints fraud-engine-svc` returns `<none>`, and any request sent to `http://fraud-engine-svc:8080/` times out or fails.
* **Underlying K8s Mechanism:**
  The Endpoint / EndpointSlice controller uses a boolean AND conjunction across all key-value pairs in `spec.selector`. If even one label does not match the Pod labels, the pod is excluded from the Service backend pool.
* **Triage & Control Commands:**
  ```bash
  # 1. Check endpoints of the fraud engine service
  kubectl get endpoints fraud-engine-svc -n apex-pay
  kubectl get endpointslices -n apex-pay -l kubernetes.io/service-name=fraud-engine-svc

  # 2. Compare Service selector with actual Pod labels
  kubectl get svc fraud-engine-svc -n apex-pay -o jsonpath='{.spec.selector}{"\n"}'
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=fraud-engine --show-labels

  # 3. Test HTTP curl to Service ClusterIP once endpoints are attached
  kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s -I http://fraud-engine-svc:8080/
  ```

---

### [INC-503] Payment Processor Port vs TargetPort Mismatch — TCP Connection Refused
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Connections to apex-pay/payment-processor-svc:80 fail immediately with 'Connection refused' (TCP RST).`
* **Symptoms:**
  CoreDNS resolves `payment-processor-svc.apex-pay.svc.cluster.local` properly, and the Service possesses valid active Endpoints. However, connecting to port 80 fails instantly with `curl: (7) Failed to connect to payment-processor-svc port 80: Connection refused`.
* **Underlying K8s Mechanism:**
  `spec.ports[].port` is the external port exposed on the Service ClusterIP. `spec.ports[].targetPort` is the actual port where the container process is listening inside the Pod network namespace. If `targetPort` forwards to an unused port, the pod's kernel responds with a TCP RST.
* **Triage & Control Commands:**
  ```bash
  # 1. Describe Service to inspect port and targetPort
  kubectl describe svc payment-processor-svc -n apex-pay

  # 2. Inspect containerPort in the running Deployment
  kubectl get deploy payment-processor -n apex-pay -o jsonpath='{.spec.template.spec.containers[*].ports}{"\n"}'

  # 3. Test connection to Service ClusterIP (Fails with Connection Refused)
  kubectl run curl-svc --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -v http://payment-processor-svc:80/

  # 4. Test direct connection to Pod IP on port 8080 (Succeeds)
  POD_IP=$(kubectl get pod -n apex-pay -l app.kubernetes.io/name=payment-processor -o jsonpath='{.items[0].status.podIP}')
  kubectl run curl-pod --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://$POD_IP:8080/
  ```

---

### [INC-504] Notification Broker Multi-Port Protocol Mismatch — TCP Drops on UDP Service
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Event dispatching to apex-pay/notification-broker-svc:9000 times out while metrics on port 9090 are operational.`
* **Symptoms:**
  The `notification-broker` pod listens on TCP 9000 (events) and TCP 9090 (metrics). Metric scraping on `notification-broker-svc:9090` works cleanly. But TCP connections to `notification-broker-svc:9000` hang and time out with `nc: connect ... timed out`.
* **Underlying K8s Mechanism:**
  In multi-port Services, each port requires an explicit `name` and `protocol` (`TCP`, `UDP`, or `SCTP`). When a port is declared as `UDP`, kube-proxy only sets up packet translation for UDP. Inbound TCP SYN packets have no matching iptables rules and are dropped.
* **Triage & Control Commands:**
  ```bash
  # 1. View Service port definitions and transport protocols
  kubectl get svc notification-broker-svc -n apex-pay -o yaml

  # 2. Check Endpoints protocol configuration
  kubectl describe endpoints notification-broker-svc -n apex-pay

  # 3. Test TCP reachability on event port 9000 (Fails / Times out)
  kubectl run nc-tcp --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000

  # 4. Test UDP reachability on event port 9000 (Connects to UDP port)
  kubectl run nc-udp --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -u -w 3 notification-broker-svc 9000

  # 5. Test metrics port 9090 (Succeeds)
  kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
  ```

---

### [INC-505] Merchant Gateway NodePort External Blackhole — `externalTrafficPolicy: Local` Misalignment
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] External payment gateway on NodePort 30080 is intermittently dropping traffic. Accessing Node-2 (10.0.10.208:30080) hangs indefinitely.`
* **Symptoms:**
  Connecting to `10.0.10.122:30080` (Node-1) returns `HTTP 200 OK`. However, connecting to `10.0.10.208:30080` (Node-2) times out. External load balancers mark Node-2 unhealthy and drop 50% of incoming merchant traffic.
* **Underlying K8s Mechanism:**
  When a NodePort Service has `externalTrafficPolicy: Local`, kube-proxy only forwards traffic to pods running **locally on that specific node** (preserving client IP and eliminating cross-node hops). If a node has **no local pod replica**, kube-proxy drops incoming packets on that node rather than routing them to other nodes.
* **Triage & Control Commands:**
  ```bash
  # 1. Locate which node hosts the merchant-gateway pod
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=merchant-gateway -o wide

  # 2. Inspect externalTrafficPolicy configuration
  kubectl get svc merchant-gateway-np -n apex-pay -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'

  # 3. Test NodePort on Node-1 (where pod lives) -> Succeeds (HTTP 200)
  kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/

  # 4. Test NodePort on Node-2 (where no pod lives) -> Times out!
  kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
  ```

---

## 🎯 Verification Criteria (Definition of Done)

The incident is considered fully resolved when:
1. `ledger-db-0.ledger-db.apex-pay.svc.cluster.local` resolves cleanly to `10.0.10.78` via CoreDNS.
2. `fraud-engine-svc` has 2 active healthy endpoints and responds with `HTTP 200` on port `8080`.
3. `payment-processor-svc:80` accepts TCP traffic without `Connection refused` and returns processing status.
4. `notification-broker-svc:9000` responds to TCP requests and port `9090` metrics can be scraped.
5. `merchant-gateway-np:30080` is reachable with `HTTP 200` across ALL web nodes (`10.0.10.122` and `10.0.10.208`).

---
---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# 🚨 SRE Incident Lab 5: ApexPay Çekirdek Bankacılık & Servis Ağı Triage Labı

Bu çalışma alanı, gerçek zamanlı ödeme takas ve sahtekarlık tespit (fraud detection) platformu olan **ApexPay Global**'in canlıya geçişi sırasında yaşanan kesintiye yönelik aktif Acil Müdahale Odasıdır (War Room).

Kümeye uygulanan tüm manifestolar **%100 sözdizimsel (schema) olarak geçerlidir** ve Kubernetes API sunucusu tarafından hiçbir hata verilmeden kabul edilmiştir. Ancak **Headless Service DNS sözleşmeleri, çok etiketli selector uyumsuzlukları, port / targetPort yönlendirme hataları, taşıma katmanı protokol çelişkileri (TCP vs UDP) ve `externalTrafficPolicy: Local` paket kara delik (blackhole) problemi** nedeniyle tüm mikroservis iletişimi çökmüştür.

> 📖 **Post-Mortem & Kapsamlı Kök Neden Analizleri (RCA):**  
> 👉 **[Kıdemli SRE Çözüm ve İnceleme Rehberini İnceleyin (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Küme Topolojisi ve Altyapı Kısıtları

Olay müdahale senaryosu doğrudan aşağıdaki 3-node küme yapısına dayanmaktadır:

| Node Adı | IP | Label | Kısıt / Taint | Tahsis Edilen Rol |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *Yok* | Web / API / Gateway İş Yükleri |
| **Node-2** | `10.0.10.208` | `tier=web` | *Yok* | Web / API / Gateway İş Yükleri |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Yalnızca Veritabanı İş Yükleri (İzole) |

* **Hedef Namespace:** `apex-pay`
* **Ağ Katmanı:** OCI VCN-Native Pod Networking, kube-proxy (iptables modu), CoreDNS.

---

## 🚀 Ortamın Başlatılması (Hatalı Platformun Dağıtımı)

Hatalı manifestoları kümeye uygulayın:

```bash
kubectl apply -f manifests/
```

Başlangıç durumunu gözlemleyin:
```bash
kubectl get pods,svc,endpointslices -n apex-pay -o wide
```

---

## 📋 Nöbetçi SRE Olay Müdahale Panosu

Biletleri sırasıyla teşhis ve tamir edin:

---

### [INC-501] Veritabanı Headless Service DNS Çözümleme Hatası — NXDOMAIN & Boş Endpoints
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] StatefulSet apex-pay/ledger-db podu ledger-db-0 diğer mikroservisler tarafından çözümlenemiyor. ledger-db-0.ledger-db için CoreDNS sorguları NXDOMAIN dönüyor.`
* **Belirtiler:**
  `ledger-db-0` podu `Node-3` (`10.0.10.78`) üzerinde başarıyla planlanmış ve `1/1 Running` durumundadır. Ancak `ledger-db-0.ledger-db.apex-pay.svc.cluster.local` adresine bağlanmak isteyen diğer servisler DNS çözümleme hatası alır. Servisin endpoint listesi boştur (`Endpoints: <none>`).
* **Temel K8s Mekanizması:**
  StatefulSet podlarının belirlenebilir DNS kayıtlarına (`<pod-adı>.<servis-adı>.<namespace>.svc.cluster.local`) sahip olabilmesi için `clusterIP: None` tanımlı bir Headless Service gerekir. Bu servisin `metadata.name` değeri ile StatefulSet'in `spec.serviceName` değeri **birebir aynı olmalı** ve servisin selector'ı pod etiketleriyle eşleşmelidir.
* **Kontrol ve Teşhis Komutları:**
  ```bash
  # 1. Servis konfigürasyonunu ve selector etiketlerini inceleyin
  kubectl describe svc ledger-service -n apex-pay

  # 2. Pod etiketlerini ve StatefulSet serviceName alanını karşılaştırın
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=ledger-db --show-labels
  kubectl get statefulset ledger-db -n apex-pay -o jsonpath='{.spec.serviceName}{"\n"}'

  # 3. Endpoints ve EndpointSlices durumunu kontrol edin
  kubectl get endpoints,endpointslices -n apex-pay -l app.kubernetes.io/name=ledger-db

  # 4. Küme içinden DNS çözümleme testi yapın
  kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local

  # 5. Düzeltme sonrası doğrudan veritabanı erişimini doğrulayın
  kubectl run db-check --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
  ```

---

### [INC-502] Fraud Engine Endpoints Kayıp — Fazla Belirtilmiş (Over-Specified) Service Selector
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] apex-pay/fraud-engine-svc servisinin 0 aktif endpoint'i var. Ödeme akışı durduruldu.`
* **Belirtiler:**
  Her iki `fraud-engine` podu da worker node'lar üzerinde `1/1 Running` ve sağlıklıdır. Ancak `kubectl get endpoints fraud-engine-svc` çıktısı `<none>` döner ve servise giden tüm HTTP istekleri zaman aşımına uğrar.
* **Temel K8s Mekanizması:**
  Kubernetes Endpoint denetleyicisi `spec.selector` altındaki tüm anahtar-değer çiftlerini mantıksal **VE (AND)** bağlacı ile sorgular. Eğer serviste pod üzerinde var olmayan fazladan bir etiket tanımlanmışsa (örneğin `environment: production`), podlar havuza dahil edilmez.
* **Kontrol ve Teşhis Komutları:**
  ```bash
  # 1. Fraud engine servisinin endpoint listesini kontrol edin
  kubectl get endpoints fraud-engine-svc -n apex-pay
  kubectl get endpointslices -n apex-pay -l kubernetes.io/service-name=fraud-engine-svc

  # 2. Servis selector'ı ile gerçek Pod etiketlerini karşılaştırın
  kubectl get svc fraud-engine-svc -n apex-pay -o jsonpath='{.spec.selector}{"\n"}'
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=fraud-engine --show-labels

  # 3. Düzeltme sonrası servis ClusterIP adresine HTTP isteği atın
  kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s -I http://fraud-engine-svc:8080/
  ```

---

### [INC-503] Payment Processor Port / TargetPort Uyuşmazlığı — TCP Connection Refused
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] apex-pay/payment-processor-svc:80 bağlantıları anında 'Connection refused' (TCP RST) ile reddediliyor.`
* **Belirtiler:**
  CoreDNS servisi başarıyla çözümler ve servisin aktif endpoint'leri mevcuttur. Ancak port 80'e bağlanan herhangi bir istemci anında `curl: (7) Failed to connect to payment-processor-svc port 80: Connection refused` hatası alır.
* **Temel K8s Mekanizması:**
  `spec.ports[].port` ClusterIP üzerinde dışa açılan porttur. `spec.ports[].targetPort` ise konteyner içerisindeki uygulamanın dinlediği gerçek porttur. Eğer `targetPort` dinlenmeyen bir porta yönlendirilirse (örneğin 8080 yerine 80), pod ağ yığını hemen TCP RST bayrağı ile bağlantıyı reddeder.
* **Kontrol ve Teşhis Komutları:**
  ```bash
  # 1. Servisin port ve targetPort değerlerini inceleyin
  kubectl describe svc payment-processor-svc -n apex-pay

  # 2. Deployment içindeki konteynerin dinlediği portu kontrol edin
  kubectl get deploy payment-processor -n apex-pay -o jsonpath='{.spec.template.spec.containers[*].ports}{"\n"}'

  # 3. Servis ClusterIP adresine istek atın (Connection Refused hatası verir)
  kubectl run curl-svc --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -v http://payment-processor-svc:80/

  # 4. Doğrudan Pod IP adresine port 8080 üzerinden bağlanın (Başarılı olur)
  POD_IP=$(kubectl get pod -n apex-pay -l app.kubernetes.io/name=payment-processor -o jsonpath='{.items[0].status.podIP}')
  kubectl run curl-pod --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://$POD_IP:8080/
  ```

---

### [INC-504] Notification Broker Protokol Çelişkisi — UDP Servisi Üzerinde Düşen TCP Paketleri
* **Öncelik:** `P2 - High`
* **Uyarı:**
  > `[WARNING] apex-pay/notification-broker-svc:9000 olay iletimi zaman aşımına uğrarken, 9090 portundaki metrikler çalışıyor.`
* **Belirtiler:**
  `notification-broker` podu TCP 9000 (olaylar) ve TCP 9090 (metrikler) üzerinde dinleme yapmaktadır. Metrikler başarıyla toplanırken, port 9000'e giden TCP bağlantıları askıda kalır ve zaman aşımına uğrar (`nc: connect ... timed out`).
* **Temel K8s Mekanizması:**
  Çok portlu servislerde her port için benzersiz bir `name` ve `protocol` (`TCP`, `UDP`, `SCTP`) tanımlanmalıdır. Bir port `UDP` olarak belirtildiğinde, kube-proxy yalnızca UDP için yönlendirme kuralları yazar. Gelen TCP paketleri hiçbir kuralla eşleşmeyerek düşürülür (drop).
* **Kontrol ve Teşhis Komutları:**
  ```bash
  # 1. Servis portlarını ve taşıma protokollerini görüntüleyin
  kubectl get svc notification-broker-svc -n apex-pay -o yaml

  # 2. Endpoint protokol konfigürasyonunu kontrol edin
  kubectl describe endpoints notification-broker-svc -n apex-pay

  # 3. Olay portu 9000 için TCP erişimini test edin (Başarısız / Zaman aşımı)
  kubectl run nc-tcp --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000

  # 4. Olay portu 9000 için UDP erişimini test edin (UDP açık görünür)
  kubectl run nc-udp --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -u -w 3 notification-broker-svc 9000

  # 5. Metrik portu 9090'ı test edin (Başarılı)
  kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
  ```

---

### [INC-505] Merchant Gateway NodePort Kara Deliği — `externalTrafficPolicy: Local` Dengesizliği
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] NodePort 30080 üzerinden dış ödeme ağ geçidine gelen istekler Node-2'de düşüyor (10.0.10.208:30080 askıda kalıyor).`
* **Belirtiler:**
  `10.0.10.122:30080` (Node-1) adresi `HTTP 200 OK` dönerken, `10.0.10.208:30080` (Node-2) adresine yapılan istekler zaman aşımına uğrar. Dış yük dengeleyici Node-2'yi sağlıksız işaretleyerek trafiğin yarısını kaybetmektedir.
* **Temel K8s Mekanizması:**
  NodePort servisinde `externalTrafficPolicy: Local` seçildiğinde kube-proxy gelen trafiği yalnızca **o node üzerinde yerel olarak koşan podlara** iletir (orijinal istemci IP'sini korumak ve ek ağ sekmesini engellemek için). Eğer o node üzerinde çalışan bir pod kopyası yoksa, kube-proxy paketi diğer node'lara iletmez ve sessizce düşürür.
* **Kontrol ve Teşhis Komutları:**
  ```bash
  # 1. Gateway podunun hangi node üzerinde çalıştığını bulun
  kubectl get pods -n apex-pay -l app.kubernetes.io/name=merchant-gateway -o wide

  # 2. Servis üzerindeki externalTrafficPolicy ayarını inceleyin
  kubectl get svc merchant-gateway-np -n apex-pay -o jsonpath='{.spec.externalTrafficPolicy}{"\n"}'

  # 3. Podun bulunduğu Node-1 üzerinden NodePort'u test edin -> Başarılı (HTTP 200)
  kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/

  # 4. Podun bulunmadığı Node-2 üzerinden NodePort'u test edin -> Zaman aşımına uğrar!
  kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
  ```

---

## 🎯 Başarı Kriterleri (Definition of Done)

Tüm incident'lar şu şartlar sağlandığında çözülmüş kabul edilir:
1. `ledger-db-0.ledger-db.apex-pay.svc.cluster.local` adresi CoreDNS üzerinden `10.0.10.78` IP'sine çözümlenmeli.
2. `fraud-engine-svc` 2 adet sağlıklı endpoint'e sahip olmalı ve 8080 portundan `HTTP 200` dönmeli.
3. `payment-processor-svc:80` portundan `Connection refused` hatası alınmamalı ve işlem durumu dönmeli.
4. `notification-broker-svc:9000` TCP isteklerine yanıt vermeli ve 9090 metrikleri toplanabilmeli.
5. `merchant-gateway-np:30080` portuna HEM `10.0.10.122` HEM DE `10.0.10.208` node IP'leri üzerinden `HTTP 200` ile erişilebilmeli.
