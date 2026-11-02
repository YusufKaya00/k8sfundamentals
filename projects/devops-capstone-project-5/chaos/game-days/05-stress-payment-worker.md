# Game Day 05 — StressChaos: `payment-worker` CPU ve Bellek Baskısı

**Manifest:** [`chaos/experiments/05-stress-payment-worker.yaml`](../experiments/05-stress-payment-worker.yaml)  
**Hedef Bileşen:** `payment-worker` (`namespace: app`)  
**Kaos Türü:** `StressChaos` (`cpu: 1 worker @ 80%`, `memory: 200MB`, `duration: 3m`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** Ödeme işçisi (`payment-worker`) konteyneri içinde yoğun CPU (%80 yük) ve bellek (`200MB`) baskısı oluştuğunda:
> 1. Kubernetes cgroup sınırları (`resources.limits`) sayesinde bu stres aynı node (`vm-worker-app`) üzerindeki `order-api`, `rabbitmq` veya `redis` pod'larını **boğmaz (Noisy Neighbor izolasyonu)**.
> 2. CPU kısıtlaması (throttling) nedeniyle ödeme işleme hızı düşse bile **hiçbir ödeme mesajı kaybolmaz** (RabbitMQ `manual ack` mekanizması).
> 3. Eğer bellek kullanımı pod limitini aşacak şekilde artırılırsa ve pod `OOMKilled` (Exit Code 137) olursa, işlenmekte olan (henüz `ack` edilmemiş) mesaj RabbitMQ tarafından otomatik olarak kuyruğa geri koyulur ve yeni başlayan pod tarafından idempotent biçimde işlenir.

**Neden Prod'da Önemli?**  
Üretimde bir worker pod'u beklenmedik büyüklükte bir payload aldığında veya bir kütüphanede bellek sızıntısı (memory leak) olduğunda CPU/RAM tüketimi fırlar. Eğer cgroup limitleri ve mesaj onay (`ack`) mimarisi doğru kurulmamışsa, hem aynı sunucudaki diğer servisler çöker hem de o an bellekte olan ödeme işlemleri buharlaşır.

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

```promql
# 1) payment-worker podu Running ve restart sayısı son 10 dakikada 0
increase(kube_pod_container_status_restarts_total{namespace="app", pod=~"payment-worker-.*"}[10m]) == 0

# 2) vm-worker-app node kullanılabilir bellek oranı > %15
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.15

# 3) Başarılı işlenen RabbitMQ mesajları akıyor
sum(rate(rs_rabbitmq_messages_processed_total{result="success"}[1m])) >= 0
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `app` namespace'indeki `app.kubernetes.io/component: payment-worker` pod'u.
- **CPU Sınırı:** `workers: 1, load: 80` — `vm-worker-app` sunucusunda 2 vCPU bulunduğu için tek çekirdeğin %80'ini meşgul eder; sunucunun tamamını kilitlemez.
- **Bellek Sınırı:** `size: "200MB"` — Varsayılan olarak pod'u hemen öldürmeden yüksek bellek baskısı altında çalıştırır (İsteğe bağlı OOMKilled testi için adım 5'te nasıl artırılacağı gösterilmiştir).
- **Süre:** `3m`.

---

## 4. Abort (Acil Durdurma) Koşulları

1. `vm-worker-app` node'unun tamamında bellek %90'ı aşıp `RSNodeMemoryHigh` alarmı çalar ve kubelet diğer pod'ları (`order-api`, `rabbitmq`) tahliye etmeye (evict) başlarsa.
2. Node SSH veya kubelet yanıt vermez hale gelirse.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/05-stress-payment-worker.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Başlangıç Kaynak Kullanımını Ölçün
```bash
kubectl top pods -n app
kubectl top nodes
```

### Adım 2: Stres Deneyini Başlatın (`stress-ng` enjeksiyonu)
Chaos Daemon, hedef konteynerin cgroup'u içine `stress-ng` süreçleri enjekte eder:
```bash
kubectl apply -f chaos/experiments/05-stress-payment-worker.yaml
```

### Adım 3: Yük Altında Ödeme Görevleri Gönderin
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
for i in $(seq 1 30); do
  curl -s -o /dev/null -w "[Sipariş $i] HTTP:%{http_code}\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"cust-stress-$i\",\"product_id\":\"sku-5\",\"quantity\":1,\"amount\":150.0}"
  sleep 0.5
done
```

### Adım 4: CPU Throttling ve Pod Kaynaklarını Gözlemleyin
```bash
# 15-20 saniye sonra top çıktısını tekrar kontrol edin
kubectl top pods -n app
kubectl get hpa -n app
kubectl describe stresschaos -n chaos-mesh stress-payment-worker
```

### Adım 5 (Opsiyonel İleri Seviye): Bilinçli `OOMKilled` ve Mesaj Kurtarma Testi
Eğer pod'un bellek limitini aşıp `OOMKilled` olduğunda RabbitMQ'nun mesajı kaybetmediğini kanıtlamak isterseniz:
```bash
# Bellek stresini pod limitinin (örn. 256Mi/512Mi) üzerine çıkaracak şekilde patch'leyin:
kubectl patch stresschaos stress-payment-worker -n chaos-mesh \
  --type='merge' -p '{"spec":{"stressors":{"memory":{"workers":1,"size":"600MB"}}}}'

# Pod'un OOMKilled (Exit Code 137) olup yeniden başladığını izleyin:
kubectl get pods -n app -l app.kubernetes.io/component=payment-worker -w
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **Kaynak İzolasyonu:**
   - `kubectl top pods -n app` çıktısında `payment-worker` CPU ve bellek kullanımının fırladığı, ancak `order-api` pod'larının normal değerlerinde kaldığı görülür.
2. **HPA (Horizontal Pod Autoscaler):**
   - CPU kullanımı HPA hedef eşiğinin (örn. %70) üzerinde 1–2 dakika boyunca kalırsa, Kubernetes HPA `payment-worker` replika sayısını otomatik olarak artırır.
3. **OOMKilled Durumunda (Adım 5 uygulanırsa):**
   - `kubectl describe pod -n app -l app.kubernetes.io/component=payment-worker` çıktısında `Last State: Terminated, Reason: OOMKilled, Exit Code: 137` görülür.
   - Eğer 10 dakika içinde >3 kez tekrarlarsa `RSPodCrashLooping` alarmı tetiklenir (`docs/02-troubleshooting-playbook.md#pod-restarts`).

---

## 7. Toparlanma (Recovery) ve Temizlik

```bash
# Stres deneyini sil (stress-ng süreçleri anında sonlandırılır)
kubectl delete -f chaos/experiments/05-stress-payment-worker.yaml

# Pod durumunu ve işlenen mesaj sayısını doğrula
kubectl get pods -n app -l app.kubernetes.io/component=payment-worker
kubectl exec -n app deploy/payment-worker -- curl -s localhost:8000/metrics | grep rs_rabbitmq_messages_processed_total
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **Neden `basic_ack` İşlem Bittikten Sonra Gönderilir?** Eğer RabbitMQ tüketicisinde `auto_ack=True` kullanırsanız, RabbitMQ mesajı pod'a gönderdiği anda siler. Pod mesajı işlerken `OOMKilled` olursa o ödeme sonsuza dek kaybolur! `ResilienceStream`'de `auto_ack=False` kullanılır; önce ödeme PostgreSQL `payments` tablosuna commit edilir, **ancak ondan sonra** RabbitMQ'ya `basic_ack` gönderilir.
- **Idempotency (Tekrarlanabilirlik):** Peki ya `payment-worker` ödemeyi Postgres'e yazdıktan tam 1 milisaniye sonra, henüz `ack` gönderemeden `OOMKilled` olursa? Yeni pod mesajı tekrar alır. Müşteriden iki kez para çekmemek için `payments` tablosunda `order_id` üzerinde `UNIQUE` kısıtı (`ON CONFLICT (order_id) DO NOTHING`) vardır. Buna **Idempotent Consumer** denir.
