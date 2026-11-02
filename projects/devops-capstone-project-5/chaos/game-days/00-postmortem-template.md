# Olay Sonrası Değerlendirme (Blameless Postmortem) Şablonu

> [!IMPORTANT]
> **Suçlamasız Kültür (Blameless Culture):** Bu dokümanın amacı "Kimin hatasıydı?" sorusunu sormak **değildir**. İnsanlar hata yapar; mühendislik sistemlerinin görevi, tek bir insanın veya tek bir bileşenin hatasının üretim ortamını (production) çökertmesini engelleyecek korkuluklar (guardrails) inşa etmektir. Burada "Sistem bu hataya neden izin verdi ve bir daha tekrarlanmaması için mimariyi nasıl güçlendiririz?" sorusuna yanıt arıyoruz.

---

## 1. Olay Özeti (Incident Summary)

| Alan | Değer |
| :--- | :--- |
| **Olay Başlığı / Game Day Deneyi** | `[Örn: Deney 03 — RabbitMQ Ağ Bölünmesi Sırasında Ödeme Gecikmesi]` |
| **Tarih ve Saat (UTC / +03:00)** | `2026-10-27 14:10 - 14:25 (+03:00)` |
| **Toplam Etki Süresi (Duration)** | `15 dakika` |
| **Önem Derecesi (Severity)** | `SEV-1 (Kritik) / SEV-2 (Yüksek) / SEV-3 (Orta - Game Day)` |
| **Olay Komutanı (Incident Commander)** | `@ysf` |
| **Etkilenen Bileşenler / Servisler** | `order-api`, `payment-worker`, `rabbitmq.messaging.svc.cluster.local` |
| **SLO / Error Budget Etkisi** | `Aylık %99.0 hata bütçesinin %4.2'si tüketildi (p99 > 1.2s)` |

---

## 2. Müşteri ve İş Etkisi (Customer & Business Impact)

- **Kullanıcılar ne yaşadı?** (Örn: Sipariş oluşturma (`POST /api/orders`) isteklerinin %0.4'ü HTTP 503 döndü; kalan %99.6'sı başarıyla kaydedildi ancak ödeme onay bildirimleri 2 dakika gecikmeli gitti.)
- **Veri kaybı yaşandı mı?** (Örn: Hayır. PostgreSQL `orders` tablosuna tüm kayıtlar yazıldı, RabbitMQ mesajları devre kesici ve retry mekanizmasıyla kurtarıldı / DLQ'ya (`payments.dlq`) yönlendirildi.)
- **Finansal / İtibar Etkisi:** `[Varsa tahmini sipariş kaybı veya SLA ihlali]`

---

## 3. Tespit ve Uyarı Mekanizması (Detection & Alerting)

- **Olay nasıl fark edildi?** (Prometheus Alertmanager / Müşteri bildirimi / Manuel Game Day gözlemi)
- **Tetiklenen Alarmlar:**
  - `RSDependencyDown` (`rs_dependency_up{dependency="rabbitmq"} == 0`) — Arızadan **10 saniye** sonra `Firing` durumuna geçti.
  - `RSCircuitBreakerOpen` (`rs_circuit_breaker_state{dependency="rabbitmq"} == 2`) — Arızadan **15 saniye** sonra tetiklendi.
- **TTD (Time to Detect - Tespit Süresi):** `12 saniye`
- **TTR (Time to Mitigate/Resolve - Müdahale ve Çözüm Süresi):** `3 dakika`
- **Alarm Kalitesi Değerlendirmesi:** Alarm gürültülü müydü (false positive)? Runbook bağlantısı (`docs/02-troubleshooting-playbook.md#dependency-down`) sorunu çözmek için yeterli miydi?

---

## 4. Dakika Dakika Zaman Çizelgesi (Timeline)

| Saat (+03:00) | Olay / Aksiyon / Gözlem |
| :--- | :--- |
| **14:00:00** | Steady state doğrulandı (`5xx == 0`, `p99 == 45ms`, tüm `rs_dependency_up == 1`). |
| **14:02:00** | `kubectl apply -f chaos/experiments/03-network-partition-rabbitmq.yaml` ile kaos deneyi başlatıldı. |
| **14:02:08** | `order-api` pod'larından birinde RabbitMQ bağlantısı koptu; 3 başarısız deneme sonrası Circuit Breaker `OPEN` (2) durumuna geçti. |
| **14:02:15** | Prometheus `RSDependencyDown` ve `RSCircuitBreakerOpen` alarmlarını ateşledi. |
| **14:04:00** | Chaos Mesh deney süresi (`duration: 2m`) doldu, `iptables` kuralları otomatik temizlendi. |
| **14:04:15** | Circuit Breaker `HALF-OPEN` (1) durumuna geçip tek bir test mesajı gönderdi; başarılı olunca `CLOSED` (0) durumuna döndü. |
| **14:05:00** | Sistem tamamen Steady State metriklerine geri döndü. |

---

## 5. Kök Neden Analizi — 5 Neden Tekniği (Root Cause Analysis - 5 Whys)

Yüzeysel belirtide kalmayıp mimari kök nedene inmek için 5 kez "Neden?" sorusunu soruyoruz:

1. **Neden bazı ödeme görevleri `payments.dlq` kuyruğuna düştü?**
   - Çünkü `payment-worker` mesajı işlerken PostgreSQL bağlantısında geçici bir zaman aşımı (timeout) aldı.
2. **Neden tek bir zaman aşımı mesajın doğrudan DLQ'ya gitmesine yol açmadı da 3 kez denendi?**
   - Çünkü worker içinde `max_retries = 3` ve üssel geri çekilme (exponential backoff) tanımlıydı; ancak 3 deneme toplamda 7 saniye sürdü.
3. **Neden PostgreSQL bağlantısı 7 saniye boyunca yanıt veremedi?**
   - Çünkü aynı anda çalışan disk gecikmesi (`IOChaos`) nedeniyle WAL `fsync` işlemleri 100ms üzerine çıktı ve bağlantı havuzu (connection pool) doldu.
4. **Neden bağlantı havuzu dolduğunda yeni bağlantılar hemen reddedilmedi?**
   - Çünkü SQLAlchemy/psycopg2 `connect_timeout` değeri varsayılan (30s) bırakılmıştı; hızlı başarısızlık (fail-fast) yapılmadı.
5. **Neden bu durum daha önce fark edilmedi?**
   - Çünkü birim ve entegrasyon testlerinde veritabanı her zaman <1ms yanıt veriyordu; ağ/disk gecikmesi altında kaos testi (Game Day) daha önce koşulmamıştı.

---

## 6. Ne İyi Gitti? / Ne Kötü Gitti? (What Went Well / What Went Wrong)

### İyi Gidenler (Şanslı Olduğumuz veya Doğru Tasarladığımız Noktalar)
- Readiness probe (`/readyz`) sadece kritik bağımlılık olan PostgreSQL'i kontrol ettiği için, RabbitMQ veya Redis kesintisinde Kubernetes `order-api` pod'larını **öldürmedi** (kaskad çöküş önlendi).
- Arka plan sağlık kontrol iş parçacığı (background health-probe thread) sayesinde `/metrics` uç noktası kilitlenmedi ve Prometheus 5 saniyede bir kesintisiz veri çekmeye devam etti.
- PodDisruptionBudget (`minAvailable: 1`) sayesinde pod kayıplarında sıfır kesinti korundu.

### Kötü Gidenler / Geliştirilmesi Gerekenler
- `[Örn: Circuit breaker yarı-açık (half-open) kalma süresi çok kısaydı, broker tam ayağa kalkmadan trafik gönderildi.]`
- `[Örn: Grafana üzerinde DLQ mesaj sayısı paneli en altta kaldığı için operatör ilk 1 dakikada fark etmedi.]`

---

## 7. Aksiyon Maddeleri (Action Items)

Her aksiyon maddesinin **tek bir sahibi**, **ölçülebilir bir çıktısı** ve **bitiş tarihi** olmalıdır. "Daha dikkatli olacağız" bir aksiyon maddesi değildir!

| # | Aksiyon Tanımı | Tür (Önleme / Tespit / Onarım) | Sahip | Öncelik | Bitiş Tarihi | Durum |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | Veritabanı istemcisinde `connect_timeout=2s` ve `statement_timeout=3000ms` sınırlarını zorunlu kıl. | Önleme (Prevent) | `@ysf` | P0 | `2026-11-03` | `[ ] Açık` |
| **2** | `RSDlqMessagesGrowing` alarmına doğrudan DLQ mesajlarını yeniden kuyruğa alma (`requeue`) komutunu içeren runbook linki ekle. | Onarım (Mitigate) | `@ysf` | P1 | `2026-11-05` | `[ ] Açık` |
| **3** | Bu kaos deneyini CI/CD pipeline'ına haftalık otomatik Game Day işi olarak ekle. | Tespit (Detect) | `@ysf` | P2 | `2026-11-10` | `[ ] Açık` |
