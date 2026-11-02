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

# 3. Bozuk v2.4.0 Sürümünü Dağıt
cd ../
kubectl create namespace storefront-prod
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
