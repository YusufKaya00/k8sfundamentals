# SRE Postmortem (Olay Sonrası İnceleme) Şablonu

> **Kural (Blameless Culture):** Olay sonrası incelemelerin amacı kişi veya ekipleri suçlamak değil, sistemdeki mimari, operasyonel ve süreçsel zafiyetleri tespit edip gelecekte aynı hatanın tekrarlanmasını önlemektir.

---

## 1. Olay Özeti (Executive Summary)

| Alan | Bilgi |
|---|---|
| **Olay Adı** | `INC-2026-11-05-T1`: PostgreSQL Gecikmesinde `order-api` Kaskad Çöküşü |
| **Önem Derecesi (Severity)** | `SEV-1 (Critical Outage)` |
| **Başlangıç Zamanı** | 2026-11-05 10:14:00 UTC |
| **Bitiş / İyileşme Zamanı** | 2026-11-05 10:28:00 UTC |
| **Toplam Kesinti Süresi (TTR)** | 14 Dakika |
| **Etkilenen Servisler** | `order-api`, `/api/orders`, `/readyz` |
| **SLO / Error Budget Etkisi** | Hata bütçesinin %18'i tüketildi (Error Ratio: %100) |
| **Olay Yöneticisi (Incident Commander)** | SRE Platform Takımı |

---

## 2. Kullanıcı Etkisi (User Impact)
- Müşteriler 14 dakika boyunca yeni sipariş oluşturamadı.
- NGINX Ingress `502 Bad Gateway` ve `504 Gateway Timeout` döndürdü.
- Toplamda tahmini 2,400 sipariş isteği reddedildi veya zaman aşımına uğradı.

---

## 3. Olay Zaman Çizelgesi (Timeline)

| Zaman (UTC) | Aşama | Detay |
|---|---|---|
| `10:14:00` | **Tetiklenme** | PostgreSQL veritabanı diskinde 1500ms gecikme (IO/Ağ darboğazı) başladı. |
| `10:14:15` | **Algılama** | Prometheus `ResilienceStreamHighLatencyP99` alarmı çaldı. |
| `10:14:35` | **Kaskad Arıza** | `order-api` liveness probe'ları 3 kez ardışık zaman aşımına uğradı (timeout: 3s). Kubelet konteynerleri öldürmeye (SIGKILL) başladı. |
| `10:15:20` | **Eskalasyon** | Tüm `order-api` podları `CrashLoopBackOff` durumuna geçti. Endpoint havuzu 0'a indi. |
| `10:18:00` | **Müdahale** | On-call SRE pod loglarını inceledi: `Liveness probe failed: HTTP probe failed with statuscode: 503`. |
| `10:22:00` | **Teşhis** | Liveness probe'un `/healthz` yerine harici bağımlılıkları sorgulayan `/readyz` uç noktasına baktığı keşfedildi. |
| `10:25:00` | **Düzeltme** | `values.yaml` içinde `livenessProbe.path: /healthz` olarak güncellendi ve Helm ile dağıtıldı. |
| `10:28:00` | **Normale Dönüş** | Podlar ayağa kalktı. Veritabanı yavaş olmasına rağmen podlar canlı kaldı ve siparişler işlenmeye devam etti. |

---

## 4. Kök Neden Analizi (Root Cause Analysis - 5 Whys)

1. **Soru 1:** `order-api` podları neden çöktü ve yeniden başladı?
   - *Cevap:* Kubelet liveness probe'un 3 kez başarısız olduğunu tespit etti ve konteyneri yeniden başlattı.
2. **Soru 2:** Liveness probe neden başarısız oldu?
   - *Cevap:* Liveness probe `/readyz` uç noktasına yönlendirilmişti ve PostgreSQL bağlantısı 1.5s gecikmeyle yanıt veriyordu.
3. **Soru 3:** Liveness probe neden harici veritabanını kontrol ediyordu?
   - *Cevap:* Helm şablonunda `livenessProbe.path` sehven `/readyz` (Readiness) ile aynı adrese bağlanmıştı.
4. **Soru 4:** Liveness ile Readiness arasındaki fark nedir?
   - *Cevap:* **Liveness**, sürecin (process) kilitlenip kilitlenmediğini denetler; bağımlılıklara ASLA bakmamalıdır. **Readiness**, pod'un trafiği kabul edip edemeyeceğini denetler. Bağımlılık çöktüğünde pod yeniden başlatılmamalı, sadece trafikten çekilmelidir.
5. **Soru 5:** Kök neden nedir?
   - *Cevap:* Bağımlılık gecikmesi yaşayan bir sistemde liveness probe'un bağımlılığa bakması, geçici bir yavaşlığı tüm uygulamanın çöküşüne (Cascading Failure) dönüştürmüştür.

---

## 5. Alınan Aksiyonlar ve İyileştirmeler (Action Items)

| ID | Aksiyon | Sahip | Öncelik | Durum |
|---|---|---|---|---|
| **ACT-01** | `helm-chart/values.yaml` içinde livenessProbe `/healthz` adresine sabitlenecek. | DevOps/SRE | P0 (Acil) | Tamamlandı |
| **ACT-02** | CI/CD pipeline'ına `livenessProbe.path != readinessProbe.path` kuralı ekleyen conftest/OPA lint kuralı yazılacak. | Platform | P1 (Yüksek) | Planlandı |
| **ACT-03** | `verify-dashboards.sh` ile tüm Liveness Probe ve Pod Restart panelleri sürekli entegrasyonda test edilecek. | SRE | P1 (Yüksek) | Tamamlandı |
| **ACT-04** | GameDay senaryolarına "Liveness Probe Cascading Failure" testi kalıcı olarak eklenecek. | QA/Chaos | P2 (Orta) | Tamamlandı |
