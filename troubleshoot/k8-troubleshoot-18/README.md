# 🇬🇧 English Version

# INCIDENT #4092 — Complete Outage Following NovaStore v2.4.0 Release

## Incident Summary (Incident Report)
This morning at 09:15 UTC, the `storefront` Helm chart was upgraded to release `v2.4.0`. The rollout introduced several architectural and security changes:
1. The session cache (Redis) was migrated to persistent storage using a `StatefulSet` with mandatory password authentication.
2. At the request of the security team, a strict `NetworkPolicy` was applied to isolate the cache layer.
3. The frontend application (`storefront-web`) image was switched to a non-root unprivileged container (`nginx-unprivileged`), accompanied by an `initContainer` verifying cache handshake before startup.

**Current Impact:** Ingress and external LoadBalancer traffic receives `503 Service Temporarily Unavailable`, completely blocking customer checkout and storefront operations.

---

## Environment Setup (Provisioning)
```bash
# 1. Provision AKS Infrastructure & Ingress Controller (Optional - if using Terraform)
cd terraform
terraform init
terraform apply -auto-approve

# 2. Retrieve Kubeconfig
$(terraform output -raw kubeconfig_command)

# 3. Deploy Broken Lab Environment for Practice:
cd ../
kubectl create namespace storefront-prod --dry-run=client -o yaml | kubectl apply -f -
# Deploy broken Helm chart:
./broken-manifests/setup-broken.sh
# (or manually: helm upgrade --install storefront ./broken-manifests/helm/storefront -n storefront-prod)

# Alternatively, deploy standard chart:
helm upgrade --install storefront ./helm/storefront -n storefront-prod
```

---

## Objectives & Acceptance Criteria (Verification)

After troubleshooting and editing the Helm chart files (`helm/storefront/`) and executing `helm upgrade --install storefront ./helm/storefront -n storefront-prod`, all verification checks must pass cleanly:

### 1. Pod and Storage Status
All pods in the `storefront-prod` namespace must be in `Running` and `1/1 READY` state, and all PVCs must be `Bound`:
```bash
kubectl get pvc,pods,svc,ep -n storefront-prod
```

### 2. Live Web Ingress Verification (Browser & CLI)
Retrieve the Ingress Public IP address and verify HTTP 200 connectivity:
```bash
export GATEWAY_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Live Storefront URL: http://$GATEWAY_IP"

curl -i http://$GATEWAY_IP
```

**Expected Output:** `HTTP/1.1 200 OK` rendering the HTML page with text `NovaStore Production Gateway - STATUS: ONLINE (v2.4.0)`.

---

## Incident Solution & Root Cause Analysis (6 Cascading Production Faults)

The incident contains **6 sequential production defects** spanning the complete stack (Storage $\rightarrow$ Secret $\rightarrow$ NetworkPolicy $\rightarrow$ Image $\rightarrow$ Probe $\rightarrow$ Service):

<details>
<summary><b>Click to expand full Root Cause Analysis & Remediation steps</b></summary>

1. **Defect 1 — StorageClass Mismatch (`Pending` PVC & Cache Pod):**
   * **Symptom:** `storefront-cache-0` pod is stuck in `Pending`. `kubectl describe pvc` shows `storageclass.storage.k8s.io "managed-csi-fast" not found`.
   * **Remediation:** In `values.yaml`, change `storageClassName: "managed-csi-fast"` to AKS standard `"managed-csi"` (or `"default"`). Remove the stuck PVC via `kubectl delete statefulset,pvc --all -n storefront-prod`.

2. **Defect 2 — Secret Key Reference Typo (`CreateContainerConfigError`):**
   * **Symptom:** `storefront-cache-0` binds storage but fails with `CreateContainerConfigError`.
   * **Root Cause:** `config-and-secret.yaml` defines Secret key `REDIS_PASSWORD`, but `cache-statefulset.yaml` looks up `key: CACHE_TOKEN`.
   * **Remediation:** In `cache-statefulset.yaml`, change `secretKeyRef.key` to `REDIS_PASSWORD`.

3. **Defect 3 — NetworkPolicy Label & Port Mismatch (`Init:0/1` Deadlock):**
   * **Symptom:** `storefront-cache-0` reaches `Running`, but `storefront-web` pods remain stuck in `Init:0/1` (`Waiting for Redis cache...`).
   * **Root Cause:** In `network-and-ingress.yaml`, `cache-isolation-policy` restricts ingress to pods with `tier: backend` on port `6380`. The web pods have label `tier: frontend` and Redis listens on port `6379`.
   * **Remediation:** In `network-and-ingress.yaml`, update NetworkPolicy ingress selector to `tier: frontend` and port to `6379`.

4. **Defect 4 — Broken Container Image Tag (`ImagePullBackOff` / `ErrImagePull`):**
   * **Symptom:** InitContainer completes successfully (`Init:Completed`), but the main container crashes with `ImagePullBackOff`.
   * **Root Cause:** `values.yaml` specifies a non-existent image tag `tag: "1.27-alpine-slim-rc99"`.
   * **Remediation:** Update `values.yaml` image tag to `tag: "1.27-alpine"` (or `"1.27-alpine-slim"`).

5. **Defect 5 — Liveness/Readiness Probe Path Mismatch (`CrashLoopBackOff` & `0/1 Ready`):**
   * **Symptom:** The container starts but restarts continuously due to probe failure returning `HTTP 404 Not Found`.
   * **Root Cause:** `config-and-secret.yaml` configures Nginx health endpoint at `/ready`, but `values.yaml` sets `probePath: /healthz`.
   * **Remediation:** Update `values.yaml` to set `probePath: /ready`.

6. **Defect 6 — Service Selector & TargetPort Mismatch (`503 Service Unavailable` / Empty Endpoints):**
   * **Symptom:** All pods are `1/1 Running`, yet hitting the site continues to return `503`. `kubectl get ep -n storefront-prod` shows `storefront-web-svc` with `<none>`.
   * **Root Cause:** In `network-and-ingress.yaml`, Service selects `tier: web-ui` (pods have `tier: frontend`) and routes to `targetPort: 80` (unprivileged nginx listens on `8080`).
   * **Remediation:** In `network-and-ingress.yaml`, set selector to `tier: frontend` and `targetPort` to `8080` (or `{{ .Values.webapp.containerPort }}`).

</details>

<br>

---

# 🇹🇷 Türkçe Dokümantasyon

# INCIDENT #4092 — NovaStore v2.4.0 Yayını Sonrası Tam Kesinti

## Olay Özeti (Incident Report)
Bu sabah saat 09:15'te `storefront` Helm paketi `v2.4.0` sürümüne güncellendi. Güncelleme kapsamında:
1. Oturum önbelleği (Redis) kalıcı disk yapısına (`StatefulSet`) geçirildi ve parola doğrulaması zorunlu kılındı.
2. Güvenlik ekibinin talebiyle önbellek katmanına `NetworkPolicy` eklendi.
3. Önyüz (`storefront-web`) imajı root olmayan (`nginx-unprivileged`) yeni bir sürüme yükseltildi ve başlangıçta önbellek bağlantısını doğrulayan bir `initContainer` eklendi.

**Mevcut Durum:** Dış dünyadan LoadBalancer IP'sine girildiğinde `503 Service Temporarily Unavailable` dönüyor ve müşteriler siteye erişemiyor.

---

## Kurulum (Lab Ortamını Başlatma)
```bash
# 1. AKS Altyapısını ve Ingress Controller'ı Kur
cd terraform
terraform init
terraform apply -auto-approve

# 2. Kubeconfig Bağlantısını Al
$(terraform output -raw kubeconfig_command)

# 3. Pratik Yapmak İçin Bozuk v2.4.0 Sürümünü Dağıt:
cd ../
kubectl create namespace storefront-prod --dry-run=client -o yaml | kubectl apply -f -
# Bozuk Helm paketini kur:
./broken-manifests/setup-broken.sh
# (veya manuel: helm upgrade --install storefront ./broken-manifests/helm/storefront -n storefront-prod)

# Veya standart paketi kur:
helm upgrade --install storefront ./helm/storefront -n storefront-prod
```

---

## Hedef ve Kabul Kriterleri (Verification)

Helm chart dosyalarını (`helm/storefront/`) düzenleyip `helm upgrade --install storefront ./helm/storefront -n storefront-prod` komutuyla güncelledikten sonra aşağıdaki tüm doğrulama kontrolleri hatasız geçmelidir:

### 1. Pod ve Depolama Durumu
`storefront-prod` namespace'indeki tüm pod'lar `Running` ve `1/1 READY` olmalı, PVC `Bound` durumuna geçmelidir:
```bash
kubectl get pvc,pods,svc,ep -n storefront-prod
```

### 2. Canlı Web Sitesi Erişimi (Tarayıcı & Terminal Testi)
Aşağıdaki komutla Ingress Public IP adresini al ve hem tarayıcıdan hem de curl ile test et:
```bash
export GATEWAY_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Canlı Site Adresi: http://$GATEWAY_IP"

curl -i http://$GATEWAY_IP
```

**Beklenen Çıktı:** `HTTP/1.1 200 OK` ve ekranda `NovaStore Production Gateway - STATUS: ONLINE (v2.4.0)` HTML sayfası.

---

## Çözüm Anahtarı (Sadece Takıldığında veya Bitirdiğinde Kontrol Etmek İçin)

Sistemde birbirini tetikleyen **6 gerçekçi prodüksiyon hatası** (Storage $\rightarrow$ Secret $\rightarrow$ NetworkPolicy $\rightarrow$ Image $\rightarrow$ Probe $\rightarrow$ Service) zincirleme olarak bulunuyor:

<details>
<summary><b>İpucu ve Tam Çözüm Adımlarını Görmek İçin Tıkla</b></summary>

1. **Hata 1 — StorageClass (`Pending` PVC & Cache Pod):**
   * **Belirti:** `storefront-cache-0` podu `Pending` durumunda. `kubectl describe pvc` yapıldığında `storageclass.storage.k8s.io "managed-csi-fast" not found` hatası görülür.
   * **Çözüm:** `values.yaml` içindeki `storageClassName: "managed-csi-fast"` değerini AKS'nin standart sınıfı olan `"managed-csi"` (veya `"default"`) olarak değiştir. (Mevcut hatalı PVC'yi silip `kubectl delete statefulset,pvc --all -n storefront-prod` ile yenile).

2. **Hata 2 — Secret Anahtar Uyuşmazlığı (`CreateContainerConfigError`):**
   * **Belirti:** `storefront-cache-0` podu diski bağladıktan sonra `CreateContainerConfigError` verir.
   * **Kök Neden:** `config-and-secret.yaml` içinde Secret anahtarı `REDIS_PASSWORD` olarak tanımlanmış ama `cache-statefulset.yaml` içinde `key: CACHE_TOKEN` aranıyor.
   * **Çözüm:** `cache-statefulset.yaml` içindeki `secretKeyRef.key` değerini `REDIS_PASSWORD` yap.

3. **Hata 3 — NetworkPolicy Etiket ve Port Hatası (`Init:0/1` Takılması):**
   * **Belirti:** `storefront-cache-0` `Running` olur ancak `storefront-web` podları `Init:0/1` aşamasında (`Waiting for Redis cache...`) takılı kalır.
   * **Kök Neden:** `network-and-ingress.yaml` içindeki `cache-isolation-policy` sadece `tier: backend` etiketli podlardan ve `6380` portundan gelen trafiğe izin veriyor. Oysa web podlarının etiketi `tier: frontend` ve Redis portu `6379`.
   * **Çözüm:** NetworkPolicy içindeki `tier: backend` değerini `tier: frontend`, portu ise `6379` yap.

4. **Hata 4 — Kırık Container Image Tag (`ImagePullBackOff` / `ErrImagePull`):**
   * **Belirti:** InitContainer başarılı olur (`Init:Completed`), ancak ana container `ImagePullBackOff` hatasına düşer.
   * **Kök Neden:** `values.yaml` içinde `tag: "1.27-alpine-slim-rc99"` şeklinde var olmayan bir tag girilmiş.
   * **Çözüm:** `values.yaml` içinde `tag: "1.27-alpine"` (veya `"stable-alpine"`) olarak düzelt.

5. **Hata 5 — Liveness/Readiness Probe Yolu (`CrashLoopBackOff` & `0/1 Ready`):**
   * **Belirti:** İmaj iner ama container sürekli restart atar ve `404 Not Found` probe hatası verir.
   * **Kök Neden:** `config-and-secret.yaml` içindeki Nginx ayarında sağlık kontrolü `/ready` olarak yazılmış ama `values.yaml` içinde `probePath: /healthz` verilmiş.
   * **Çözüm:** `values.yaml` içindeki `probePath` değerini `/ready` yap.

6. **Hata 6 — Service Selector & TargetPort (`503 Service Unavailable` / Boş Endpoint):**
   * **Belirti:** Tüm podlar `1/1 Running` olur ama siteye girildiğinde hala `503` döner. `kubectl get ep -n storefront-prod` çıktısında `storefront-web-svc` karşısı `<none>` (boş) görünür.
   * **Kök Neden:** `network-and-ingress.yaml` içindeki Service `tier: web-ui` etiketini arıyor (podlarda `tier: frontend` var) ve `targetPort: 80` yönlendiriyor (unprivileged nginx `8080` portunu dinliyor).
   * **Çözüm:** Service içindeki selector'ı `tier: frontend`, `targetPort` değerini ise `{{ .Values.webapp.containerPort }}` (`8080`) yap.

</details>
