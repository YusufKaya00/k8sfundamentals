# NovaMarket (k8-troubleshoot-2) — SRE Incident Management & Triage Runbook

Bu çalışma alanı, NovaMarket e-ticaret platformunun canlıya geçişi sırasında yaşanan çok katmanlı operasyonel krizin olay yönetim (Incident Triage) masasıdır.

Küme genelinde uygulanan manifestolar Kubernetes API sunucusu tarafından **şema olarak hatasız kabul edilmiş**, ancak mimari ve operasyonel uyuşmazlıklar nedeniyle servisler zincirleme biçimde çökmüş veya trafiğe kapanmıştır.

---

## 🗺️ Mevcut Küme Topolojisi ve Altyapı Kısıtları

Laboratuvar senaryosu şu fiziksel topoloji üzerinde kurgulanmıştır:

| Node Adı | IP | Etiket (Label) | Kısıt / Taint | Tahsis Edilen Rol |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *Yok* | Web / API / Cache İş Yükleri |
| **Node-2** | `10.0.10.208` | `tier=web` | *Yok* | Web / API / Cache İş Yükleri |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Yalnızca Veritabanı (İzole) |

* **StorageClass:** Kümede varsayılan depolama sınıfı `oci-bv` (Oracle Cloud Block Volume - WaitForFirstConsumer) kullanılmaktadır.

---

## 🚀 Başlangıç: Bozuk Ortamı Kümeye Uygulama

Tüm bozuk manifestoları tek komutla kümeye uygulayın:

```bash
kubectl apply -f manifests/
```

Pod'ların ilk durumunu izleyin:

```bash
kubectl get pods -n nova-prod -o wide -w
```

---

## 📋 Nöbetçi SRE Olay Masası (Incident Board)

Her bileti sırasıyla ele alınız; bir önceki bilet çözülmeden sonraki katmanın hata çıktısı netleşmeyebilir.

---

### [INC-201] Veritabanı Pod'u Ayağa Kalkmıyor — Pod Pending & Storage Unbound
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Service nova-prod/postgres-0 has been in Pending state for > 5m. Database cluster unreachable. Customer orders blocked.`
* **Semptomlar:**
  Geliştirici ekibi veritabanı StatefulSet manifestosunu kümeye uyguladı. Ancak `postgres-0` pod'u hiçbir node üzerinde çalıştırılamıyor ve sürekli `Pending` durumunda bekliyor. İlgili `postgres-storage-postgres-0` PVC'si de kalıcı depolama alanı bağlayamıyor (`WaitingForFirstConsumer`).
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pod postgres-0 -n nova-prod -o wide` çıktısında pod'un başarıyla `10.0.10.78` (veritabanı node'u) üzerine schedule edildiği görülmelidir.
  * Pod durumu `Pending` durumundan çıkmalı ve depolama birimi (`oci-bv`) `Bound` hale gelmelidir.

> [!NOTE]
> *StatefulSet Operasyon Kuralı:* Kubernetes mimarisinde StatefulSet denetleyicisi `OrderedReady` ilkesi gereği takılı kalan pod'u manifest güncellense dahi her zaman otomatik yeniden başlatmayabilir. Pod'un yeni şablonla anında tetiklenmesi için manifest uygulandıktan sonra pod'un silinmesi (`kubectl delete pod postgres-0 -n nova-prod`) gerekebilir.

---

### [INC-202] Veritabanı Pod'u Çöküyor — CrashLoopBackOff & Storage Mount Hatası
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Pod nova-prod/postgres-0 is in CrashLoopBackOff. Exit Code: 1. Container terminating immediately after start.`
* **Semptomlar:**
  Veritabanı pod'u doğru node'a yerleşti ve disk bağlandı; ancak PostgreSQL konteyneri ayağa kalktıktan 1-2 saniye sonra çöküyor. Kubelet konteyneri tekrar başlattıkça çökme döngüsü devam ediyor (`CrashLoopBackOff`). Pod loglarında depolama alanının mount edildiği kök dizinle ilgili bir başlatma (initdb) engeli göze çarpıyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pod postgres-0 -n nova-prod` çıktısında pod `1/1 Running` olmalı ve `RESTARTS` sayısı sabit kalmalıdır.
  * Veritabanının canlı bağlantı kabul ettiği şu komutla teyit edilmelidir:
    ```bash
    kubectl exec -n nova-prod postgres-0 -- pg_isready -U novauser -d novadb
    ```
    *(Çıktı: `/var/run/postgresql:5432 - accepting connections` olmalıdır).*

---

### [INC-203] API Servisi Sürekli Yeniden Başlıyor — Warmup Aşamasında Pod Katliamı
* **Öncelik:** `P2 - High`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Deployment nova-prod/api containers are frequently killed and restarted by Kubelet. Exit code: 137. Service flapping.`
* **Semptomlar:**
  Backend API pod'ları ayağa kalkarken ilk açılışta 10 saniyelik bir önbellek ve konfigürasyon ısınma (warmup) sürecine girmektedir. Ancak Kubelet, konteyner açıldıktan yaklaşık 5-6 saniye sonra sürece müdahale etmekte, konteyneri öldürüp baştan başlatmaktadır (`Exit Code: 137`).
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get deployment api -n nova-prod` çıktısında pod'lar açılışta Kubelet tarafından öldürülmemeli ve en az 30 saniye kesintisiz çalışarak ısınma evresini tamamlayabilmelidir.

---

### [INC-204] API Pod'u Açıldıktan Sonra Çöküyor — Fatal DB Configuration Missing
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Deployment nova-prod/api pod exit code 1. Application initialization aborted: DB_HOST environment variable missing.`
* **Semptomlar:**
  Probe kontrolü esnetildikten sonra pod'lar artık Kubelet tarafından erken öldürülmüyor; fakat uygulama ısınma evresini tamamlar tamamlamaz loglara kritik bir ortam değişkeninin bulunamadığını (`[FATAL] DB_HOST environment variable is missing...`) yazarak `exit code 1` ile kendisini kapatıyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=api -n nova-prod` çıktısında pod'lar çökmeksizin `Running` durumunda kalmalıdır.
  * Pod loglarında şu satır görülmelidir:
    ```text
    [API] Listening for connections on port 8080...
    ```

---

### [INC-205] API Servisi Hazır Değil (0/1 NotReady) — Redis Önbellek İletişim Hatası
* **Öncelik:** `P2 - High`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Service nova-prod/api readiness probe failing with HTTP 503. Traffic not routed to backend.`
* **Semptomlar:**
  API pod'ları `Running` durumundadır ancak pod durumunda `READY: 0/1` yazmaktadır. Kubelet'in çağırdığı `/ready` kontrolü HTTP 503 döndürmektedir. API logları incelendiğinde servisin veritabanına ulaştığı, ancak Redis önbellek servisine bağlanmaya çalışırken `Connection refused` aldığı görülmektedir. İlginç olan, kümede `redis` pod'unun sağlıklı bir şekilde `1/1 Running` olarak çalışıyor olmasıdır.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get endpointslices -l kubernetes.io/service-name=redis -n nova-prod` çıktısında geçerli ve hazır bir pod IP'si listelenmelidir.
  * `kubectl get pods -l app.kubernetes.io/name=api -n nova-prod` çıktısında tüm replikalar `1/1 Ready` durumuna gelmelidir.
  * API pod'u içinden `/ready` sorgulandığında HTTP 200 dönmelidir:
    ```bash
    kubectl exec -n nova-prod deploy/api -- wget -qO- http://localhost:8080/ready
    ```
    *(Dönen JSON'da hem `"database": "connected"` hem de `"redis": "connected"` yer almalıdır).*

---

### [INC-206] Mağaza Arayüzü 503 Servis Dışı — Frontend Pod'ları NotReady (0/1)
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Storefront ingress returns HTTP 503 Service Temporarily Unavailable. Frontend service has no endpoints.`
* **Semptomlar:**
  Kullanıcılar web sitesine erişememekte ve 503 almaktadır. `frontend` deployment'ına ait pod'lar `Running` durumunda olmasına rağmen `0/1 Ready` durumundadır. Kubelet pod event'lerinde periyodik olarak sağlık kontrolünün HTTP 404 ile başarısız olduğunu bildirmektedir.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=frontend -n nova-prod` çıktısında çalışan pod'lar `1/1 Ready` durumuna geçmelidir.
  * `kubectl describe svc frontend -n nova-prod` çıktısında `Endpoints` satırı boş (`<none>`) olmamalı, pod IP'leri ile eşleşmelidir.

---

### [INC-207] Frontend Yüksek Erişilebilirlik (HA) Uyarısı — 3. Replika Pending
* **Öncelik:** `P3 - Medium`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Deployment nova-prod/frontend desired replicas: 3, available replicas: 2. High Availability policy violated.`
* **Semptomlar:**
  Frontend pod'larının ikisi sağlıklı şekilde ayağa kalktı ve trafiğe açıldı. Ancak Deployment 3 replika olarak yapılandırılmış olmasına rağmen 3. pod bir türlü schedule olamamakta ve `Pending` durumunda kalmaktadır. Kube-scheduler pod'u hiçbir node üzerine atayamamaktadır.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get deployment frontend -n nova-prod` çıktısında `READY 3/3`, `UP-TO-DATE 3`, `AVAILABLE 3` görülmeli, kümede hiçbir pod `Pending` kalmamalıdır.

---

## 🏁 FİNAL: Canlı Web Sitesi ve Mikroservis Sağlık Kontrol Metodolojisi

Tüm biletleri çözdükten sonra, kurumsal standartlarda bir üretim (production) web platformunun genel sağlık denetimi şu katmanlı sıra ile doğrulanmalıdır:

### 1. Katman: Veri & Durum Bilgisi (Stateful & Storage)
```bash
# 1.1 PVC ve PV bağlantısını doğrula
kubectl get pvc,pv -n nova-prod

# 1.2 Veritabanı canlılık ve bağlantı testi
kubectl exec -n nova-prod postgres-0 -- pg_isready -U novauser -d novadb
```

### 2. Katman: Servis Keşfi & Ağ Endpoint Doğrulaması (Service Discovery)
```bash
# Servislerin arkasındaki pod IP'lerinin eksiksiz dolduğunu teyit et
kubectl get endpoints,endpointslices -n nova-prod
```
*Hiçbir servisin Endpoint adresi `<none>` kalmamalıdır.*

### 3. Katman: Uygulama & Bağımlılık Sağlığı (Backend Readiness)
```bash
# API pod'unun kendi bağımlılıklarını (DB + Redis) doğruladığını gör
kubectl exec -n nova-prod deploy/api -- wget -qO- http://localhost:8080/ready
```
*JSON yanıtında `"database": "connected"` ve `"redis": "connected"` bulunmalıdır.*

### 4. Katman: Reverse Proxy & Ön Yüz Entegrasyonu (L7 Proxy Routing)
```bash
# Frontend pod'u içinden Nginx'in API proxy (/api/) yönlendirmesini test et
kubectl exec -n nova-prod deploy/frontend -- wget -qO- http://localhost:8080/api/products
```
*Nginx üzerinden API'nin döndürdüğü ürün listesi JSON olarak gelmelidir.*

### 5. Katman: Uçtan Uca Dış Erişim (End-to-End User Simulation)
```bash
# Lokal terminalinden port-forward açarak gerçek kullanıcı gibi bağlan
kubectl port-forward svc/frontend -n nova-prod 8088:80 &
curl -I http://localhost:8088/
curl -s http://localhost:8088/api/products
```
*HTTP 200 OK yanıtı ve JSON ürün kataloğu dönmelidir.*

### 6. Katman: Topoloji, Yüksek Erişilebilirlik ve Kısıt Denetimi
```bash
kubectl get pods -n nova-prod -o wide
```
*Kontrol Kriterleri:*
* `postgres-0` yalnızca `tier=database` etiketli ve tainted node üzerinde çalışmalıdır.
* `frontend`, `api` ve `redis` pod'ları `tier=web` etiketli worker node'lar üzerinde homojen dağılmış olmalıdır.
* Hiçbir pod `0/1 NotReady`, `Pending` veya `CrashLoopBackOff` durumunda olmamalıdır.
