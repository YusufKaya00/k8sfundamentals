# Game Day 04 — PodChaos: Kafka KRaft Broker Çöküşü ve Toparlanma

**Manifest:** [`chaos/experiments/04-kafka-broker-kill.yaml`](../experiments/04-kafka-broker-kill.yaml)  
**Hedef Bileşen:** `kafka` (`namespace: data`, StatefulSet `kafka-controller-0`)  
**Kaos Türü:** `PodChaos` (`action: pod-kill`, `gracePeriod: 0`, `duration: 60s`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** Lab ortamındaki tek Kafka KRaft broker'ı (`kafka-controller-0`) aniden öldürüldüğünde:
> 1. `order-api` içinde Kafka devre kesicisi (`RSCircuitBreakerOpen`) ve arka plan sağlık kontrolü (`rs_dependency_up{dependency="kafka"} == 0`) **15 saniye içinde** durumu tespit eder ve sipariş kaydının (PostgreSQL) bloke olmasını engeller.
> 2. Kubernetes StatefulSet, Kafka pod'unu aynı PersistentVolumeClaim (`local-path`) ile yeniden başlatır; diskteki önceden yazılmış `orders.events` mesajları **kaybolmaz**.
> 3. Broker ayağa kalktığında `analytics-consumer` bağlantıyı otomatik yeniler ve biriken consumer lag **5 dakika içinde sıfırlanır**.

**Neden Prod'da Önemli?**  
Olay güdümlü (event-driven) sistemlerde mesaj otobüsünün (Kafka) çökmesi veya lider değişimi (leader election) yaşamasının hem yayıncı (producer) hem de tüketici (consumer) tarafından insan müdahalesi olmadan (self-healing) atlatılması şarttır. Yeniden bağlanma mantığı (reconnection loop) hatalı yazılmış consumer'lar broker koptuğunda sessizce donup kalır (zombie consumer)!

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

```promql
# 1) Kafka bağımlılık durumu == 1
min(rs_dependency_up{dependency="kafka"}) == 1

# 2) Kafka consumer lag == 0
max(rs_kafka_consumer_lag) == 0

# 3) Kafka podu Running ve Ready
kube_pod_status_ready{namespace="data", pod=~"kafka-.*", condition="true"} == 1
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `data` namespace'indeki `app.kubernetes.io/name: kafka` pod'u.
- **Lab Kısıtı Uyarısı:** Lab'da 6 vCPU / 4 GB RAM (`vm-worker-data`) sınırı nedeniyle **tek broker (`Replication Factor = 1`)** çalışmaktadır. Bu nedenle broker öldüğü ~30–45 saniye boyunca Kafka kümesi geçici olarak erişilemez olacaktır. (Prod'daki 3 broker farkı için Bölüm 8'e bakın).
- **Kalıcı Disk:** Kafka verileri `/bitnami/kafka` PVC üzerinde durduğu için pod silinse de commit edilmiş log segmentleri silinmez.

---

## 4. Abort (Acil Durdurma) Koşulları

1. Kafka pod'u yeniden başlarken PVC bağlanamazsa (`Multi-Attach error` veya `local-path` hatası) ya da `CrashLoopBackOff`'a girerse.
2. `vm-worker-data` üzerinde bellek yetersizliğinden (`OOMKilled`) PostgreSQL veya Cassandra etkilenirse.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/04-kafka-broker-kill.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Data Node Üzerindeki Podları İzleyin (Terminal 1)
```bash
kubectl get pods -n data -o wide -w
```

### Adım 2: Kaos Deneyini Başlatın (Terminal 2)
```bash
kubectl apply -f chaos/experiments/04-kafka-broker-kill.yaml
```

### Adım 3: Broker Kapalıyken ve Açılırken Sipariş Gönderin
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
for i in $(seq 1 30); do
  curl -s -w "\n[Sipariş $i] HTTP:%{http_code} Süre:%{time_total}s\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"cust-kafka-$i\",\"product_id\":\"sku-4\",\"quantity\":1,\"amount\":75.0}"
  sleep 2
done
```

### Adım 4: Consumer Loglarını ve Lag'i Takip Edin
```bash
kubectl logs -n app -l app.kubernetes.io/component=analytics-consumer --tail=40 -f
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **T+0s – T+10s (Çöküş ve Tespit):**
   - `kafka-controller-0` pod'u `SIGKILL` ile kapanır ve StatefulSet hemen yeni `kafka-controller-0` pod'unu başlatır.
   - `order-api` arka plan sağlık kontrolü `rs_dependency_up{dependency="kafka"}` değerini `0`'a çeker.
   - `RSDependencyDown{dependency="kafka"}` alarmı **<15 saniye içinde** ateşlenir.
2. **T+10s – T+45s (Broker Başlangıç Süresi):**
   - `order-api` üzerindeki Kafka devre kesicisi (`rs_circuit_breaker_state{dependency="kafka"}`) `2 (OPEN)` durumuna geçerek sipariş uç noktasının Kafka timeout'u yüzünden yavaşlamasını engeller.
3. **T+45s – T+90s (Toparlanma):**
   - Kafka KRaft metadata loglarını okuyup `1/1 Ready` olur.
   - `rs_dependency_up{dependency="kafka"}` tekrar `1` olur, devre kesici `CLOSED (0)` durumuna döner ve `analytics-consumer` yeni eventleri tüketip Cassandra'ya yazar (`rs_kafka_events_consumed_total` artmaya devam eder).

---

## 7. Toparlanma (Recovery) ve Temizlik

```bash
# Deney nesnesini temizle
kubectl delete -f chaos/experiments/04-kafka-broker-kill.yaml

# Kafka podunun Running/Ready olduğunu ve consumer'ın çalıştığını doğrula
kubectl get pods -n data -l app.kubernetes.io/name=kafka
kubectl exec -n app deploy/analytics-consumer -- curl -s localhost:8000/metrics | grep rs_kafka
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

Lab ortamında RAM kısıtı yüzünden tek broker (`RF=1`) kullandığımız için broker yeniden başlayana kadar (~40 sn) Kafka yazmaları kesintiye uğradı. **Gerçek üretim (Production) ortamında Kafka nasıl kurulur?**
1. **En Az 3 Broker (KRaft Combined veya Ayrı Controller/Broker):** 3 farklı Availability Zone'a dağılmış en az 3 broker çalışır.
2. **`replication.factor=3`:** `orders.events` topic'inin her bir partition'ı 3 broker'a kopyalanır (1 Leader, 2 Follower).
3. **`min.insync.replicas=2` + Producer `acks=all` (`enable.idempotence=true`):** Producer bir mesajı gönderdiğinde en az 2 kopyanın diske yazıldığından emin olur.
4. **Sonuç:** Prod'da `kafka-0` broker'ını `SIGKILL` ile öldürdüğünüzde, KRaft controller **milisaniyeler içinde** partition liderliğini `kafka-1`'e devreder. Kalan 2 broker `min.insync.replicas=2` şartını sağlamaya devam ettiği için **kesinti süresi 0 saniyedir**; tek bir mesaj bile reddedilmez! (Detaylar için: [`docs/01-prod-vs-lab.md`](../../docs/01-prod-vs-lab.md)).
