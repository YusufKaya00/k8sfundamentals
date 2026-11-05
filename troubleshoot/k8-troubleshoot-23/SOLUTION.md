# 🔐 SRE Incident Post-Mortem & Solution Key
## Lab 23 — NexusMesh v4.2 Zero-Trust Edge Gateway & Distributed Service Mesh

---

# 🇹🇷 Türkçe Çözüm Kılavuzu (Adım Adım Kök Neden Analizi)

Bu belge, **Lab 23 (`k8-troubleshoot-23`)** içerisindeki 10 adet çok katmanlı Kubernetes ağ, mikroservis ve güvenlik zafiyetinin kök nedenlerini ve adım adım çözümlerini içerir.

---

## 🛠️ AŞAMA 1 Çözümleri: DaemonSet ve Headless Veritabanı (2 Hata)

### Hata 1: `DaemonSet/traffic-guard` Bölge (Zone) Düğüm Seçici Hatası (`DESIRED: 0`)
* **İlgili Dosyalar:** `helm/nexusmesh/templates/08-traffic-guard-daemonset.yaml` ve `helm/nexusmesh/values.yaml` (`trafficGuard.nodeSelectorZone`)
* **Belirti:** `kubectl get ds -n nexus-mesh` çıktısında `DESIRED: 0`, `CURRENT: 0` görünür.
* **Kök Neden:** `values.yaml` içinde `nodeSelectorZone: denmarkeast-1a` tanımlanmıştır. Kümedeki düğümlerde bu bölge etiketi bulunmadığı için DaemonSet hiçbir sunucuya planlanamaz.
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde `nodeSelectorZone` değerini boş bırakın veya `templates/08-traffic-guard-daemonset.yaml` dosyasından `nodeSelector` bloğunu kaldırın:
  ```yaml
  # values.yaml:
  trafficGuard:
    enabled: true
    nodeSelectorZone: ""
    memoryLimit: 64Mi
  ```

---

### Hata 2: StatefulSet Headless Service İsim Uyuşmazlığı (`session-cache-0.session-cache-db` NXDOMAIN)
* **İlgili Dosya:** `helm/nexusmesh/values.yaml` (`sessionCache.serviceName`)
* **Belirti:** `stream-router` podunun InitContainer'ı (`wait-for-cache`) DNS çözümleyemez ve `nc: bad address 'session-cache-0.session-cache-db'` hatasıyla asılı kalır.
* **Kök Neden:** `templates/02-session-cache-statefulset.yaml` içindeki Headless Service'in adı `session-cache-db` iken, `values.yaml` içinde `serviceName: session-cache-headless` verilmiştir. StatefulSet podlarının CoreDNS üzerinde A/SRV kaydı alabilmesi için `spec.serviceName` ile Headless Service adının birebir eşleşmesi zorunludur!
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde `sessionCache.serviceName` değerini `session-cache-db` yapın:
  ```yaml
  sessionCache:
    replicas: 1
    serviceName: session-cache-db
    port: 6379
    memoryLimit: 128Mi
  ```

---

## 🛠️ AŞAMA 2 Çözümleri: `stream-router` Pod, Probe ve Endpointler (3 Hata)

### Hata 3: `Service/stream-router` Adlandırılmış TargetPort Uyuşmazlığı (`ENDPOINTS: <none>`)
* **İlgili Dosya:** `helm/nexusmesh/values.yaml` (`streamRouter.serviceTargetPort`)
* **Belirti:** `stream-router` podları çalışır duruma gelse bile `kubectl get ep stream-router -n nexus-mesh` çıktısı `<none>` olarak kalır.
* **Kök Neden:** `04-stream-router.yaml` içindeki Deployment containerPort'u `name: http-stream` olarak tanımlanmıştır. Ancak `values.yaml` içinde `serviceTargetPort: stream-port` yazılmıştır. İsim eşleşmediği için kube-proxy Endpoint oluşturmaz.
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde `serviceTargetPort` değerini `http-stream` yapın:
  ```yaml
  streamRouter:
    replicas: 2
    port: 8080
    serviceTargetPort: http-stream
  ```

---

### Hata 4: Liveness Probe Port ve Yol Uyuşmazlığı (`CrashLoopBackOff`)
* **İlgili Dosya:** `helm/nexusmesh/values.yaml` (`streamRouter.livenessPort` & `livenessPath`)
* **Belirti:** Pod `Running` olur ancak kısa süre sonra `Liveness probe failed: Get "http://...:8081/status": dial tcp ...:8081: connect: connection refused` hatasıyla Kubelet tarafından sürekli öldürülür.
* **Kök Neden:** Python uygulaması port `8080` üzerinde `/healthz` sunarken, probe port `8081` üzerinde `/status` aramaktadır.
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde liveness ayarlarını düzeltin:
  ```yaml
  streamRouter:
    livenessPort: 8080
    livenessPath: /healthz
  ```

---

### Hata 5: `session-cache-isolation` NetworkPolicy Giriş Etiketi Engeli
* **İlgili Dosya:** `helm/nexusmesh/templates/06-network-policies.yaml` (`session-cache-isolation`)
* **Belirti:** DNS çözülse bile Redis'e giden TCP 6379 paketleri zaman aşımına uğrar (`Connection timed out`).
* **Kök Neden:** `session-cache-isolation` NetworkPolicy kuralı yalnızca `role: router` etiketine izin vermektedir. Oysa `stream-router` podu `role: stream-engine` ve `tier: mesh-api` etiketlerine sahiptir.
* **Çözüm:** `templates/06-network-policies.yaml` içindeki kurala `tier: mesh-api` seçicisini ekleyin:
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: session-cache-isolation
    namespace: {{ .Values.global.meshNamespace }}
  spec:
    podSelector:
      matchLabels:
        tier: cache
    policyTypes:
      - Ingress
    ingress:
      - from:
          - podSelector:
              matchLabels:
                tier: mesh-api
          - podSelector:
              matchLabels:
                tier: audit-job
        ports:
          - protocol: TCP
            port: {{ .Values.sessionCache.port | default 6379 }}
  ```

---

## 🛠️ AŞAMA 3 Çözümleri: Sıfır Güven, Localhost Tuzağı ve DNS Egress (3 Hata)

### Hata 6: `token-vault` Localhost (127.0.0.1) Dinleme Tuzağı (`Connection Refused`)
* **İlgili Dosya:** `helm/nexusmesh/templates/01-config-and-secrets.yaml` (`token-vault-code` ConfigMap)
* **Belirti:** `token-vault` podu `1/1 Running` durumundadır ve podun kendi içindeki probe'lar geçer. Ancak harici podlar veya Service IP üzerinden gelen bağlantılar anında `Connection Refused` alır.
* **Kök Neden:** `token-vault` içerisindeki Python HTTP sunucusu `server_address = ('127.0.0.1', 8443)` olarak başlatılmıştır. Linux ağ stack'inde `127.0.0.1` yalnızca podun kendi loopback (`lo`) arayüzüne yanıt verir. Kube-proxy veya CNI üzerinden `eth0` arayüzüne gelen paketler kernel tarafından reddedilir!
* **Çözüm:** `templates/01-config-and-secrets.yaml` içinde `server_address`'i tüm arayüzleri dinleyecek şekilde `0.0.0.0` yapın:
  ```python
      if __name__ == '__main__':
          server_address = ('0.0.0.0', PORT)
          httpd = http.server.HTTPServer(server_address, TokenHandler)
          print(f"token-vault listening on 0.0.0.0:{PORT}", flush=True)
          httpd.serve_forever()
  ```

---

### Hata 7: `stream-router` Egress Politikasında CoreDNS (Port 53 UDP/TCP) Eksikliği
* **İlgili Dosya:** `helm/nexusmesh/templates/06-network-policies.yaml` (`stream-router-egress`)
* **Belirti:** `stream-router` podu içerisinden hiçbir DNS adı çözülemez (`nslookup` komutları zaman aşımına düşer).
* **Kök Neden:** `stream-router-egress` politikası Redis (6379) ve Token Vault (8443) portlarına izin verirken, küme içi CoreDNS servisine (`kube-system` / `53 UDP/TCP`) çıkış iznini unutmuştur. Kubernetes Zero-Trust ortamında Egress politikası tanımlandığında izin verilmeyen TÜM çıkış trafiği (DNS dahil) engellenir!
* **Çözüm:** `templates/06-network-policies.yaml` içindeki `stream-router-egress` kuralına CoreDNS iznini ekleyin:
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: stream-router-egress
    namespace: {{ .Values.global.meshNamespace }}
  spec:
    podSelector:
      matchLabels:
        tier: mesh-api
    policyTypes:
      - Egress
    egress:
      # CoreDNS Sorgu İzni
      - to:
          - namespaceSelector: {}
        ports:
          - protocol: UDP
            port: 53
          - protocol: TCP
            port: 53
      # Redis Önbellek İzni
      - to:
          - podSelector:
              matchLabels:
                tier: cache
        ports:
          - protocol: TCP
            port: 6379
      # Token Vault İzni
      - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: {{ .Values.global.secureNamespace }}
        ports:
          - protocol: TCP
            port: 8443
  ```

---

### Hata 8: `token-vault-isolation` NetworkPolicy Port Uyuşmazlığı (`9443` vs `8443`)
* **İlgili Dosyalar:** `helm/nexusmesh/values.yaml` (`tokenVault.networkPolicyPort`)
* **Belirti:** `token-vault` `0.0.0.0:8443` dinlese bile `nexus-mesh` namespace'inden gelen istekler zaman aşımına uğrar.
* **Kök Neden:** `values.yaml` içinde `tokenVault.networkPolicyPort: 9443` olarak tanımlanmıştır. Güvenlik duvarı `9443` portunu beklediği için `8443` portundaki gerçek trafiği sessizce düşürür (Drop).
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde portu `8443` yapın:
  ```yaml
  tokenVault:
    replicas: 1
    port: 8443
    networkPolicyPort: 8443
  ```

---

## 🛠️ AŞAMA 4 Çözümleri: Ingress ve Çapraz Namespace FQDN (2 Hata)

### Hata 9: Edge Gateway Nginx Upstream Kısa Ad vs FQDN Çözümleme Hatası (`502 Bad Gateway`)
* **İlgili Dosya:** `helm/nexusmesh/templates/01-config-and-secrets.yaml` (`edge-gateway-conf` ConfigMap)
* **Belirti:** `curl http://edge-gateway.nexus-gateway.svc.cluster.local/stream` isteği `502 Bad Gateway` döner. Nginx loglarında `stream-router could not be resolved` hatası yazar.
* **Kök Neden:** Nginx konfigürasyonunda `proxy_pass http://stream-router:8080;` yazılmıştır. `edge-gateway` podu `nexus-gateway` namespace'inde olduğundan CoreDNS kısa adları yalnızca `nexus-gateway.svc.cluster.local` arama yoluyla arar ve bulamaz! Farklı namespace'teki bir servise erişirken Tam Nitelikli Alan Adı (FQDN) zorunludur!
* **Çözüm:** `templates/01-config-and-secrets.yaml` içindeki upstream adreslerini FQDN yapın:
  ```nginx
            location /stream {
                proxy_pass http://stream-router.{{ .Values.global.meshNamespace }}.svc.cluster.local:8080/stream;
                proxy_connect_timeout 3s;
                proxy_read_timeout 3s;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
            }

            location /auth/token {
                proxy_pass http://token-vault.{{ .Values.global.secureNamespace }}.svc.cluster.local:8443/auth/token;
                proxy_connect_timeout 3s;
                proxy_read_timeout 3s;
            }
  ```

---

### Hata 10: Ingress Controller Sınıfı (`ingressClassName`) ve Yol (Path) Uyuşmazlığı
* **İlgili Dosya:** `helm/nexusmesh/values.yaml` (`ingress` bölümü)
* **Belirti:** Ingress hiçbir adres almaz (`ADDRESS: <none>`) veya standart Nginx Controller tarafından işlenmez.
* **Kök Neden:** `values.yaml` içinde `className: custom-traefik` yazılmıştır. Kümedeki Ingress Controller standart `nginx` sınıfına sahiptir. Ayrıca yol `/api/v1/stream` yerine `/stream` olarak eşlenmelidir.
* **Çözüm:** `helm/nexusmesh/values.yaml` içinde:
  ```yaml
  ingress:
    enabled: true
    className: nginx
    host: nexusmesh.local
    path: /stream
    pathType: Prefix
  ```

---

## ✅ Tek Seferde Düzeltme ve Doğrulama

Tüm düzeltmeleri yaptıktan sonra:

```bash
# 1. Helm güncellemesini uygula:
helm upgrade --install nexusmesh ./helm/nexusmesh

# 2. ConfigMap değişikliklerini podlara yansıtmak için rollout yap:
kubectl rollout restart deploy/token-vault -n nexus-secure
kubectl rollout restart deploy/edge-gateway -n nexus-gateway
kubectl rollout restart deploy/stream-router -n nexus-mesh

# 3. Önceki tamamlanmamış denetim Job'ını temizle ve yeniden çalıştır:
kubectl delete job nexusmesh-e2e-audit -n nexus-mesh --ignore-not-found
helm upgrade --install nexusmesh ./helm/nexusmesh

# 4. Pusula Job loglarını canlı izle:
kubectl logs -n nexus-mesh job/nexusmesh-e2e-audit -f
```

Başarılı sonuç:
```
================================================================
 NEXUSMESH v4.2 E2E VERIFICATION & NETWORK AUDIT SUITE           
================================================================
--> [1/5] Testing CoreDNS & Headless Cache (session-cache-0.session-cache-db:6379)... [PASS] Headless DNS & Redis port 6379 reachable!
--> [2/5] Testing Cross-Namespace Token Vault (token-vault.nexus-secure:8443)... [PASS] Token Vault authenticated successfully!
--> [3/5] Testing Stream Router (stream-router.nexus-mesh:8080)... [PASS] Stream Router is active and responding on 8080!
--> [4/5] Testing Edge Gateway (edge-gateway.nexus-gateway:80/stream)... [PASS] Edge Gateway successfully proxied request across namespaces!
--> [5/5] Testing Traffic Guard Mesh Monitor (traffic-guard-svc:9100)... [PASS] Traffic Guard agent telemetry online!
================================================================
 🎉 ALL 5 AUDIT CHECKS PASSED! NEXUSMESH v4.2 IS 100% HEALTHY!  
================================================================
```

---

# 🇬🇧 English Solution Key

### Summary of Faults & Corrections:
1. **Fault 1:** Set `trafficGuard.nodeSelectorZone: ""` in `values.yaml`.
2. **Fault 2:** Set `sessionCache.serviceName: "session-cache-db"` in `values.yaml` to match Headless Service.
3. **Fault 3:** Set `streamRouter.serviceTargetPort: "http-stream"` in `values.yaml` to match containerPort name.
4. **Fault 4:** Set `streamRouter.livenessPort: 8080` and `streamRouter.livenessPath: "/healthz"` in `values.yaml`.
5. **Fault 5:** In `06-network-policies.yaml` (`session-cache-isolation`), allow `tier: mesh-api`.
6. **Fault 6:** In `01-config-and-secrets.yaml` (`token-vault-code`), change bind address from `127.0.0.1` to `0.0.0.0`.
7. **Fault 7:** In `06-network-policies.yaml` (`stream-router-egress`), add egress rule to port 53 UDP/TCP (CoreDNS).
8. **Fault 8:** Set `tokenVault.networkPolicyPort: 8443` in `values.yaml`.
9. **Fault 9:** In `01-config-and-secrets.yaml` (`edge-gateway-conf`), use FQDN `http://stream-router.nexus-mesh.svc.cluster.local:8080/stream`.
10. **Fault 10:** Set `ingress.className: "nginx"` and `ingress.path: "/stream"` in `values.yaml`.
