# 🔥 Kubernetes Chaos Engineering & Distributed Systems Troubleshooting Lab 2 (İleri Seviye / Zero-Spoiler)

Bu laboratuvar, **ResilienceStream** çok katmanlı dağıtık sipariş ve ödeme mimarisi üzerinde **Chaos Mesh**, **Prometheus** ve **Grafana** kullanarak gerçek dünya üretim (Production) arızalarını simüle etmek, gözlemlemek ve **YAML dosyalarında hiçbir kopya/yorum olmadan** kök neden analizi (Root Cause Analysis - RCA) yapmak için tasarlanmıştır.

> [!IMPORTANT]
> **Bu Lab'ın Farkı Nedir? (Zero-Spoiler & Gelişmiş Telemetri)**
> 1. **Sıfır Kopya (`helm-chart/`):** `helm-chart/values.yaml` ve `helm-chart/templates/*.yaml` dosyalarının içinde **hiçbir `# HATA` veya çözüm yorumu bulunmaz**. Tıpkı gerçek bir üretim ortamında olduğu gibi, semptomları Grafana panellerinden ve `kubectl` çıktılarından yakalayıp YAML dosyalarındaki hatalı parametreleri kendiniz tespit edeceksiniz.
> 2. **Çok Katmanlı (Multi-Layered) Senaryolar:** Bazı deneylerde tek bir ayarı değiştirmek yetmez! Örneğin bir podun `OOMKilled` olmasını engelledikten sonra, neden hala Kafka Consumer Lag'in erimediğini veya CPU darboğazını çözdükten sonra HPA'nın neden pod sayısını artırmadığını ikinci katmanda teşhis etmeniz gerekir.
> 3. **Canlı Grafana Telemetrisi (`telemetry-agent`):** Ortamda çalışan yerleşik `telemetry-agent` bileşeni, her `2.5` saniyede bir düzenli sipariş trafiği (`POST /api/orders`) üretir ve her `4` saniyede bir doğrudan Kafka Broker (`end_offsets` vs `committed_offsets`) ile RabbitMQ (`payments` ve `payments.dlq`) kuyruklarını sorgular. Böylece **HTTP p50/p95/p99 gecikmeleri**, **Kafka Consumer Lag** ve **RabbitMQ Kuyruk/DLQ/Consumer** grafikleri tüketici podlar çökse bile **asla `No Data` (`NaN`) göstermez!**

---

## 🧭 1. Mimaride Neyi, Neden Kullanıyoruz ve Hangi Durumda Hangi Kaos Testini Yaparız?

Dağıtık bir mikroservis mimarisinde her bileşenin üstlendiği bir sorumluluk ve arıza anında göstermesi gereken bir **dayanıklılık (resilience)** davranışı vardır:

| Katman / Teknoloji | Sistemdeki Görevi & Nasıl Çalışmalı? | Hangi Durumda Hangi Kaos Testini Yaparız? | Grafana ve CLI'da Neyi İzleriz? |
| :--- | :--- | :--- | :--- |
| **`order-api`** *(FastAPI + Uvicorn, 2+ Pod)* | Gelen `POST /api/orders` isteklerini karşılar, veritabanına/kuyruklara yazar ve önbelleği günceller. **Stateless** olmalı, `PodDisruptionBudget` (`minAvailable: 1`) ile korunmalı ve CPU yükü arttığında **HPA** ile otomatik ölçeklenmelidir. | **1. Ağ Paket Kaybı (`NetworkChaos -> loss`):** Veri merkezi içi bozuk NIC/Switch veya TCP yeniden iletim (retransmission) durumunu test etmek için.<br>**2. CPU Stresi (`StressChaos -> cpu`):** Kampanya/Black Friday anlarında CFS CPU Throttling ve HPA (Auto-Scaling) davranışını doğrulamak için. | **Grafana (`SLO Overview`):** `HTTP Latency Quantiles (p50/p95/p99)`, `HTTP Request Rate by Status`, `CPU Throttling Ratio (%)`, `Active Pods`.<br>**CLI:** `kubectl get hpa -n app`, `kubectl top pods -n app` |
| **PostgreSQL** *(StatefulSet, `data` ns)* | Sipariş (`orders`) ve ödeme (`payments`) kayıtlarının tutulduğu birincil **ACID** ilişkisel veritabanı. Ağ gecikmesi yaşandığında API hemen çökmemeli; bağlantı zaman aşımı (`DEP_TIMEOUT_SECONDS`) ve **Liveness Probe** ayarları geçici yavaşlamaları tolere etmelidir. | **Ağ Gecikmesi (`NetworkChaos -> delay`):** Disk I/O doygunluğu, uzun süren `VACUUM`/kilitlenme veya bulut ağ gecikmesi sırasında API podlarının gereksiz yere `Restart` atıp atmadığını test etmek için. | **Grafana (`SLO Overview` & `Chaos Game Day`):** `Dependency Health Status (postgres)`, `Application Pod Restarts (15m)`, `HTTP 5xx Rate`.<br>**CLI:** `kubectl describe pod -n app -l app.kubernetes.io/component=order-api` |
| **Redis** *(StatefulSet, `messaging` ns)* | En son siparişleri ve durum bilgisini tutan **In-Memory Cache** katmanı. Kritik olmayan (non-blocking) bağımlılıktır; tamamen koptuğunda sistem **Circuit Breaker / Graceful Degradation** ile sipariş almaya (`HTTP 200`) devam etmelidir. | **Ağ Bölünmesi (`NetworkChaos -> partition`):** Redis sunucusuna giden ağın tamamen kopması (Split-Brain / Firewall düşmesi) durumunda API'nin 500 hatası vermeden önbelleği pas geçip geçemediğini doğrulamak için. | **Grafana (`SLO Overview`):** `Dependency Health Status (redis -> DOWN)`, buna rağmen `HTTP 200 Rate (%100)` kalması.<br>**CLI:** `curl -s http://app.<APP_IP>.nip.io/api/status \| jq` |
| **RabbitMQ & `payment-worker`** *(AMQP Kuyruk, `messaging` & `app` ns)* | Sipariş alındıktan sonra ödeme işlemini asenkron yürüten **Task Queue** katmanı. Tekil pod arızasında kuyruk durmamalı (`replicaCount >= 2`) ve hatalı mesajlar sonsuz döngüye girmeden kontrollü retry sonrası **DLQ (`payments.dlq`)** kuyruğuna incelenmek üzere ayrılmalıdır. | **Pod Arızası (`PodChaos -> pod-failure`):** Ödeme işleyici podlardan birinin bulunduğu düğümün veya konteynerin çökmesi durumunda mesajların kuyrukta (`messages_ready`) birikip birikmediğini ve DLQ davranışını test etmek için. | **Grafana (`Messaging & Queues`):** `RabbitMQ Active Consumers`, `RabbitMQ Queue Depth (payments vs payments.dlq)`, `RabbitMQ DLQ Messages`.<br>**CLI:** `rabbitmqctl list_queues name messages_ready consumers` |
| **Apache Kafka & `analytics-consumer` & Cassandra** *(Event Streaming & Wide-Column DB)* | Sipariş olaylarını (`orders.events`) gerçek zamanlı akış olarak saklar ve `analytics-consumer` aracılığıyla **Cassandra**'ya yazar. Tüketici pod bellek baskısı altında ölmemeli ve doğru topic'i dinleyerek **Consumer Lag**'i `0`'a yakın tutmalıdır. | **1. Cassandra Gecikmesi (`NetworkChaos -> delay`):** Analitik veritabanı yavaşladığında Kafka'nın geri basınç (Backpressure) tamponu olarak API'yi koruduğunu görmek için.<br>**2. Bellek Stresi (`StressChaos -> memory`):** Büyük mesaj yığınlarında `OOMKilled (Exit Code 137)` ve Kafka Lag birikimini test etmek için. | **Grafana (`Messaging & Queues`):** `Kafka Consumer Lag`, `Kafka Topic End Offset vs Committed Offset`, `Cassandra Write Latency (p95)`.<br>**CLI:** `./scripts/check-system.sh` |

---

## 🛠️ 2. Ortamı Sıfırdan Kurma (Azure Terraform + Ansible) veya Mevcut Ortamı Başlatma

### Seçenek A: Ortamı Azure Üzerinde Sıfırdan Kurmak İsterseniz
Bu klasör kendi içinde tam bağımsız `terraform/` ve `ansible/` altyapısına sahiptir:
```bash
# 1. Azure üzerinde 1 Master + 4 Worker VM ve Ağı oluşturun (~3 dk)
cd terraform
terraform init
terraform apply -auto-approve

# 2. RKE2, Rancher, Chaos Mesh, Prometheus/Grafana, Kafka, RabbitMQ, Postgres, Cassandra, Redis ve Uygulamayı kurun (~15 dk)
cd ../ansible
ansible-playbook site.yml
cd ..
```

### Seçenek B: Hazır Küme Üzerinde Lab 2'yi Başlatmak / Sıfırlamak
Ortamınız zaten ayaktaysa, Lab 2'nin **Troubleshoot modunu** (4 çok katmanlı arıza senaryosuyla) yüklemek ve tüm önceki kaos deneylerini temizlemek için:

```bash
./scripts/setup-lab.sh
```

Sistemin başlangıç röntgenini çekmek için teşhis aracını çalıştırın:
```bash
./scripts/check-system.sh
```

---

## 📊 3. Grafana Panelleri Rehberi (Yenilenmiş & Eksiksiz Metrikler)

Tarayıcınızdan **`http://grafana.<MASTER_IP>.nip.io`** (`admin` / `AdminPassword2026!`) adresine gidin ve **Dashboards** menüsünden aşağıdaki 3 paneli yan yana sekmelerde açın:

1. **`ResilienceStream - SLO & Golden Signals Overview` (`rs-slo-overview`):**
   - **HTTP Latency Quantiles (`p50`, `p95`, `p99`):** `telemetry-agent` sürekli sipariş trafiği gönderdiği için artık p50, p95 ve p99 çizgileri kesintisiz çizilir.
   - **HTTP Request Rate by Status (RPS):** `200` (yeşil) ve `500/503` (kırmızı) yanıt oranlarını saniye bazında gösterir.
   - **Dependency Health Status:** `postgres`, `redis`, `kafka`, `rabbitmq`, `cassandra` bağımlılıklarının anlık `UP (1)` / `DOWN (0)` durumu.
2. **`ResilienceStream - Messaging, Kafka Lag & RabbitMQ DLQ` (`rs-messaging`):**
   - **Kafka Consumer Lag (`orders.events`):** Broker üzerindeki son offset ile `analytics-consumer` grubunun işlediği offset arasındaki farkı (`telemetry-agent` üzerinden doğrudan broker'dan) gösterir. Tüketici pod ölse bile gerçek lag grafiği çizilmeye devam eder!
   - **Kafka Topic End Offset vs Consumer Committed Offset:** Üretilen toplam olay sayısı ile tüketilen olay sayısının makasının açılıp açılmadığını gösterir.
   - **RabbitMQ Queue Depth & Active Consumers:** `payments` ve `payments.dlq` kuyruklarında bekleyen mesaj sayılarını ve aktif `payment-worker` consumer sayısını canlı gösterir.
3. **`ResilienceStream - Chaos Game Day & Self-Healing` (`rs-chaos-gameday`):**
   - **Application Pod Restarts (15m):** Liveness probe veya `OOMKilled` kaynaklı konteyner yeniden başlamalarını gösterir.
   - **CPU Usage vs Throttling Ratio (%) & Memory Working Set:** Deney 6 (`OOMKilled`) ve Deney 7 (`CPU Throttling & HPA`) sırasında doğrudan kök nedeni yakalamanızı sağlar.

---

## 🟢 BÖLÜM A: KONTROL DENEYLERİ (Beklenen Sonuç: Sistem Dayanıklı Kalmalı)

İlk 3 deneyde sistemin **doğru tasarlanmış** dayanıklılık mekanizmalarını test edeceğiz. Bu deneylerde uygulama çökmemeli ve veri kaybı yaşanmamalıdır.

---

### 🧪 Deney 1: `order-api` Ağ Paket Kaybı (`%20 Packet Loss` — TCP Dayanıklılığı)

- **Ne Zaman / Neden Yapılır?** Bulut ortamlarında sanal anahtar (vSwitch) doygunluğu veya fiziksel NIC hataları nedeniyle paketlerin bir kısmı düşebilir. Mikroservisimizin `%20` paket kaybı altında HTTP 500 vermeden sadece hafif gecikme artışıyla (`p95/p99`) çalışmaya devam ettiğini doğrulamak için yapılır.
- **Chaos Mesh Web UI Adımları:**
  1. Sol menüden **Experiments** -> **+ New Experiment** butonuna tıklayın.
  2. **Fault Type:** `Network Attack` -> **`Loss`** seçin.
  3. **Loss:** `20`, **Correlation:** `25`, **Direction:** `to` girin.
  4. **Scope:** Namespace `app`, Label Selectors `app.kubernetes.io/component: order-api`, Mode `All` seçin.
  5. **Experiment Info:** Name `kontrol-01-order-api-packet-loss`, Duration `2m` girip **Submit** edin.
  *(Alternatif CLI: `kubectl apply -f chaos-workflows/01-kontrol-api-packet-loss.yaml`)*
- **Nasıl Kontrol Edilir?**
  - **Grafana (`SLO Overview`):** `HTTP Latency Quantiles (p50 / p95 / p99)` panelinde `p99` gecikmesinin TCP retransmission nedeniyle hafifçe yükseldiğini, ancak `HTTP Error Ratio` panelinin **`%0`** kaldığını doğrulayın.
  - Deneyi **Archive** ederek sonlandırın.

---

### 🧪 Deney 2: Redis Tam Ağ Bölünmesi (`Network Partition` — Circuit Breaker Testi)

- **Ne Zaman / Neden Yapılır?** Önbellek (Cache) katmanı hız içindir; önbellek çöktüğünde ana sipariş akışı durmamalıdır. `order-api` ile `redis` arasındaki ağ trafiğini iki yönlü (`both`) tamamen kestiğimizde sistemin **Graceful Degradation** moduna geçip sipariş almaya devam ettiğini doğrulamak için yapılır.
- **Chaos Mesh Web UI Adımları:**
  1. **Experiments** -> **+ New Experiment** -> `Network Attack` -> **`Partition`** seçin.
  2. **Direction:** `both` seçin.
  3. **Target (Hedef):** Namespace `messaging`, Label Selectors `app.kubernetes.io/name: redis`, Mode `All` seçin.
  4. **Scope (Kaynak):** Namespace `app`, Label Selectors `app.kubernetes.io/component: order-api`, Mode `All` seçin.
  5. **Name:** `kontrol-02-redis-network-partition`, **Duration:** `2m` girip **Submit** edin.
  *(Alternatif CLI: `kubectl apply -f chaos-workflows/02-kontrol-redis-partition.yaml`)*
- **Nasıl Kontrol Edilir?**
  - **Grafana (`SLO Overview`):** `Dependency Health Status` panelinde **`redis`** kutusunun **`DOWN (Kırmızı)`** olduğunu, ancak **`Overall API Availability`** kutusunun **`HEALTHY (Yeşil)`** ve `HTTP 200` trafiğinin kesintisiz devam ettiğini gözlemleyin.
  - **CLI:** `./scripts/check-system.sh` çıktısında `overall_health: "degraded"` ve `redis.healthy: false` görünürken yeni siparişlerin PostgreSQL'e yazılmaya devam ettiğini doğrulayın.
  - Deneyi **Archive** ederek sonlandırın.

---

### 🧪 Deney 3: Cassandra `500ms` Yazma Gecikmesi (Asenkron Kafka Tamponlama Testi)

- **Ne Zaman / Neden Yapılır?** Analitik veritabanı (`Cassandra`) yoğun compaction veya disk I/O nedeniyle yavaşladığında, senkron bir mimaride müşterinin sipariş isteği de yavaşlar. Ancak **Event-Driven (Kafka)** mimaride `order-api` olayı Kafka'ya bırakıp hemen döner; Cassandra'daki yavaşlama sadece `analytics-consumer` tarafında hissedilir. Bunu kanıtlamak için yapılır.
- **Chaos Mesh Web UI Adımları:**
  1. **Experiments** -> **+ New Experiment** -> `Network Attack` -> **`Delay`** seçin.
  2. **Latency:** `500ms`, **Jitter:** `50ms`, **Correlation:** `50`, **Direction:** `to` girin.
  3. **Scope:** Namespace `data`, Label Selectors `app.kubernetes.io/name: cassandra`, Mode `All` seçin.
  4. **Name:** `kontrol-03-cassandra-delay-500ms`, **Duration:** `2m` girip **Submit** edin.
  *(Alternatif CLI: `kubectl apply -f chaos-workflows/03-kontrol-cassandra-delay.yaml`)*
- **Nasıl Kontrol Edilir?**
  - **Grafana (`Messaging & Queues`):** `Cassandra Write Latency (p95 / p50)` panelinin `500ms+` seviyesine çıktığını, buna karşın **`SLO Overview`** panelindeki `order-api` HTTP p99 yanıt süresinin bundan **hiç etkilenmediğini** doğrulayın.
  - Deneyi **Archive** ederek sonlandırın.

---

## 🔴 BÖLÜM B: TROUBLESHOOTING DENEYLERİ (Hataları Bul, Teşhis Et ve Çöz!)

Aşağıdaki 4 deneyde ortamda gizli yapılandırma hataları bulunmaktadır. Hiçbir YAML dosyasında yorum satırı yoktur. Her deneyde:
1. Kaos deneyini başlatın,
2. Grafana ve CLI üzerinden arızayı gözlemleyin,
3. `helm-chart/` altındaki ilgili dosyaları inceleyip kök nedeni teşhis edin ve düzeltin!

---

### 🚨 Deney 4 (Troubleshoot #1): PostgreSQL `800ms` Gecikmesi Altında Çöken API ve Pod Restart Fırtınası

#### 1. Ne Zaman / Neden Bu Testi Yaparız?
İlişkisel veritabanlarında (PostgreSQL) yoğun sorgu veya ağ gecikmesi (`800ms`) yaşandığında, uygulama katmanındaki zaman aşımı (Timeout) ve Kubernetes **Liveness / Readiness Probe** ayarlarının bu gecikmeyi tolere edip edemediğini doğrulamak için yapılır. İyi yapılandırılmış bir sistemde `800ms` gecikme sadece HTTP yanıt süresini uzatmalı, podları öldürmemeli veya `503` üretmemelidir.

#### 2. Deneyi Başlatma (Chaos Mesh Web UI)
1. **Experiments** -> **+ New Experiment** -> `Network Attack` -> **`Delay`** seçin.
2. **Latency:** `800ms`, **Jitter:** `50ms`, **Correlation:** `50`, **Direction:** `to` girin.
3. **Scope:** Namespace `data`, Label Selectors `app.kubernetes.io/name: postgresql`, Mode `All` seçin.
4. **Name:** `troubleshoot-04-postgres-delay-800ms`, **Duration:** `3m` girip **Submit** edin.
*(Alternatif CLI: `kubectl apply -f chaos-workflows/04-troubleshoot-postgres-delay.yaml`)*

#### 3. Gözlem ve Teşhis Rehberi (Nereye Bakmalısınız?)
- **Grafana (`SLO Overview` & `Chaos Game Day`):**
  - `Dependency Health Status` panelinde **`postgres`** neden anında `DOWN (0)` oldu?
  - `HTTP Request Rate by Status` panelinde neden `503` hataları başladı?
  - `Application Pod Restarts (15m)` panelinde `order-api` podları neden sürekli **Restart** atıyor?
- **Terminal / CLI Teşhis Komutları:**
  ```bash
  ./scripts/check-system.sh
  kubectl describe pod -n app -l app.kubernetes.io/component=order-api | tail -n 25
  ```
- **Araştırma Soruları (`helm-chart/values.yaml` dosyasını inceleyin):**
  1. Veritabanında `800ms` gecikme varken uygulamanın bağımlılık zaman aşımı (`DEP_TIMEOUT_SECONDS`) kaç saniyeye ayarlanmış?
  2. Kubelet'in podu öldürüp yeniden başlatmasına karar veren `livenessProbe` hangi HTTP adresini (`path`) çağırıyor ve `timeoutSeconds` değeri kaç? Liveness probe dış bağımlılıkları kontrol eden `/readyz` adresine mi yoksa sadece sürecin yaşadığını kontrol eden `/healthz` adresine mi bakmalıdır?

---

### 🚨 Deney 5 (Troubleshoot #2): `payment-worker` Pod Arızası, Sıfırlanan Consumer ve Patlayan DLQ (`payments.dlq`)

#### 1. Ne Zaman / Neden Bu Testi Yaparız?
Ödeme kuyruğunu (`payments`) tüketen `payment-worker` servisinde iki kritik risk vardır:
1. Tek bir pod çökmesiyle tüm ödeme tüketiminin durması (**Single Point of Failure**),
2. Ödeme ağ geçidi (Payment Gateway) hata oranının veya yeniden deneme (`retry`) ayarlarının yanlış yapılandırılması sonucu mesajların işlenemeyip **Dead-Letter Queue (`payments.dlq`)** kuyruğunu şişirmesi.

#### 2. Deneyi Başlatma (Chaos Mesh Web UI)
1. **Experiments** -> **+ New Experiment** -> `Pod Fault` -> **`Pod Failure`** seçin.
2. **Scope:** Namespace `app`, Label Selectors `app.kubernetes.io/component: payment-worker`, Mode `One` (`1` pod) seçin.
3. **Name:** `troubleshoot-05-payment-worker-failure`, **Duration:** `3m` girip **Submit** edin.
*(Alternatif CLI: `kubectl apply -f chaos-workflows/05-troubleshoot-payment-dlq.yaml`)*

#### 3. Gözlem ve Teşhis Rehberi (Nereye Bakmalısınız?)
- **Grafana (`Messaging, Kafka Lag & RabbitMQ DLQ`):**
  - `RabbitMQ Active Consumers (payment-worker)` paneline bakın: Deney başladığında aktif consumer sayısı neden **`0`**'a düştü ve `payments` kuyruğunda (`RabbitMQ Queue Depth`) mesajlar birikmeye başladı?
  - Deney bittiğinde (veya pod çalışırken) **`RabbitMQ DLQ Messages (payments.dlq)`** ve **`Payment Worker Failure / Retry / DLQ Rates`** panellerine bakın: Neden ödemelerin büyük çoğunluğu başarısız olup `payments.dlq` kuyruğuna düşüyor?
- **Terminal / CLI Teşhis Komutları:**
  ```bash
  ./scripts/check-system.sh
  kubectl logs -n app -l app.kubernetes.io/component=payment-worker --tail=30
  ```
- **Araştırma Soruları (`helm-chart/values.yaml` dosyasını inceleyin):**
  1. `Pod Failure (mode: one)` sırasında kuyruk tüketiminin hiç durmaması için `workers.paymentWorker.replicaCount` (ve `hpa.paymentWorkerEnabled`) ne olmalıdır?
  2. `env` altındaki `PAYMENT_FAILURE_RATE` ve `RABBITMQ_MAX_RETRIES` parametreleri neden mesajların hızla `payments.dlq` kuyruğuna taşmasına yol açıyor?

---

### 🚨 Deney 6 (Troubleshoot #3): `analytics-consumer` Bellek Stresi (`OOMKilled`) ve Gizli Kafka Topic Uyuşmazlığı!

#### 1. Ne Zaman / Neden Bu Testi Yaparız?
Gerçek zamanlı veri akışı (Kafka Streaming) hatlarında iki farklı arıza türü sıkça iç içe geçer:
1. Tüketici podun ani bir mesaj yığını altında bellek limitine takılıp Linux çekirdeği tarafından **`OOMKilled` (`Exit Code 137`)** ile öldürülmesi,
2. Pod ayakta (`Running`) görünse bile **Kafka Consumer Lag**'in sürekli artmaya devam etmesi!

#### 2. Deneyi Başlatma (Chaos Mesh Web UI)
1. **Experiments** -> **+ New Experiment** -> `Stress Test` -> **`Memory`** seçin.
2. **Memory Workers:** `1`, **Size:** `50MB` girin.
3. **Scope:** Namespace `app`, Label Selectors `app.kubernetes.io/component: analytics-consumer`, Mode `One` seçin.
4. **Name:** `troubleshoot-06-analytics-memory-50mb`, **Duration:** `2m` girip **Submit** edin.
*(Alternatif CLI: `kubectl apply -f chaos-workflows/06-troubleshoot-analytics-lag.yaml`)*

#### 3. Gözlem ve Teşhis Rehberi (Çok Katmanlı Arıza!)
- **Katman 1 — `OOMKilled` Teşhisi:**
  - **Grafana (`Chaos Game Day`):** `Memory Working Set (App Pods)` ve `Application Pod Restarts` panellerine bakın.
  - **CLI:**
    ```bash
    kubectl get pods -n app -l app.kubernetes.io/component=analytics-consumer
    kubectl describe pod -n app -l app.kubernetes.io/component=analytics-consumer | grep -A 10 "Last State:"
    ```
  - `analyticsResources.limits.memory` değeri `50MB` ek bellek stresini kaldırabilecek seviyede mi?
- **Katman 2 — Neden Kafka Consumer Lag Hala Erimiyor?!**
  - Bellek limitini artırıp `helm upgrade` yaptıktan sonra bile **Grafana (`Messaging & Queues`)** içindeki **`Kafka Consumer Lag (orders.events)`** ve **`Kafka Topic End Offset vs Committed Offset`** panellerine bakın!
  - `analytics-consumer` podu `1/1 Running` ve `0 Restart` olmasına rağmen **`Committed Offset` neden `0`'da çakılı kalıyor ve `Lag` sürekli artıyor?**
  - **CLI ile İpucu Yakalama:**
    ```bash
    kubectl get deploy analytics-consumer -n app -o yaml | grep -A 5 -B 2 "KAFKA_TOPIC"
    ```
  - `order-api` olayları hangi Kafka topic'ine yazıyor, `analytics-consumer` ise (`values.yaml` ve `templates/deployment.yaml` nedeniyle) hangi topic'i dinliyor?

---

### 🚨 Deney 7 (Troubleshoot #4): `order-api` CPU Darboğazı (`CFS Throttling`), Fırlayan HTTP p99 ve Çalışmayan HPA!

#### 1. Ne Zaman / Neden Bu Testi Yaparız?
Yoğun trafik veya CPU yükü altında mikroservislerin yanıt süresinin (`HTTP p99`) bozulmaması için iki şey şarttır:
1. Konteynerin CPU limitinin (`resources.limits.cpu`), Linux CFS (Completely Fair Scheduler) tarafından her `100ms` periyotta boğulmayacak (**CPU Throttling**) kadar makul verilmesi,
2. **HorizontalPodAutoscaler (HPA)** bileşeninin CPU artışını algılayıp pod sayısını `2`'den `4`'e otomatik çıkarması.

#### 2. Deneyi Başlatma (Chaos Mesh Web UI)
1. **Experiments** -> **+ New Experiment** -> `Stress Test` -> **`CPU`** seçin.
2. **CPU Workers:** `1`, **Load:** `80` (`%80` CPU yükü) girin.
3. **Scope:** Namespace `app`, Label Selectors `app.kubernetes.io/component: order-api`, Mode `All` seçin.
4. **Name:** `troubleshoot-07-order-api-cpu-stress`, **Duration:** `3m` girip **Submit** edin.
*(Alternatif CLI: `kubectl apply -f chaos-workflows/07-troubleshoot-api-cpu-hpa.yaml`)*

#### 3. Gözlem ve Teşhis Rehberi (Çok Katmanlı Arıza!)
- **Grafana (`SLO Overview` & `Chaos Game Day`):**
  - `CPU Usage vs Throttling Ratio (%)` paneline bakın: `order-api` podlarında **CPU Throttling** oranı neden `%80-%100` bandına fırladı?
  - `HTTP Latency Quantiles (p50 / p95 / p99)` paneline bakın: CPU boğulması yüzünden `p99` gecikmesi nasıl sıçradı?
  - `Active Pods by Component` paneline bakın: CPU yükü tavan yapmasına rağmen `order-api` pod sayısı neden **`2`**'de sabit kaldı ve **`4`**'e çıkmadı?
- **Terminal / CLI Teşhis Komutları:**
  ```bash
  kubectl get hpa -n app
  kubectl describe hpa order-api-hpa -n app
  ```
- **Araştırma Soruları (`helm-chart/values.yaml` ve `templates/hpa.yaml` dosyalarını inceleyin):**
  1. `order-api` için tanımlanan `resources.limits.cpu` değeri kaç milicore (`m`)? Neden en ufak yükte ağır CPU Throttling yaşanıyor?
  2. `kubectl describe hpa order-api-hpa -n app` çıktısında HPA hangi Deployment ismini (`scaleTargetRef.name`) ölçeklemeye çalışıyor? Kümedeki gerçek Deployment ismi ne?

---

## 🏆 4. Çözümleri Uygulama ve Final Chaos Workflow Doğrulaması

Tüm hataları `helm-chart/values.yaml` içinde bulup düzelttikten sonra değişikliklerinizi kümeye uygulayın:

```bash
# Kendi düzelttiğiniz values.yaml dosyasını uygulamak için:
./scripts/setup-lab.sh

# VEYA anahtar teslim çözülmüş referans yapılandırmayı (--fixed) uygulamak için:
./scripts/setup-lab.sh --fixed
```

Ardından 4 arıza senaryosunu (Postgres 800ms Delay -> Payment Worker Failure -> Analytics 50MB Memory Stress -> Order API CPU Stress) arka arkaya otomatik koşturan **Final Doğrulama Pipeline**'ını başlatın:

```bash
kubectl apply -f chaos-workflows/08-final-dogrulama-workflow.yaml
```

Grafana panellerinden tüm deneyler boyunca:
- `order-api` podlarının **0 Restart** ile ayakta kaldığını,
- `payments.dlq` kuyruğunun **0** kaldığını ve aktif consumer sayısının sıfırlanmadığını,
- `analytics-consumer` podunun `OOMKilled` olmadığını ve **Kafka Consumer Lag**'in anında `0`'a indiğini,
- `order-api-hpa`'nın metrikleri okuyup podları başarıyla ölçeklediğini doğrulayın!

---

<details>
<summary>🔐 <b>ÇÖZÜM ANAHTARI (Sadece Kendi Teşhisinizi Tamamladıktan Sonra Açın!)</b></summary>

### 🛠️ Deney 4 Çözümü (PostgreSQL `800ms` Gecikmesi & Liveness Probe)
- **Kök Neden 1 (`env.DEP_TIMEOUT_SECONDS`):** `values.yaml` içinde `"0.4"` (`400ms`) olarak ayarlanmıştır. PostgreSQL'e `800ms` gecikme enjekte edildiğinde tüm sorgular `400ms`'de zaman aşımına uğrar ve `503` döner.
- **Kök Neden 2 (`apiProbes.livenessProbe`):** `path: "/readyz"` ve `timeoutSeconds: 1` olarak ayarlanmıştır. `/readyz` veritabanı bağlantısını kontrol ettiği için veritabanı yavaşladığında Liveness Probe başarısız olur ve Kubelet sağlıklı `order-api` podlarını öldürüp yeniden başlatır.
- **Düzeltme (`values.yaml`):**
  ```yaml
  apiProbes:
    livenessProbe:
      path: "/healthz"
      initialDelaySeconds: 10
      periodSeconds: 10
      timeoutSeconds: 3
      failureThreshold: 3
  env:
    DEP_TIMEOUT_SECONDS: "2.5"
  ```

### 🛠️ Deney 5 Çözümü (`payment-worker` HA & RabbitMQ DLQ Patlaması)
- **Kök Neden 1 (`workers.paymentWorker.replicaCount`):** `1` olarak ayarlanmıştır. Tek pod `PodChaos` ile durdurulduğunda aktif consumer sayısı `0`'a düşer.
- **Kök Neden 2 (`env.PAYMENT_FAILURE_RATE` & `RABBITMQ_MAX_RETRIES`):** `PAYMENT_FAILURE_RATE: "0.65"` (`%65` simüle edilmiş hata) ve `RABBITMQ_MAX_RETRIES: "1"` olduğu için mesajların büyük kısmı 1 deneme sonunda doğrudan `payments.dlq` kuyruğuna düşer.
- **Düzeltme (`values.yaml`):**
  ```yaml
  workers:
    paymentWorker:
      enabled: true
      replicaCount: 2
  hpa:
    paymentWorkerEnabled: true
  env:
    RABBITMQ_MAX_RETRIES: "3"
    PAYMENT_FAILURE_RATE: "0.0"
  ```

### 🛠️ Deney 6 Çözümü (`analytics-consumer` OOMKilled & Kafka Topic Uyuşmazlığı)
- **Kök Neden 1 (`analyticsResources.limits.memory`):** `80Mi` olarak verilmiştir. Python süreci + `50MB` `StressChaos` toplamda `80Mi` sınırı aştığı için konteyner `OOMKilled` (`Exit Code 137`) olur.
- **Kök Neden 2 (`workers.analyticsConsumer.kafkaTopic`):** `values.yaml` içinde `workers.analyticsConsumer.kafkaTopic: "orders.raw"` tanımlanmıştır (`templates/deployment.yaml` bu değeri `KAFKA_TOPIC` olarak enjekte eder). Oysa `order-api` mesajları `"orders.events"` topic'ine yazar! Bu yüzden pod çalışsa bile `"orders.events"` üzerindeki lag hiç erimez.
- **Düzeltme (`values.yaml`):**
  ```yaml
  workers:
    analyticsConsumer:
      enabled: true
      replicaCount: 1
      kafkaTopic: "orders.events"
  analyticsResources:
    requests:
      cpu: 25m
      memory: 96Mi
    limits:
      cpu: 250m
      memory: 256Mi
  ```

### 🛠️ Deney 7 Çözümü (`order-api` CPU Throttling & Bozuk HPA Hedefi)
- **Kök Neden 1 (`resources.limits.cpu`):** `60m` (`0.06` vCPU) olarak ayarlanmıştır. En ufak yükte konteyner ağır CFS CPU Throttling yaşar ve HTTP p99 süresi fırlar.
- **Kök Neden 2 (`hpa.targetDeploymentName`):** `values.yaml` içinde `"order-service"` yazılmıştır. Oysa Deployment'ın gerçek adı `"order-api"`'dir. Bu nedenle `order-api-hpa` hedef Deployment'ı bulamaz (`FailedGetScale`) ve pod sayısını artıramaz.
- **Düzeltme (`values.yaml`):**
  ```yaml
  resources:
    requests:
      cpu: 50m
      memory: 96Mi
    limits:
      cpu: 400m
      memory: 256Mi
  hpa:
    enabled: true
    targetDeploymentName: "order-api"
  ```

</details>
