# Game Day 07 — DNSChaos: Redis Servis Keşfi (DNS) Hatası ve Graceful Degradation

**Manifest:** [`chaos/experiments/07-dns-chaos.yaml`](../experiments/07-dns-chaos.yaml)  
**Hedef Bileşen:** `order-api` (`mode: one`) → `redis-master.messaging.svc.cluster.local` sorguları  
**Kaos Türü:** `DNSChaos` (`action: error`, `duration: 2m`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** `order-api` pod'larından birinde `redis-master.messaging.svc.cluster.local` DNS adı çözümlenemez hale geldiğinde (`SERVFAIL / NXDOMAIN`):
> 1. Redis bir **önbellek (cache)** katmanı olduğu için `order-api` hatayı yakalar, loglar ve işlemi **durdurmak yerine doğrudan PostgreSQL üzerinden tamamlar (Graceful Degradation — Zarif Bozulma)**.
> 2. Kullanıcı tarafında HTTP 5xx hata oranı **%0 kalır**.
> 3. Arka plan sağlık kontrolü `rs_dependency_up{dependency="redis"}` metriğini `0`'a düşürür ve operatöre `RSDependencyDown` uyarısı gönderir.

**Neden Prod'da Önemli?**  
"Her zaman DNS'tir (It's always DNS)" sözü SRE dünyasının en meşhur gerçeğidir. CoreDNS pod'larının yoğunluktan yanıt verememesi veya yanlış bir NetworkPolicy nedeniyle DNS çözümlemesinin bozulması çok sık yaşanır. İkinci kritik ders ise **Kritik Bağımlılık vs Opsiyonel Bağımlılık** ayrımıdır: Önbellek (Redis) çöktü diye müşterinin sipariş vermesini engellemek büyük bir mimari hatadır!

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL

```promql
# 1) Redis bağımlılık durumu tüm podlarda == 1
min(rs_dependency_up{dependency="redis"}) == 1

# 2) Chaos Mesh DNS sunucusu (chaos-dns-server) çalışıyor olmalı
kube_pod_status_ready{namespace="chaos-mesh", pod=~"chaos-dns-server-.*", condition="true"} == 1

# 3) HTTP 5xx hata oranı == 0
sum(rate(rs_http_requests_total{status=~"5.."}[1m])) == 0
```

> [!NOTE]
> `DNSChaos` deneyinin çalışabilmesi için Chaos Mesh Helm kurulumunda `dnsServer.create: true` ayarı açık olmalıdır (Proje 5 `helm-values/chaos-mesh-values.yaml` içinde bu ayar hazır olarak açıktır).

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `app` namespace'indeki **1 adet** `order-api` pod'u.
- **DNS Deseni (`patterns`):** Yalnızca `redis-master.messaging.svc.cluster.local` sorguları hata döner. Aynı pod'un `postgres-postgresql.data.svc.cluster.local` veya `kafka.data.svc.cluster.local` sorguları normal şekilde çözümlenmeye devam eder!
- **Süre:** `2m`.

---

## 4. Abort (Acil Durdurma) Koşulları

1. `chaos-dns-server` pod'unda bir sorun oluşup hedef pod'un **tüm** DNS çözümlemeleri (PostgreSQL dahil) bozulursa.
2. HTTP 5xx oranı %1'i aşarsa.

**Acil Durdurma Komutu:**
```bash
kubectl delete -f chaos/experiments/07-dns-chaos.yaml
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Chaos DNS Sunucusunun Ayakta Olduğunu Doğrulayın
```bash
kubectl get pods -n chaos-mesh -l app.kubernetes.io/component=chaos-dns-server
```

### Adım 2: DNS Kaosunu Başlatın
```bash
kubectl apply -f chaos/experiments/07-dns-chaos.yaml
kubectl get dnschaos -n chaos-mesh dns-chaos-redis
```

### Adım 3: Sipariş Oluşturun ve Okuma Yapın
Hem yazma (cache set) hem de okuma (cache get -> fallback to DB) yollarını test edin:
```bash
APP_HOST="http://app.<APP_IP>.nip.io"
for i in $(seq 1 20); do
  curl -s -w "\n[Sipariş $i] HTTP:%{http_code} Süre:%{time_total}s\n" \
    -X POST "$APP_HOST/api/orders" \
    -H "Content-Type: application/json" \
    -d "{\"customer_id\":\"cust-dns-$i\",\"product_id\":\"sku-7\",\"quantity\":1,\"amount\":33.0}"
  sleep 1
done
```

### Adım 4: Pod İçinden DNS Hatasını ve Metriği Gözlemleyin
```bash
for pod in $(kubectl get pods -n app -l app.kubernetes.io/component=order-api -o name); do
  echo "=== $pod ==="
  kubectl exec -n app "$pod" -- curl -s localhost:8000/metrics | grep 'rs_dependency_up{dependency="redis"}'
done
```

---

## 6. Beklenen Gözlem (Grafana & Alarmlar)

1. **Uygulama Davranışı (Graceful Degradation):**
   - Etkilenen `order-api` pod'u Redis'e bağlanmak istediğinde `socket.gaierror: [Errno -2] Name or service not known` hatası alır.
   - Uygulama bu hatayı yakalar, `rs_circuit_breaker_state{dependency="redis"}` ve `rs_dependency_up{dependency="redis"}` metriklerini günceller ama **siparişi HTTP 200/201 ile başarıyla tamamlar**.
2. **Grafana & Alarmlar:**
   - **Chaos Game Day Dashboard:** `rs_dependency_up{dependency="redis"}` grafiği 1'den 0'a iner.
   - **SLO Overview Dashboard:** Başarı oranı **%100** kalır!
   - **Alertmanager:** `RSDependencyDown{dependency="redis"}` alarmı <15 saniye içinde çalarak altyapı ekibine Redis erişim sorununu bildirir; ancak müşteriler kesinti yaşamaz.

---

## 7. Toparlanma (Recovery) ve Temizlik

```bash
# Deneyi sonlandır (podun /etc/resolv.conf ayarı normale döner)
kubectl delete -f chaos/experiments/07-dns-chaos.yaml

# 10 saniye sonra Redis bağımlılık metriğinin 1 olduğunu doğrula
sleep 10
for pod in $(kubectl get pods -n app -l app.kubernetes.io/component=order-api -o name); do
  kubectl exec -n app "$pod" -- curl -s localhost:8000/metrics | grep 'rs_dependency_up{dependency="redis"}'
done
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

- **NodeLocal DNSCache:** Büyük Kubernetes kümelerinde her pod'un her dış/iç bağlantıda merkezi CoreDNS pod'larına UDP sorgusu atması CoreDNS'i darboğaza sokar ve Linux `nf_conntrack` tablosunu doldurur (DNS yarış durumu nedeniyle 5 saniyelik gizemli gecikmeler yaşanır). Prod ortamlarında her sunucuda DaemonSet olarak **NodeLocal DNSCache** çalıştırılır.
- **Connection Pooling ve DNS TTL:** Kalıcı TCP bağlantı havuzu kullanan istemciler, DNS'i sadece yeni bağlantı açarken çözümler. Arka plan sağlık kontrolümüz (`resilience.py`) bağlantıyı ve ping işlemini periyodik doğruladığı için hem ağ hem de DNS kopmalarını saniyeler içinde tespit eder.
