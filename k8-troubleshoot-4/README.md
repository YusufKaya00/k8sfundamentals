# PulseMed (k8-troubleshoot-4) — SRE Incident Management & Triage Runbook

Bu çalışma alanı, PulseMed gerçek zamanlı hasta telemetri ve klinik izleme platformunun canlıya geçişi sırasında yaşanan servis, port, sağlık kontrolü ve topoloji kaynaklı zincirleme kesintilerin olay müdahale (Incident Triage) masasıdır.

Küme genelinde uygulanan manifestolar Kubernetes API sunucusu tarafından **şema olarak hatasız kabul edilmiş**, ancak servis keşfi (Service Discovery), port eşleştirmeleri, probe yapılandırmaları ve düğüm kısıtları nedeniyle sistem trafiğe kapanmıştır.

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

Tüm manifestoları tek komutla kümeye uygulayın:

```bash
kubectl apply -f manifests/
```

Pod'ların ve servislerin ilk durumunu izleyin:

```bash
kubectl get pods,svc,endpointslices -n pulse-prod -o wide
```

---

## 📋 Nöbetçi SRE Olay Masası (Incident Board)

Her bileti sırasıyla ele alınız; alt katmanlardaki servis ve port sorunları çözülmeden üst katmanların bağımlılık kontrolleri yeşile dönmeyecektir.

---

### [INC-401] Hasta Telemetri Veritabanı Ayağa Kalkmıyor — Pod Pending
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] StatefulSet pulse-prod/vitals-db pod vitals-db-0 is stuck in Pending. Storage volume unbound.`
* **Semptomlar:**
  Veritabanı StatefulSet manifestosu uygulandı ancak `vitals-db-0` pod'u hiçbir node üzerinde çalıştırılamıyor ve `Pending` durumunda bekliyor. İlgili `vitals-storage-vitals-db-0` PVC'si de `WaitingForFirstConsumer` aşamasında bekliyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pod vitals-db-0 -n pulse-prod -o wide` çıktısında pod'un `10.0.10.78` (`tier=database`) node'u üzerine yerleştiği ve `1/1 Running` durumuna geçtiği görülmelidir.
  * Pod'un içine girerek veritabanı motorunun 5432 portunda bağlantı kabul ettiği doğrulanmalıdır:
    ```bash
    kubectl exec -n pulse-prod vitals-db-0 -- pg_isready -U pulse_user -d pulse_vitals
    ```

> [!NOTE]
> *StatefulSet Kuralı:* StatefulSet denetleyicisi `Pending` durumunda takılı kalan pod'u manifest güncellendiğinde her zaman kendiliğinden yeniden başlatmayabilir. Manifest uygulandıktan sonra pod'u silerek (`kubectl delete pod vitals-db-0 -n pulse-prod`) yeni şablonla oluşmasını sağlayabilirsiniz.

---

### [INC-402] Veritabanı Çalışıyor Ama Servis Üzerinden Erişilemiyor — DNS NXDOMAIN & Boş Endpoint
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Service pulse-prod/vitals-db has 0 active endpoints. Internal DNS queries for vitals-db return NXDOMAIN.`
* **Semptomlar:**
  `vitals-db-0` pod'u `1/1 Running` durumuna geçti ve kendi içinde PostgreSQL çalışıyor. Ancak kümedeki diğer pod'lar `vitals-db.pulse-prod.svc.cluster.local` adresini çözemiyor ve servisin arkasında hiçbir pod IP'si görünmüyor (`Endpoints: <none>`).
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get endpointslices -l kubernetes.io/service-name=vitals-db -n pulse-prod` çıktısında `vitals-db-0` pod'unun IP adresi ve `5432` portu görünmelidir.
  * Başka bir pod içinden veritabanı servisine port kontrolü yapıldığında bağlantı başarılı olmalıdır:
    ```bash
    kubectl exec -n pulse-prod deploy/session-store -- nc -zv vitals-db 5432
    ```

---

### [INC-403] Önbellek (Redis) Servisi Bağlantıyı Reddediyor — Connection Refused
* **Öncelik:** `P2 - High`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Service pulse-prod/session-store refuses TCP connections on port 6379 despite Redis pod running.`
* **Semptomlar:**
  `session-store` (Redis) pod'u `1/1 Running` durumunda ve kendi içinde `6379` portunu dinliyor. Servisin EndpointSlice listesinde de pod IP'si mevcut. Ancak küme içinden `session-store:6379` servisine bağlanılmaya çalışıldığında paketler `Connection refused` hatasıyla geri dönüyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl describe svc session-store -n pulse-prod` çıktısında `Port` ve `TargetPort` değerlerinin konteynerin gerçekte dinlediği portla birebir örtüştüğü görülmelidir.
  * Küme içinden Redis servisine erişim testi başarılı olmalıdır:
    ```bash
    kubectl exec -n pulse-prod vitals-db-0 -- nc -zv session-store 6379
    ```

---

### [INC-404] Telemetry API Pod'ları Sürekli Yeniden Başlıyor — CrashLoopBackOff
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Deployment pulse-prod/telemetry-api containers are restarting continuously. Liveness/Readiness probes failing with connection refused.`
* **Semptomlar:**
  `telemetry-api` pod'ları başlıyor ve loglarında `[Telemetry-API] Listening for traffic on 0.0.0.0:8080` mesajı görülüyor. Buna rağmen Kubelet pod'un sağlık kontrollerinin başarısız olduğunu (`connection refused`) raporluyor, pod'u `0/1 NotReady` tutuyor ve birkaç saniye sonra konteyneri öldürüp yeniden başlatıyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=telemetry-api -n pulse-prod` çıktısında pod'ların `RESTARTS` sayısının artması durmalı ve konteynerler Kubelet tarafından öldürülmemelidir.

---

### [INC-405] Telemetry API Çökmüyor Ama Hazır Değil (0/1 NotReady) — Bağımlılık Port Hatası
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Deployment pulse-prod/telemetry-api pods running but 0/1 Ready. /ready endpoint returns HTTP 503.`
* **Semptomlar:**
  Probe portları düzeltildikten sonra `telemetry-api` pod'ları artık yeniden başlamıyor ve `Running` kalıyor; fakat `READY` durumu `0/1` olarak bekliyor. Pod'un içine girip `/ready` endpoint'i sorgulandığında veya loglara bakıldığında, API'nin `session-store` (Redis) servisine bağlanabildiği ancak `vitals-db` veritabanına bağlanırken yanlış bir port numarası denediği görülüyor.
* **Başarı Kriteri & Doğrulama:**
  * API pod'u içinden `/ready` sorgulandığında HTTP 200 ve her iki bağımlılığın da `"connected"` olduğu JSON yanıtı alınmalıdır:
    ```bash
    kubectl exec -n pulse-prod deploy/telemetry-api -- wget -qO- http://localhost:8080/ready
    ```
  * `kubectl get pods -l app.kubernetes.io/name=telemetry-api -n pulse-prod` çıktısında her iki replika da `1/1 Ready` olmalıdır.

---

### [INC-406] Portal Proxy 502 Bad Gateway Veriyor — Servis Portu ve Proxy Uyuşmazlığı
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Portal proxy returns HTTP 502 Bad Gateway on /api/vitals. Upstream telemetry-api unreachable.`
* **Semptomlar:**
  `telemetry-api` pod'ları `1/1 Ready` ve kendi içlerinde `/api/vitals` çağrısına yanıt veriyorlar. Ancak `portal-proxy` (Nginx) üzerinden `/api/vitals` çağrıldığında `502 Bad Gateway` alınıyor. Nginx loglarında `connect() failed (111: Connection refused) while connecting to upstream: http://telemetry-api:8080/` hatası yer alıyor.
* **Başarı Kriteri & Doğrulama:**
  * `portal-proxy` pod'u içinden hem doğrudan API servisine hem de yerel Nginx proxy üzerinden yapılan istekler HTTP 200 ve hasta telemetri JSON verisini döndürmelidir:
    ```bash
    kubectl exec -n pulse-prod deploy/portal-proxy -- wget -qO- http://localhost:8080/api/vitals
    ```

---

### [INC-407] Portal Proxy Yüksek Erişilebilirlik Uyarısı — 3. Replika Pending
* **Öncelik:** `P3 - Medium`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Deployment pulse-prod/portal-proxy desired replicas: 3, available: 2. One pod stuck in Pending.`
* **Semptomlar:**
  `portal-proxy` pod'larının 2 tanesi `tier=web` node'larında çalışıyor ancak 3. replika `Pending` durumunda bekliyor ve hiçbir node'a atanamıyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get deployment portal-proxy -n pulse-prod` çıktısında `READY 3/3`, `UP-TO-DATE 3`, `AVAILABLE 3` görülmeli, kümede `Pending` pod kalmamalıdır.

---

## 🏁 FİNAL: Canlı Telemetri Web Platformu Katmanlı Sağlık Kontrol Metodolojisi

Tüm biletleri çözdükten sonra, sistemin uçtan uca sağlıklı çalıştığını içeriden dışarıya (Bottom-Up) şu komutlarla doğrulayın:

### 1. Katman: Veritabanı & Kalıcı Disk Kontrolü
```bash
# PVC'nin Bound olduğunu ve pod'un database node'unda çalıştığını gör
kubectl get pvc,pod -l app.kubernetes.io/name=vitals-db -n pulse-prod -o wide

# PostgreSQL'in bağlantı kabul ettiğini doğrula
kubectl exec -n pulse-prod vitals-db-0 -- pg_isready -U pulse_user -d pulse_vitals
```

### 2. Katman: Servisler, Portlar ve EndpointSlice Eşleşmesi
```bash
# Tüm servislerin port/targetPort yapılandırmasını ve EndpointSlice IP:Port çiftlerini kontrol et
kubectl get svc,endpointslices -n pulse-prod
```
*Kontrol:*
* `vitals-db` EndpointSlice $\rightarrow$ `5432`
* `session-store` EndpointSlice $\rightarrow$ `6379`
* `telemetry-api` EndpointSlice $\rightarrow$ `8080`
* `portal-proxy` EndpointSlice $\rightarrow$ `8080`

### 3. Katman: Pod İçinden Ağ & Port Erişilebilirlik Testi (`nc -zv`)
```bash
# API pod'undan veritabanı ve Redis servis portlarına TCP erişimini doğrula
kubectl exec -n pulse-prod deploy/telemetry-api -- nc -zv vitals-db 5432
kubectl exec -n pulse-prod deploy/telemetry-api -- nc -zv session-store 6379
```

### 4. Katman: API Hazırlık (`/ready`) ve Veri (`/api/vitals`) Kontrolü
```bash
kubectl exec -n pulse-prod deploy/telemetry-api -- wget -qO- http://localhost:8080/ready
kubectl exec -n pulse-prod deploy/telemetry-api -- wget -qO- http://localhost:8080/api/vitals
```

### 5. Katman: Nginx Reverse Proxy & Uçtan Uca Kullanıcı Testi
```bash
# Portal Proxy üzerinden API yönlendirmesini test et
kubectl exec -n pulse-prod deploy/portal-proxy -- wget -qO- http://localhost:8080/api/vitals

# Lokal port-forward ile dış kullanıcı gibi bağlan
kubectl port-forward svc/portal-proxy -n pulse-prod 8090:80 &
curl -I http://localhost:8090/
curl -s http://localhost:8090/api/vitals
```

### 6. Katman: Küme Genel Durum ve Topoloji Denetimi
```bash
kubectl get pods -n pulse-prod -o wide
```
*Hiçbir pod `Pending`, `CrashLoopBackOff` veya `0/1 NotReady` olmamalı; `RESTARTS` sayıları sabit kalmalıdır.*
