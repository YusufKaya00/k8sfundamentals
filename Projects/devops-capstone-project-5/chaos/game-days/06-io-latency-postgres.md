# Game Day 06 — IOChaos: PostgreSQL Disk Yazma (`write/fsync`) Gecikmesi

**Manifest:** [`chaos/experiments/06-io-latency-postgres.yaml`](../experiments/06-io-latency-postgres.yaml)  
**Hedef Bileşen:** `postgresql` (`namespace: data`, volume: `/bitnami/postgresql`)  
**Kaos Türü:** `IOChaos` (`action: latency`, `delay: 100ms`, `percent: 50`, `methods: [write, fsync]`, `duration: 2m`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** Ana ilişkisel veritabanımız olan PostgreSQL'in veri diskinde (`/bitnami/postgresql`) `write` ve `fsync` sistem çağrılarının %50'sine **100ms gecikme** enjekte edildiğinde:
> 1. Her `INSERT INTO orders ... COMMIT` işlemi Write-Ahead Log (WAL) `fsync` çağrısını beklediği için `order-api` sipariş oluşturma gecikmesi (p99) belirgin şekilde artar ve **`RSHighLatencyP99` alarmı tetiklenir**.
> 2. Buna karşın `/readyz` ve `/healthz` kontrolleri zaman aşımına uğramaz, pod'lar yeniden başlatılmaz ve **hiçbir sipariş verisi bozulmaz (ACID garantisi)**.

**Neden Prod'da Önemli?**  
Bulut ortamlarında ağ bağlantılı diskler (Azure Managed Disks, AWS EBS) zaman zaman "noisy neighbor", IOPS burst kredisinin tükenmesi veya arka plan snapshot işlemleri nedeniyle sessizce yavaşlar (Gray Failure / Gri Arıza). Sunucu ayaktadır, CPU %5'tir, RAM boştur ama site çok yavaştır! Bu deney, izleme sistemimizin (Prometheus histogramlarının) "gri disk arızalarını" yakalayıp yakalayamadığını kanıtlar.

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

```promql
# 1) PostgreSQL bağımlılık durumu == 1
min(rs_dependency_up{dependency="postgres"}) == 1

# 2) PostgreSQL p95 gecikmesi < 25ms (0.025s)
histogram_quantile(0.95, sum by (le) (rate(rs_dependency_latency_seconds_bucket{dependency="postgres"}[1m]))) < 0.025

# 3) order-api p99 HTTP gecikmesi < 300ms (0.3s)
histogram_quantile(0.99, sum by (le) (rate(rs_http_request_duration_seconds_bucket{endpoint="/api/orders"}[1m]))) < 0.3
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `data` namespace'indeki `app.kubernetes.io/name: postgresql` pod'u.
- **Volume ve Metod Seçimi:** Yalnızca `/bitnami/postgresql` altındaki dosyalara yapılan `write` ve `fsync` çağrılarının `%50`'sine `100ms` FUSE gecikmesi eklenir. Okuma (`read`) işlemleri doğrudan etkilenmez; işletim sistemi kök diski (`/`) etkilenmez.
- **Süre:** `2m`.

---

## 4. Abort (Acil Durdurma) Koşulları

1. PostgreSQL bağlantı havuzu (connection pool) tamamen dolup `order-api` `/readyz` kontrolleri arka arkaya başarısız olmaya başlarsa.
2. PostgreSQL pod'u kilitlenip Liveness probe tarafından öldürülürse.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/06-io-latency-postgres.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Sürekli Sipariş Yükü Başlatın (Terminal 1)
p99 histogramının anlamlı veri üretmesi için düzenli istek gönderin:
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
while true; do
  curl -s -o /dev/null -w "HTTP:%{http_code} ToplamSüre:%{time_total}s\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"cust-io","product_id":"sku-6","quantity":1,"amount":210.0}'
  sleep 0.3
done
```

### Adım 2: Disk Gecikmesini (`IOChaos`) Enjekte Edin (Terminal 2)
```bash
kubectl apply -f chaos/experiments/06-io-latency-postgres.yaml
```

### Adım 3: Durumu ve PostgreSQL Bekleme Olaylarını (Wait Events) İnceleyin
```bash
# IOChaos durumunu kontrol et
kubectl get iochaos -n chaos-mesh io-latency-postgres

# PostgreSQL içinde aktif sorguların hangi I/O olayını (WALWrite / DataFileFlush) beklediğini gör:
kubectl exec -n data statefulset/postgres-postgresql -- \
  sh -c 'PGPASSWORD=AdminPassword2026! psql -U resilience -d resilience -c "SELECT pid, state, wait_event_type, wait_event, query FROM pg_stat_activity WHERE state != '\''idle'\'';"'
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **Terminal 1 Çıktısı:**
   - Deney öncesinde `0.02s - 0.05s` süren `POST /api/orders` çağrılarının süresi `0.25s - 0.80s` aralığına yükselir (her transaction birden fazla `write` ve `fsync` yaptığı için 100ms gecikmeler kümülatif toplanır).
2. **Grafana — SLO Overview & Chaos Game Day Dashboard:**
   - `rs_dependency_latency_seconds{dependency="postgres"}` p95/p99 grafiğinde net bir basamak (step-up) görülür.
   - `order-api` p99 latency eğrisi yükselir.
3. **Alarmlar:**
   - Eğer p99 gecikmesi tanımlanan eşiği (veya bağımlılık gecikmesi eşiği) aşarsa **`RSHighLatencyP99`** alarmı tetiklenir (`docs/02-troubleshooting-playbook.md#high-latency`).
   - Dikkat: `rs_dependency_up{dependency="postgres"}` **`1` kalmaya devam eder**! İşte bu yüzden sadece "up/down" izlemek yetmez; **gecikme (latency) izlemek zorunludur**.

---

## 7. Toparlanma (Recovery) ve Temizlik

```bash
# Deneyi sonlandır
kubectl delete -f chaos/experiments/06-io-latency-postgres.yaml

# Sipariş sayısının eksiksiz kaydedildiğini doğrula
kubectl exec -n data statefulset/postgres-postgresql -- \
  sh -c 'PGPASSWORD=AdminPassword2026! psql -U resilience -d resilience -c "SELECT count(*) AS total_orders FROM orders;"'
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **Neden `fsync` Bu Kadar Kritik?** PostgreSQL'de bir transaction `COMMIT` edildiğinde, veri sayfaları hemen tablo dosyasına yazılmasa bile **WAL (Write-Ahead Log)** dosyasına yazılıp `fsync()` ile fiziksel diske mühürlenmek zorundadır. Aksi takdirde fiş çekilirse onaylanmış sipariş kaybolur.
- **Prod Çözümü:** Üretim ortamında veritabanı diskleri için standart HDD/Standart SSD yerine **garantili IOPS ve düşük gecikmeli diskler** (Azure Premium SSD v2 / Ultra Disk, AWS io2 Block Express) kullanılır ve WAL dizini (`pg_wal`) ana veri dizininden **ayrı bir fiziksel diske** mount edilir ki yoğun tablo okumaları/checkpoint işlemleri `COMMIT` (`fsync`) gecikmesini etkilemesin.
