# 01 — Sistem Kullanım ve Kriz Anı Teşhis El Kitabı (Cheat Sheet)

Bu rehber; **Kubernetes, Helm, Apache Kafka, RabbitMQ, PostgreSQL ve Redis** kullanılan bir üretim veya laboratuvar ortamında **"İçeride şu an ne oluyor, sistem neden yavaşladı veya neresi patladı?"** sorusuna saniyeler içinde yanıt bulmanız için hazırlanmış pratik başvuru kılavuzudur.

---

## 1. Kubernetes & Helm — Günlük Kullanım ve Teşhis Notları

### 1.1. Pod Durumlarını ve Neden Yeniden Başladığını (Restart) Bulma
Bir podda `RESTARTS > 0`, `CrashLoopBackOff` veya `0/1 Running` gördüğünüzde bakacağınız ilk 3 komut:

```bash
# 1) Podların durumunu, hangi sunucuda (NODE) çalıştığını ve RESTARTS sayısını gör
kubectl get pods -n app -o wide

# 2) Podun en son NEDEN öldüğünü (Last State, Exit Code ve Probe hatalarını) gör
kubectl describe pod -n app <POD_ADI> | grep -A 15 -B 5 "Last State:"

# 3) Namespace içindeki son uyarı ve hata olaylarını (Liveness/Readiness/OOM) kronolojik gör
kubectl get events -n app --sort-by='.metadata.creationTimestamp' | tail -n 20
```

#### Çıkış Kodları (Exit Codes) Ne Anlama Gelir?
| Exit Code | Reason | Anlamı ve Çözümü |
| :--- | :--- | :--- |
| **`137`** | `OOMKilled` veya `SIGKILL` | Konteyner `resources.limits.memory` sınırını aştı ve Linux Kernel tarafından öldürüldü **VEYA** `livenessProbe` başarısız olduğu için Kubelet tarafından zorla kapatıldı. |
| **`143`** | `SIGTERM` | Normal kapanış (Deployment güncellemesi, `Pod Kill` veya `kubectl delete pod`). |
| **`1`** | `Error` | Uygulama kodunda yakalanmayan bir exception, yanlış ortam değişkeni veya başlangıç hatası (`kubectl logs <pod> -p` ile önceki loga bakın). |

### 1.2. Servis Yük Dengeleme (Endpoints) Kontrolü
Bir pod `Running` olsa bile `Readiness Probe` başarısızsa (`0/1`), Kubernetes o podu **Service Endpoint** listesinden çıkarır ve ona trafik göndermez:

```bash
# order-api servisinin şu an aktif olarak trafik gönderdiği pod IP'lerini gör
kubectl get endpoints -n app order-api
```
- Eğer `ENDPOINTS` karşısı **`<none>`** ise hiçbir pod `Ready` değildir ve Ingress doğrudan **`502 Bad Gateway` / `503 Service Unavailable`** döner!

### 1.3. Anlık CPU ve RAM Tüketimi (`kubectl top`)
```bash
# Sunucuların (Node) toplam CPU ve RAM yüzdesini gör
kubectl top nodes

# Uygulama podlarının anlık CPU (millicore) ve RAM (MiB) tüketimini gör
kubectl top pods -n app
```

### 1.4. Helm ile Yükseltme, Geçmişi Görme ve Geri Alma (Rollback)
```bash
# Kurulu Helm paketlerini ve kaçıncı revizyonda olduklarını listele
helm list -n app

# values.yaml dosyasını değiştirdikten sonra canlı sistemi güncelle
helm upgrade resiliencestream ./helm-chart -n app -f ./helm-chart/values.yaml

# Yapılan son değişiklik sistemi bozduysa tek komutla bir önceki sürüme geri dön (Rollback)
helm history resiliencestream -n app
helm rollback resiliencestream 1 -n app
```

---

## 2. Apache Kafka (KRaft) — Günlük Kullanım ve Teşhis Notları

Kafka bir **olay akış günlüğüdür (append-only event log)**. Mesajlar tüketilse bile hemen silinmez; her tüketici grubu (`consumer group`) kaldığı satır numarasını (`offset`) takip eder.

### 2.1. Topic Listesini ve Partition Yapısını Görme
```bash
# 1) Mevcut tüm topic'leri listele
kubectl exec -n data kafka-controller-0 -- \
  /opt/bitnami/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# 2) 'orders.events' topic'inin partition ve replika detaylarını incele
kubectl exec -n data kafka-controller-0 -- \
  /opt/bitnami/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders.events
```

### 2.2. En Kritik Kafka Kontrolü: Consumer Group & LAG (Gecikme) Analizi
> **Altın Kural:** Bir Kafka sisteminde ilk bakılacak metrik **`LAG`** değeridir!  
> `LAG = LOG-END-OFFSET (Üretilen son mesaj) - CURRENT-OFFSET (Tüketicinin okuduğu son mesaj)`

```bash
# analytics-consumer grubunun okuma durumunu ve LAG (geride kalma) sayısını gör
kubectl exec -n data kafka-controller-0 -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group analytics-consumer
```

**Çıktıyı Nasıl Yorumlamalıyım?**
- **`LAG == 0`:** Tüketici (`analytics-consumer`), gelen tüm sipariş olaylarını anında işliyor.
- **`LAG` sürekli artıyorsa:** Ya `analytics-consumer` podu çökmüştür (`OOMKilled` / `CrashLoopBackOff`), ya da yazdığı hedef veritabanı (Cassandra/DB) yavaşlamıştır.
- **`CONSUMER-ID` sütunu boşsa (`-`):** O grubu dinleyen hiçbir aktif pod kalmamıştır!

### 2.3. Topic İçindeki Mesajları Canlı Okuma
```bash
# orders.events içindeki son 5 mesajı ekrana yazdır
kubectl exec -n data kafka-controller-0 -- \
  /opt/bitnami/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic orders.events --from-beginning --max-messages 5
```

---

## 3. RabbitMQ — Günlük Kullanım ve Teşhis Notları

RabbitMQ bir **görev kuyruğudur (task broker)**. Kafka'nın aksine mesaj işlenip onaylandığında (`basic_ack`) kuyruktan **silinir**. İşlenemeyen hatalı mesajlar ise **Dead-Letter Queue (`payments.dlq`)** kuyruğuna atılır.

### 3.1. En Kritik RabbitMQ Kontrolü: Kuyruk Derinliği ve Consumer Sayısı
```bash
# Kuyruk adı, bekleyen mesaj (messages_ready), işlenmekte olan (unacknowledged) ve dinleyen işçi (consumers) sayısı
kubectl exec -n messaging rabbitmq-0 -- \
  rabbitmqctl -q list_queues name messages_ready messages_unacknowledged consumers
```

**Çıktıyı Nasıl Yorumlamalıyım?**
| Sütun | Sağlıklı Değer | Sorun Varsa Ne Anlama Gelir? |
| :--- | :--- | :--- |
| **`messages_ready`** | `0` (veya çok düşük) | Sürekli artıyorsa `payment-worker` yetişemiyor veya tamamen durmuştur! |
| **`messages_unacknowledged`** | `0` - `5` arası | Yüksek kalıyorsa `payment-worker` mesajı aldı ama `ack` göndermeden takıldı (DB yavaşlığı veya kilitlenme). |
| **`consumers`** | `>= 1` (Prod'da `>= 2`) | **`0` ise KRİTİK ARIZA:** Kuyruğu dinleyen hiçbir `payment-worker` podu hayatta değildir! |
| **`payments.dlq`** | `0` | `> 0` ise 3 kez denenmesine rağmen başarısız olmuş zehirli/hatalı ödemeler var demektir. |

### 3.2. Bağlantıları (Connections) ve Kanalları Görme
```bash
# RabbitMQ'ya bağlı olan istemci IP'lerini ve durumlarını listele
kubectl exec -n messaging rabbitmq-0 -- rabbitmqctl -q list_connections peer_host state
```

---

## 4. PostgreSQL — Günlük Kullanım ve Teşhis Notları

PostgreSQL sistemimizin **ACID garantili ana kayıt veritabanıdır (Hard Dependency)**.

### 4.1. Tablo Kayıt Sayılarını ve Son Siparişleri Görme
```bash
# orders ve payments tablolarındaki toplam kayıt sayısı
kubectl exec -n data postgres-postgresql-0 -- \
  env PGPASSWORD='AdminPassword2026!' psql -U resilience -d resilience \
  -c "SELECT (SELECT count(*) FROM orders) AS toplam_siparis, (SELECT count(*) FROM payments) AS toplam_odeme;"

# Son 5 siparişi listele
kubectl exec -n data postgres-postgresql-0 -- \
  env PGPASSWORD='AdminPassword2026!' psql -U resilience -d resilience \
  -c "SELECT order_id, customer_id, amount, pod_name, created_at FROM orders ORDER BY created_at DESC LIMIT 5;"
```

### 4.2. Aktif Bağlantıları ve Yavaş/Takılı Sorguları Görme (`pg_stat_activity`)
Veritabanı yavaşladığında veya bağlantı havuzu (connection pool) dolduğunda bakılacak ilk tablo `pg_stat_activity` tablosudur:

```bash
kubectl exec -n data postgres-postgresql-0 -- \
  env PGPASSWORD='AdminPassword2026!' psql -U resilience -d resilience \
  -c "SELECT pid, usename, client_addr, state, wait_event_type, query FROM pg_stat_activity WHERE datname = 'resilience';"
```

---

## 5. Redis — Günlük Kullanım ve Teşhis Notları

Redis sistemimizde **önbellek (Cache - Soft Dependency)** olarak çalışır.

### 5.1. Sağlık, Anahtar Sayısı ve Önbellek İçeriği Kontrolü
```bash
# 1) Redis ayakta mı? (PONG dönmeli)
kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning PING

# 2) Toplam kaç adet sipariş önbellekte tutuluyor?
kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning DBSIZE

# 3) Önbellekteki son 5 sipariş anahtarını listele
kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning KEYS "order:*" | head -n 5

# 4) Bellek kullanımı ve Hit/Miss istatistiklerini gör
kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning INFO memory | grep -E "used_memory_human|maxmemory_human"
```
