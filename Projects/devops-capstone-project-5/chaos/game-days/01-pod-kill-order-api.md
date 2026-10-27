# Game Day 01 — PodChaos: `order-api` Ani Pod Çöküşü (SIGKILL)

**Manifest:** [`chaos/experiments/01-pod-kill-order-api.yaml`](../experiments/01-pod-kill-order-api.yaml)  
**Hedef Bileşen:** `order-api` (`namespace: app`, 2 replica)  
**Kaos Türü:** `PodChaos` (`action: pod-kill`, `gracePeriod: 0`, `mode: one`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** `order-api` servisi 2 replica olarak çalıştığı, önünde Kubernetes Service / Ingress NGINX yük dengeleyici bulunduğu ve `PodDisruptionBudget (minAvailable: 1)` ile korunduğu için; pod'lardan biri aniden (`SIGKILL`, `gracePeriod: 0`) öldürüldüğünde kullanıcı tarafında HTTP 5xx hata oranı **%1 SLO sınırını aşmaz** ve yeni pod **30 saniye içinde** `Ready` durumuna gelerek kapasiteyi eski haline döndürür.

**Neden Prod'da Önemli?**  
Üretim ortamında süreçler her zaman nazikçe (`SIGTERM`) kapanmaz. Donanım arızası, kernel panic, node OOM killer veya hipervizör çökmesi durumunda süreç anında yok olur. Uygulama mimarimiz tek bir pod'un aniden kaybolmasını kullanıcıya hissettirmemelidir.

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

Deneye başlamadan önce sistemin sağlıklı olduğundan emin olmak için Grafana **SLO Overview** veya Prometheus UI üzerinden aşağıdaki PromQL sorgularını doğrulayın:

```promql
# 1) Çalışan ve Ready olan order-api pod sayısı == 2 olmalı
 count(kube_pod_status_ready{namespace="app", condition="true", pod=~"order-api-.*"}) == 2

# 2) Son 1 dakikadaki HTTP 5xx hata oranı == 0 olmalı
sum(rate(rs_http_requests_total{status=~"5.."}[1m])) / clamp_min(sum(rate(rs_http_requests_total[1m])), 1) == 0

# 3) p99 sipariş oluşturma gecikmesi < 500ms (0.5s) olmalı
histogram_quantile(0.99, sum by (le) (rate(rs_http_request_duration_seconds_bucket{endpoint="/api/orders"}[1m]))) < 0.5

# 4) Tüm altyapı bağımlılıkları ayakta (1) olmalı
min(rs_dependency_up) == 1
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** Sadece `app` namespace'i içindeki `app.kubernetes.io/component: order-api` etiketli pod'lar.
- **Mod:** `mode: one` — Aynı anda yalnızca **rastgele 1 adet** pod öldürülür (kapasitenin %50'si korunur).
- **Süre:** `duration: "60s"` — Deney penceresi 60 saniye sonunda otomatik kapanır.
- **Veri Katmanı Etkisi:** Yok (`data` ve `messaging` namespace'lerine dokunulmaz).

---

## 4. Abort (Acil Durdurma) Koşulları

Aşağıdaki durumlardan biri gerçekleşirse deneyi **derhal durdurun**:
1. Her iki `order-api` pod'u da aynı anda `CrashLoopBackOff` veya `Pending` durumuna düşerse (hata oranı %100'e çıkarsa).
2. HTTP 5xx oranı 30 saniyeden uzun süre **%5'in üzerinde** kalırsa.
3. Yeni oluşturulan pod `Insufficient cpu` veya `Insufficient memory` nedeniyle schedule edilemezse.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/01-pod-kill-order-api.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Gözlem Terminali Açın (Terminal 1)
Pod durumlarını canlı izlemek için ayrı bir terminalde şu komutu başlatın:
```bash
kubectl get pods -n app -l app.kubernetes.io/component=order-api -o wide -w
```

### Adım 2: Hafif Trafik Başlatın (Terminal 2)
Etkiyi görmek için saniyede 2 sipariş gönderen basit bir döngü (veya k6) çalıştırın:
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
while true; do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"gameday-01","product_id":"sku-1","quantity":1,"amount":49.90}'
  sleep 0.5
done
```

### Adım 3: Kaos Deneyini Enjekte Edin (Terminal 3)
```bash
kubectl apply -f chaos/experiments/01-pod-kill-order-api.yaml
```

### Adım 4: Chaos Mesh Durumunu Sorgulayın
```bash
kubectl get podchaos -n chaos-mesh pod-kill-order-api -o yaml
kubectl describe podchaos -n chaos-mesh pod-kill-order-api
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **Kubernetes Katmanı:**
   - `order-api` pod'larından biri anında `Terminating` / `Completed` olur ve ReplicaSet saniyeler içinde yeni bir pod (`ContainerCreating` -> `Running`) başlatır.
   - Yeni podun `/readyz` kontrolü PostgreSQL bağlantısını doğrulayana kadar (yaklaşık 3–5 sn) kube-proxy ve Ingress NGINX trafiği yalnızca hayatta kalan diğer pod'a yönlendirir.
2. **Grafana Panelleri (Chaos Game Day & SLO Overview):**
   - **HTTP 2xx vs 5xx:** Tam ölüm anında o pod üzerinde uçuşta (in-flight) olan 1 istek varsa tekil bir `502 Bad Gateway` görülebilir; ancak genel başarı oranı **>%99** kalır.
   - **Aktif Deneyler Paneli:** `PodChaos / pod-kill-order-api` aktif olarak görünür.
3. **Alarmlar:**
   - Tek seferlik pod ölümü `RSPodCrashLooping` alarmını **tetiklememelidir** (çünkü alarm `increase(kube_pod_container_status_restarts_total[10m]) > 3` koşuluna bakar; tek bir hata gürültü yaratmamalıdır).
   - `RSHighErrorRate` (SLO burn rate) alarmı **ateşlenmemelidir**.

---

## 7. Toparlanma (Recovery) ve Temizlik

Deney nesnesini silin ve sistemin Steady State'e döndüğünü doğrulayın:
```bash
# Deneyi temizle
kubectl delete -f chaos/experiments/01-pod-kill-order-api.yaml

# İki podun da 1/1 Ready olduğunu doğrula
kubectl get pods -n app -l app.kubernetes.io/component=order-api
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **`gracePeriod: 0` vs `gracePeriod: 30`:** Bu deneyde en kötü senaryoyu (`SIGKILL`) test ettik. Normal dağıtımlarda (rolling update) Kubernetes önce pod'u Service Endpoint listesinden çıkarır, paralel olarak `SIGTERM` gönderir. Prod'da Uvicorn/FastAPI sunucusuna `--timeout-graceful-shutdown 15` ve pod'a `preStop: sleep 5` kancası eklenir ki Ingress NGINX endpoint değişimini fark edene kadar pod yeni bağlantı kabul etmeyi bıraksın ve mevcut istekleri tamamlasın (Zero-Downtime Deployment).
- **Anti-Affinity:** Lab'da tek bir uygulama sunucumuz (`vm-worker-app`) olduğu için her iki `order-api` pod'u aynı VM üzerinde çalışır. Prod'da `topologySpreadConstraints` veya `podAntiAffinity` ile bu iki pod farklı Availability Zone'lardaki (AZ-1, AZ-2) sunuculara dağıtılır.
