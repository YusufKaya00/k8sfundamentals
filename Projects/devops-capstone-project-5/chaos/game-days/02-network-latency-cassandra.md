# Game Day 02 — NetworkChaos: Apache Cassandra'ya 300ms Ağ Gecikmesi

**Manifest:** [`chaos/experiments/02-network-latency-cassandra.yaml`](../experiments/02-network-latency-cassandra.yaml)  
**Hedef Bileşen:** `cassandra` (`namespace: data`) ← `app` namespace'inden gelen trafik  
**Kaos Türü:** `NetworkChaos` (`action: delay`, `latency: 300ms`, `jitter: 50ms`, `duration: 3m`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** Analitik veritabanı olan Apache Cassandra'ya giden ağ trafiğinde `300ms ± 50ms` gecikme yaşandığında; `order-api` Cassandra'ya doğrudan yazmadığı (olayları asenkron olarak Kafka `orders.events` topic'ine bıraktığı) için **sipariş verme uç noktasının (`POST /api/orders`) p99 gecikmesi ve başarı oranı bundan hiç etkilenmez**. Yavaşlama yalnızca `analytics-consumer` üzerinde görülür, Kafka consumer lag (`rs_kafka_consumer_lag`) geçici olarak artar ve deney bittiğinde sıfıra iner.

**Neden Prod'da Önemli?**  
Mikroservis mimarisinde en ölümcül tasarım hatası, analitik veya raporlama gibi **kritik olmayan** bir yan işlemi kullanıcının senkron sipariş akışına bağlamaktır. Eğer `order-api` doğrudan Cassandra'ya yazsaydı, Cassandra'daki 300ms'lik bir disk/ağ yavaşlaması tüm e-ticaret sitesinin sipariş almasını yavaşlatacaktı. Event-Driven (Kafka) mimarisi bu iki dünyayı birbirinden ayırır (decoupling).

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

Deney öncesi Prometheus / Grafana üzerinden aşağıdaki metrikleri kontrol edin:

```promql
# 1) Cassandra bağımlılık durumu == 1 (UP)
rs_dependency_up{dependency="cassandra"} == 1

# 2) Cassandra sağlık kontrolü gecikmesi (p95) < 50ms (0.05s)
histogram_quantile(0.95, sum by (le) (rate(rs_dependency_latency_seconds_bucket{dependency="cassandra"}[1m]))) < 0.05

# 3) Kafka consumer lag == 0 (veya < 5)
max(rs_kafka_consumer_lag) < 5

# 4) order-api p99 gecikmesi < 500ms
histogram_quantile(0.99, sum by (le) (rate(rs_http_request_duration_seconds_bucket{endpoint="/api/orders"}[1m]))) < 0.5
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Hedef Seçici:** `data` namespace'indeki `app.kubernetes.io/name: cassandra` pod'u.
- **Yön Sınırlaması (`direction: from`, `target: app`):** Gecikme **yalnızca** `app` namespace'i ile `cassandra` pod'u arasındaki paketlere (Linux `tc netem` ile) uygulanır. `monitoring` namespace'i veya cluster içi diğer bileşenler etkilenmez.
- **Süre:** `3m` (180 saniye sonra `tc` kuralları Chaos Daemon tarafından otomatik silinir).

---

## 4. Abort (Acil Durdurma) Koşulları

Aşağıdaki durumlardan biri oluşursa deneyi derhal sonlandırın:
1. `order-api` HTTP 5xx oranı %1'i aşarsa (asenkron izolasyonun çalışmadığını gösterir!).
2. `analytics-consumer` pod'u bellek sızıntısı nedeniyle `OOMKilled` olursa.
3. Cassandra pod'u Liveness probe zaman aşımı nedeniyle Kubernetes tarafından yeniden başlatılırsa.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/02-network-latency-cassandra.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Sipariş Trafiği Üretin (Terminal 1)
Kafka'ya sürekli event akması için saniyede birkaç sipariş gönderin:
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
for i in $(seq 1 200); do
  curl -s -o /dev/null -w "[Sipariş $i] HTTP:%{http_code} Süre:%{time_total}s\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"cust-$i\",\"product_id\":\"sku-10\",\"quantity\":2,\"amount\":125.0}"
  sleep 0.3
done
```

### Adım 2: Ağ Gecikmesini Başlatın (Terminal 2)
```bash
kubectl apply -f chaos/experiments/02-network-latency-cassandra.yaml
```

### Adım 3: Deney ve Consumer Loglarını İzleyin
```bash
# NetworkChaos durumunu kontrol et
kubectl get networkchaos -n chaos-mesh network-latency-cassandra

# analytics-consumer loglarında Cassandra yazım sürelerini ve olası circuit breaker mesajlarını izle
kubectl logs -n app -l app.kubernetes.io/component=analytics-consumer -f --tail=50
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **Grafana — Messaging (Kafka vs RabbitMQ) & Chaos Game Day Dashboard:**
   - **Bağımlılık Gecikmesi (`rs_dependency_latency_seconds{dependency="cassandra"}`):** 5–10ms seviyesinden aniden **300–350ms** bandına fırlar.
   - **Kafka Consumer Lag (`rs_kafka_consumer_lag`):** `analytics-consumer` her bir mesajı Cassandra'ya yazarken +300ms beklediği için, Kafka'ya giren mesaj hızına yetişemez ve **Consumer Lag eğrisi yukarı doğru tırmanır**.
   - **`order-api` p99 Latency:** Sipariş API'si sadece Postgres, Kafka ve RabbitMQ ile konuştuğu için yanıt süresi **değişmez (<100ms kalır)**. Kullanıcılar yavaşlığı hiç hissetmez!
2. **Alarmlar:**
   - Eğer lag 100 mesajı aşarsa `RSKafkaConsumerLagHigh` alarmı `Pending` -> `Firing` durumuna geçebilir (`docs/02-troubleshooting-playbook.md#consumer-lag`).
   - Eğer gecikme veya zaman aşımı üst üste hata üretirse `RSCircuitBreakerOpen{dependency="cassandra"}` tetiklenir.

---

## 7. Toparlanma (Recovery) ve Temizlik

3 dakika dolduğunda (veya manuel sildiğinizde) sistemin kendini nasıl iyileştirdiğini izleyin:
```bash
# Deneyi sonlandır
kubectl delete -f chaos/experiments/02-network-latency-cassandra.yaml

# Consumer lag'in hızla 0'a indiğini Prometheus metriklerinden doğrula
kubectl exec -n app deploy/analytics-consumer -- curl -s localhost:8000/metrics | grep -E "rs_kafka_consumer_lag|rs_kafka_events_consumed_total"
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **Speculative Execution (Spekülatif Çalıştırma):** Üretim ortamında Cassandra **3+ node (`RF=3`, `LOCAL_QUORUM`)** olarak çalışır. Eğer tek bir Cassandra node'unda (örneğin GC pause veya disk arızası yüzünden) 300ms gecikme olursa, Cassandra sürücüsü (DataStax Python Driver) **Speculative Execution** özelliği sayesinde 50ms sonunda yanıt alamadığı sorguyu otomatik olarak ikinci bir replikaya paralel gönderir ve hızlı dönen yanıtı alır. Lab ortamımızda tek node olduğu için bu gecikmeyi doğrudan absorbe etmek zorundayız.
- **Kafka'nın Tampon (Buffer) Rolü:** Kafka burada bir "şok emici (shock absorber)" görevi görür. Veritabanı yavaşladığında veriyi diskte (`orders.events`) güvenle tutar, veritabanı hızlandığında ise biriken kuyruğu (lag) eritir.
