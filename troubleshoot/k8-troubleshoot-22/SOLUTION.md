# 🔐 SRE Incident Post-Mortem & Solution Key
## Lab 22 — VaultStream v6.0 Zero-Trust Payment Settlement & PCI-DSS Mesh

---

# 🇹🇷 Türkçe Çözüm Kılavuzu (Adım Adım Kök Neden Analizi)

Bu belge, **Lab 22 (`k8-troubleshoot-22`)** içerisindeki 10 çok katmanlı Kubernetes ağ, iş yükü ve güvenlik hatasının kök nedenlerini ve tam çözümlerini içerir.

---

## 🛠️ AŞAMA 1 Çözümleri: `DaemonSet/pci-node-auditor` (3 Katmanlı Hata)

### Hata 1: Geçersiz `nodeSelector` (`DESIRED: 0`)
* **İlgili Dosyalar:** `helm/vaultstream/templates/08-auditor-daemonset.yaml` ve `helm/vaultstream/values.yaml`
* **Belirti:** `kubectl get ds -n vaultstream-core` çıktısında `DESIRED: 0` görünür.
* **Kök Neden:** `08-auditor-daemonset.yaml` içinde `nodeSelector: security.azure.com/fips-node: "true"` tanımlanmıştır. Kümedeki düğümlerde bu etiket olmadığı için DaemonSet hiçbir düğümü seçemez.
* **Çözüm:** `08-auditor-daemonset.yaml` içindeki `nodeSelector:` bloğunu silin:
  ```yaml
      tolerations:
        - operator: Exists
  ```

### Hata 2: Bellek Sınırı Aşımı (`OOMKilled` — Exit Code 137)
* **İlgili Dosya:** `helm/vaultstream/values.yaml` (`auditor.memoryLimit`)
* **Belirti:** `nodeSelector` kaldırıldıktan sonra `pci-node-auditor` podları başlar ancak hemen `OOMKilled` (`Exit Code 137`) ile çöküp `CrashLoopBackOff` olur.
* **Kök Neden:** Konteyner içindeki Python kodu `bytearray(48 * 1024 * 1024)` (`48 MB`) bellek ayırmaktadır, ancak `values.yaml` içinde `auditor.memoryLimit: 32Mi` verilmiştir.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde bellek limitini `128Mi` yapın:
  ```yaml
  auditor:
    memoryLimit: 128Mi
  ```

### Hata 3: `Service/pci-auditor-svc` Etiket Seçici Kayması (`ENDPOINTS: <none>`)
* **İlgili Dosya:** `helm/vaultstream/templates/08-auditor-daemonset.yaml`
* **Belirti:** DaemonSet podları `1/1 Running` olsa bile `kubectl get ep pci-auditor-svc -n vaultstream-core` çıktısı `<none>` kalır.
* **Kök Neden:** `Service/pci-auditor-svc` seçicisinde `tier: compliance-agent` aranırken DaemonSet podlarının gerçek etiketi `tier: auditor` olarak tanımlanmıştır.
* **Çözüm:** `08-auditor-daemonset.yaml` içinde Service `selector` alanını düzeltin:
  ```yaml
  spec:
    type: ClusterIP
    selector:
      app: pci-node-auditor
      tier: auditor
  ```

---

## 🛠️ AŞAMA 2 Çözümleri: `settlement-engine` ve `ledger-db` (4 Katmanlı Hata)

### Hata 4: StatefulSet Headless Service İsim Uyuşmazlığı (`ledger-db-0.ledger-db` DNS Hatası)
* **İlgili Dosya:** `helm/vaultstream/values.yaml` (`ledger.serviceName`)
* **Belirti:** `settlement-engine` podları `Init:0/1` (`wait-for-ledger`) aşamasında takılır ve `vaultstream-e2e-audit` Job'ı `[1/4]` adımında `nc: bad address 'ledger-db-0.ledger-db'` hatası verir.
* **Kök Neden:** `02-ledger-statefulset.yaml` içindeki Headless Service'in adı `ledger-db` iken, `values.yaml` içinde `ledger.serviceName: ledger-db-internal` verilmiştir. İkisi eşleşmediği için CoreDNS `ledger-db-0.ledger-db` kaydını oluşturmaz.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde `serviceName` değerini `ledger-db` yapın:
  ```yaml
  ledger:
    serviceName: ledger-db
  ```

### Hata 5: `ledger-db-isolation` NetworkPolicy Etiket Engeli
* **İlgili Dosya:** `helm/vaultstream/templates/06-network-policies.yaml`
* **Belirti:** DNS çözülse bile `nc -z -w 2 ledger-db-0.ledger-db 6379` bağlantısı zaman aşımına (`timed out`) uğrar.
* **Kök Neden:** `ledger-db-isolation` NetworkPolicy kuralı sadece `tier: settlement` etiketli podlara izin vermektedir. Oysa `settlement-engine` podunun etiketi `tier: engine`, doğrulama Job'ının etiketi ise `tier: audit-job`'dır.
* **Çözüm:** `06-network-policies.yaml` içindeki `ledger-db-isolation` politikasında `tier: engine` ve `tier: audit-job` etiketlerine izin verin:
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: ledger-db-isolation
    namespace: {{ .Values.global.coreNamespace }}
  spec:
    podSelector:
      matchLabels:
        tier: database
    policyTypes:
      - Ingress
    ingress:
      - from:
          - podSelector:
              matchLabels:
                tier: engine
          - podSelector:
              matchLabels:
                tier: audit-job
        ports:
          - protocol: TCP
            port: 6379
  ```

### Hata 6: Secret Anahtar İsim Uyuşmazlığı (`CreateContainerConfigError`)
* **İlgili Dosya:** `helm/vaultstream/values.yaml` (`engine.secretKeyName`)
* **Belirti:** InitContainer tamamlandıktan sonra `settlement-engine` podu `CreateContainerConfigError` durumuna düşer (`kubectl describe pod` içinde `Error: couldn't find key signing_key in Secret vaultstream-core/vaultstream-hsm-secret` yazar).
* **Kök Neden:** `01-config-and-secrets.yaml` içindeki `Secret/vaultstream-hsm-secret` verisinde anahtar adı `hsm_signing_key` iken, `values.yaml` içinde `engine.secretKeyName: signing_key` yazılmıştır.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde `secretKeyName` değerini `hsm_signing_key` yapın:
  ```yaml
  engine:
    secretKeyName: hsm_signing_key
  ```

### Hata 7: Liveness & Readiness Probe Port Uyuşmazlığı (`CrashLoopBackOff`)
* **İlgili Dosya:** `helm/vaultstream/values.yaml` (`engine.probePort`)
* **Belirti:** `settlement-engine` podu `Running` olur ancak `0/1 Ready` kalır ve birkaç saniye sonra `Liveness probe failed: Get "http://...:8080/healthz": dial tcp ...:8080: connect: connection refused` ile yeniden başlar.
* **Kök Neden:** Uygulama `engine.port: 8081` üzerinde dinlerken, `engine.probePort: 8080` olarak bırakılmıştır.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde `probePort: 8081` yapın:
  ```yaml
  engine:
    port: 8081
    probePort: 8081
  ```

---

## 🛠️ AŞAMA 3 Çözümleri: `pci-signer`, `edge-proxy` ve CoreDNS Egress

### Hata 8: `pci-signer-isolation` NetworkPolicy Port (`9443` vs `8443`) ve Seçici Hatası
* **İlgili Dosyalar:** `helm/vaultstream/values.yaml` (`signer.networkPolicyPort`) ve `helm/vaultstream/templates/06-network-policies.yaml`
* **Belirti:** `vaultstream-e2e-audit` Job'ı `[3/4]` adımında `http://pci-signer.vaultstream-pci.svc.cluster.local:8443/pci/verify` adresine giderken `download timed out` verir.
* **Kök Neden:**
  1. `values.yaml` içinde `signer.networkPolicyPort: 9443` olarak verilmiştir, oysa `pci-signer` `8443` portunda çalışır.
  2. `06-network-policies.yaml` içinde `namespaceSelector` ve `podSelector` iki ayrı liste elemanı (`-`) olarak yazılmıştır ama port `9443` olduğu için tüm paketler düşmektedir.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde `networkPolicyPort: 8443` yapın ve `06-network-policies.yaml` içinde `vaultstream-core` namespace'inden `8443` portuna erişime izin verin:
  ```yaml
  # values.yaml:
  signer:
    port: 8443
    networkPolicyPort: 8443
  ```

### Hata 9: `Service/edge-proxy` Seçici (`selectorTier`) ve `targetPortName` Uyuşmazlığı + CoreDNS Egress + Cross-Namespace FQDN
* **İlgili Dosyalar:** `helm/vaultstream/values.yaml`, `06-network-policies.yaml` ve `01-config-and-secrets.yaml`
* **Belirtiler:**
  1. `kubectl get ep edge-proxy -n vaultstream-core` çıktısı `<none>` döner.
  2. Endpoint düzeltilse bile `edge-proxy` podu içinden `settlement-engine` ve `pci-signer` adresleri çözülemez (`502/504`).
* **Kök Nedenler ve Çözümleri:**
  1. **`values.yaml` (`proxy` bölümü):** Deployment pod etiketi `tier: proxy` ve containerPort adı `proxy-http` iken, `values.yaml` içinde `selectorTier: edge-gateway` ve `targetPortName: proxy-http-port` yazılmıştır. Bunları düzeltin:
     ```yaml
     proxy:
       targetPortName: proxy-http
       selectorTier: proxy
     ```
  2. **`06-network-policies.yaml` (`edge-proxy-egress`):** CoreDNS (`UDP/TCP 53`) çıkış iznini ekleyin:
     ```yaml
       egress:
         - to:
             - namespaceSelector: {}
           ports:
             - protocol: UDP
               port: 53
             - protocol: TCP
               port: 53
         - to:
             - podSelector:
                 matchLabels:
                   tier: engine
           ports:
             - protocol: TCP
               port: 8081
         - to:
             - namespaceSelector:
                 matchLabels:
                   kubernetes.io/metadata.name: {{ .Values.global.pciNamespace }}
           ports:
             - protocol: TCP
               port: 8443
     ```
  3. **`01-config-and-secrets.yaml` (`edge-proxy-conf`):** Farklı namespace'teki `pci-signer` servisine kısa ad yerine tam FQDN ile gidin:
     ```nginx
         location /pci/verify {
             proxy_pass http://pci-signer.{{ .Values.global.pciNamespace }}.svc.cluster.local:8443/pci/verify;
             proxy_connect_timeout 3s;
             proxy_read_timeout 3s;
         }
     ```

---

## 🛠️ AŞAMA 4 Çözümü: Ingress Sınıfı ve Yolu (`07-ingress.yaml` & `values.yaml`)

### Hata 10: `ingressClassName: internal-nginx` ve Path Uyuşmazlığı
* **İlgili Dosya:** `helm/vaultstream/values.yaml` (`ingress` bölümü)
* **Kök Neden:** `className: internal-nginx` olduğu için standart `nginx` Ingress Controller tarafından işlenmez ve `path: /api/v2/settlement/status` doğrudan Nginx'e gönderildiğinde `404` alır.
* **Çözüm:** `helm/vaultstream/values.yaml` içinde:
  ```yaml
  ingress:
    enabled: true
    className: nginx
    host: vaultstream.local
    path: /settlement/status
    pathType: Prefix
  ```

---

## ✅ Tek Seferde Doğrulama Komutları

Tüm düzeltmeleri yaptıktan sonra:

```bash
helm upgrade --install vaultstream ./helm/vaultstream
kubectl rollout restart deploy/edge-proxy -n vaultstream-core
kubectl delete job vaultstream-e2e-audit -n vaultstream-core --ignore-not-found
helm upgrade --install vaultstream ./helm/vaultstream

# Doğrulama Job'ı loglarını izle:
kubectl logs -n vaultstream-core job/vaultstream-e2e-audit -f
```
