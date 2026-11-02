# Game Day 03 — NetworkChaos: `order-api` ↔ RabbitMQ Ağ Bölünmesi (Network Partition)

**Manifest:** [`chaos/experiments/03-network-partition-rabbitmq.yaml`](../experiments/03-network-partition-rabbitmq.yaml)  
**Hedef Bileşen:** `order-api` (`mode: one`) ↔ `rabbitmq` (`namespace: messaging`)  
**Kaos Türü:** `NetworkChaos` (`action: partition`, `direction: both`, `duration: 2m`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** `order-api` pod'larından biri ile RabbitMQ arasına iki yönlü tam ağ bölünmesi (`iptables DROP`) girdiğinde:
> 1. İzole edilen `order-api` pod'u RabbitMQ'ya bağlanırken sonsuza kadar asılı kalmaz; **kısa timeout + Circuit Breaker (`OPEN`)** sayesinde hızlıca hata/fallback döner.
> 2. Siparişin ana kaydı (`PostgreSQL`) kritik yol olduğu için kaydedilmeye devam eder (graceful degradation / outbox yaklaşımı).
> 3. Diğer `order-api` replikası RabbitMQ'ya erişebildiği için sistem genelinde görevler işlenmeye devam eder; bozuk mesajlar ise 3 deneme sonunda kaybolmak yerine **`payments.dlq` (Dead-Letter Queue)** kuyruğuna düşer.

**Neden Prod'da Önemli?**  
Bulut ortamlarında (AWS, Azure, GCP) iki Availability Zone arasındaki sanal ağda kısmi kopmalar (partial network partition) sıkça yaşanır: Pod A veritabanını görür ama mesaj kuyruğunu göremezken, Pod B her ikisini de görebilir. Eğer uygulama içinde **Circuit Breaker (Devre Kesici)** yoksa, erişilemeyen RabbitMQ yüzünden tüm HTTP worker thread'leri TCP timeout beklerken kilitlenir (thread pool exhaustion) ve tüm API çöker!

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

```promql
# 1) RabbitMQ bağımlılık durumu her iki API podunda da == 1
min(rs_dependency_up{dependency="rabbitmq"}) == 1

# 2) RabbitMQ devre kesicisi CLOSED (0) durumunda
max(rs_circuit_breaker_state{dependency="rabbitmq"}) == 0

# 3) DLQ'ya düşen mesaj artış hızı == 0
sum(rate(rs_rabbitmq_messages_processed_total{result="dlq"}[5m])) == 0
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `app` namespace'indeki **yalnızca 1 adet** `order-api` pod'u (`mode: one`) ile `messaging` namespace'indeki `rabbitmq` pod'u arasındaki çift yönlü (`direction: both`) trafik.
- **Diğer Bileşenler:** `payment-worker` ↔ `rabbitmq` iletişimi ve ikinci `order-api` pod'u ↔ `rabbitmq` iletişimi **açık kalır**.
- **Süre:** `2m` (120 saniye).

---

## 4. Abort (Acil Durdurma) Koşulları

1. `order-api` pod'larının `/readyz` uç noktası başarısız olup Kubernetes her iki pod'u da Service dışına çıkarırsa (Kritik tasarım kuralı: `/readyz` sadece PostgreSQL'e bakmalıdır, RabbitMQ kesintisi pod'u `Unready` yapmamalıdır!).
2. Genel HTTP 5xx hata oranı %5'i geçerse.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/03-network-partition-rabbitmq.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Başlangıç Metriklerini Kontrol Edin
```bash
kubectl get pods -n app -o wide
kubectl get pods -n messaging -o wide
```

### Adım 2: Ağ Bölünmesini (Partition) Uygulayın
```bash
kubectl apply -f chaos/experiments/03-network-partition-rabbitmq.yaml
```

### Adım 3: Sipariş Gönderin ve Devre Kesiciyi Tetikleyin
İsteklerin yarısı sağlam pod'a, yarısı izole edilmiş pod'a gidecektir:
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
for i in $(seq 1 40); do
  curl -s -w "\n[İstek $i] HTTP:%{http_code} Süre:%{time_total}s\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"cust-part-$i\",\"product_id\":\"sku-3\",\"quantity\":1,\"amount\":99.50}"
  sleep 1
done
```

### Adım 4: Devre Kesici ve Sağlık Metriklerini Canlı Sorgulayın
```bash
# Her bir order-api podunun kendi gözünden RabbitMQ durumunu kontrol edin
for pod in $(kubectl get pods -n app -l app.kubernetes.io/component=order-api -o name); do
  echo "=== $pod ==="
  kubectl exec -n app "$pod" -- curl -s localhost:8000/metrics | grep -E 'rs_dependency_up\{dependency="rabbitmq"\}|rs_circuit_breaker_state\{dependency="rabbitmq"\}'
done
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **İzole Edilen Pod'un Davranışı:**
   - Arka plan sağlık kontrol thread'i (her 5 saniyede bir çalışır) RabbitMQ'ya TCP/AMQP bağlantısı kuramaz ve `rs_dependency_up{dependency="rabbitmq"}` metriğini **`0`** yapar.
   - Ardışık başarısız gönderimlerden sonra `rs_circuit_breaker_state{dependency="rabbitmq"}` değeri **`0` (CLOSED) → `2` (OPEN)** olur.
   - Circuit Breaker açıldıktan sonra gelen sipariş istekleri RabbitMQ timeout'unu (örn. 2-3 sn) **beklemez**, anında (<20ms) fallback/kayıt yaparak yanıt döner!
2. **Grafana Panelleri:**
   - **Chaos Game Day Dashboard:** `rs_circuit_breaker_state` grafiğinde RabbitMQ çizgisi `2` seviyesine çıkar.
   - **Messaging Dashboard:** Sağlam pod üzerinden giden mesajlar `rs_rabbitmq_messages_processed_total{result="success"}` sayacını artırmaya devam eder.
3. **Alarmlar:**
   - **10–15 saniye içinde** `RSDependencyDown` (`dependency="rabbitmq"`) ve `RSCircuitBreakerOpen` alarmları `Firing` durumuna geçer.

---

## 7. Toparlanma (Recovery) ve Temizlik

2 dakika dolduğunda (veya manuel silindiğinde):
```bash
# Deneyi kaldır
kubectl delete -f chaos/experiments/03-network-partition-rabbitmq.yaml

# 15 saniye bekle ve devre kesicinin HALF-OPEN (1) -> CLOSED (0) geçişini doğrula
sleep 15
for pod in $(kubectl get pods -n app -l app.kubernetes.io/component=order-api -o name); do
  echo "=== $pod ==="
  kubectl exec -n app "$pod" -- curl -s localhost:8000/metrics | grep -E 'rs_dependency_up\{dependency="rabbitmq"\}|rs_circuit_breaker_state\{dependency="rabbitmq"\}'
done
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **Transactional Outbox Pattern:** Üretim ortamında "Postgres'e yazdım ama tam o sırada RabbitMQ ağı koptu, ödeme görevi kayboldu mu?" sorusunun kesin çözümü **Transactional Outbox** desenidir. `order-api`, siparişi `orders` tablosuna yazarken aynı veritabanı transaction'ı içinde `outbox_events` tablosuna da yazar. Ayrı bir relay/worker süreci (veya Debezium CDC) `outbox_events` tablosunu okuyup RabbitMQ'ya gönderir. Ağ kopsa bile kayıt Postgres diskinde güvendedir.
- **RabbitMQ Quorum Queues & Split-Brain:** Prod'da RabbitMQ 3 veya 5 node'lu küme olarak kurulur ve klasik kuyruklar yerine **Raft tabanlı Quorum Queues** kullanılır. Ağ bölünmesi (split-brain) yaşandığında çoğunluğa (`(N/2)+1`, yani 3 node'da 2 node) sahip olan taraf yazma kabul etmeye devam ederken, azınlıkta kalan node veri tutarsızlığını önlemek için kendini durdurur.
