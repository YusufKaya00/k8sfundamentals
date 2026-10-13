# 🚨 SRE Incident Lab 4: PulseMed Telemetry & Clinic Gateway Triage

This workspace serves as the active Incident Triage War Room during the production go-live failure of PulseMed, a mission-critical hospital telemetry and clinic monitoring platform.

All manifests deployed to the cluster were **schema-compliant** and accepted without syntax errors by the Kubernetes API server. However, severe service discovery failures, port mapping mismatches (`port` vs `targetPort`), probe misconfigurations, and scheduling constraints caused a cascading outage across all microservices.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Senior SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Cluster Topology & Infrastructure Constraints

The incident scenario is grounded strictly in the following 3-node cluster topology:

| Node Name | IP | Label | Constraint / Taint | Allocated Tier Role |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *None* | Web / API / Cache Workloads |
| **Node-2** | `10.0.10.208` | `tier=web` | *None* | Web / API / Cache Workloads |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Database Workloads Only (Isolated) |

* **StorageClass:** Default cluster storage class is `oci-bv` (Oracle Cloud Block Volume - `WaitForFirstConsumer`).

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all broken manifests to the cluster:

```bash
kubectl apply -f manifests/
```

Watch initial status:
```bash
kubectl get pods,svc,endpointslices -n pulse-prod -o wide
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the tickets sequentially:

---

### [INC-401] Telemetry Database Fails to Schedule — Pod Pending
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] StatefulSet pulse-prod/vitals-db pod vitals-db-0 is stuck in Pending. Storage volume unbound.`
* **Symptoms:**
  The `vitals-db-0` StatefulSet pod cannot be scheduled on any node and remains `Pending`. Its associated PVC (`vitals-storage-vitals-db-0`) cannot bind.
* **Verification:**
  * `kubectl get pod vitals-db-0 -n pulse-prod -o wide` shows the pod scheduled on `10.0.10.78` (`tier=database`) and reaching `1/1 Running`.
  * Database accepts connections on port 5432:
    ```bash
    kubectl exec -n pulse-prod vitals-db-0 -- pg_isready -U pulse_user -d pulse_vitals
    ```

---

### [INC-402] Database Running but Unreachable via Service — DNS NXDOMAIN & Empty Endpoints
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service pulse-prod/vitals-db has 0 active endpoints. Internal DNS queries for vitals-db return NXDOMAIN.`
* **Symptoms:**
  `vitals-db-0` is `1/1 Running`. However, other pods cannot resolve `vitals-db.pulse-prod.svc.cluster.local`, and the service has no endpoints (`Endpoints: <none>`).
* **Verification:**
  * `kubectl get endpointslices -l kubernetes.io/service-name=vitals-db -n pulse-prod` shows the pod IP and port `5432`.
  * Port check from another pod succeeds:
    ```bash
    kubectl exec -n pulse-prod deploy/session-store -- nc -zv vitals-db 5432
    ```

---

### [INC-403] Cache Service Refuses Connections — Connection Refused
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Service pulse-prod/session-store refuses TCP connections on port 6379 despite Redis pod running.`
* **Symptoms:**
  `session-store` (Redis) pod is `1/1 Running` and listening on port 6379. The EndpointSlice exists. However, TCP connections to `session-store:6379` are rejected with `Connection refused`.
* **Verification:**
  * `kubectl describe svc session-store -n pulse-prod` shows `Port` and `TargetPort` matching the container port.
  * Internal TCP ping succeeds:
    ```bash
    kubectl exec -n pulse-prod vitals-db-0 -- nc -zv session-store 6379
    ```

---

### [INC-404] Telemetry API Containers CrashLoopBackOff — Probe Connection Refused
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Deployment pulse-prod/telemetry-api containers are restarting continuously. Liveness/Readiness probes failing with connection refused.`
* **Symptoms:**
  `telemetry-api` starts and logs `Listening for traffic on 0.0.0.0:8080`. Yet Kubelet reports healthcheck probe failures (`connection refused`), keeps the pod `0/1 NotReady`, and kills the container repeatedly.
* **Verification:**
  * `kubectl get pods -l app.kubernetes.io/name=telemetry-api -n pulse-prod` shows restart count stabilized with zero container terminations.

---

### [INC-405] Telemetry API Stable but NotReady (0/1) — Upstream Database Port Mismatch
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Deployment pulse-prod/telemetry-api pods running but 0/1 Ready. /ready endpoint returns HTTP 503.`
* **Symptoms:**
  API pods stop crashing and remain `Running`, but report `0/1 NotReady`. The `/ready` check returns 503 indicating that while Redis is connected, attempts to reach `vitals-db` fail because the application attempts port 5433 instead of 5432.
* **Verification:**
  * `/ready` returns HTTP 200 with both `"vitals_db": "connected"` and `"session_store": "connected"`.
  * API pods reach `1/1 Ready`.

---

### [INC-406] Portal Proxy Returns 502 Bad Gateway — Service Port & Proxy Mismatch
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Portal proxy returns HTTP 502 Bad Gateway on /api/vitals. Upstream telemetry-api unreachable.`
* **Symptoms:**
  `telemetry-api` pods are `1/1 Ready`. But accessing `/api/vitals` through `portal-proxy` (Nginx) returns `502 Bad Gateway`. Nginx error logs report `Connection refused` connecting to upstream `http://telemetry-api:8080/`. The Service only exposes port 80.
* **Verification:**
  * Requests through `portal-proxy` return HTTP 200 with telemetry JSON.

---

### [INC-407] Portal Proxy High Availability Warning — 3rd Replica Pending
* **Priority:** `P3 - Medium`
* **Alert:**
  > `[WARNING] Deployment pulse-prod/portal-proxy desired replicas: 3, available: 2. One pod stuck in Pending.`
* **Symptoms:**
  Two `portal-proxy` replicas run on web nodes, but the 3rd replica remains `Pending` due to strict anti-affinity on a 2-web-node cluster.
* **Verification:**
  * `kubectl get deployment portal-proxy -n pulse-prod` reports `READY 3/3`, `AVAILABLE 3`, with zero pending pods.

---

## 🏁 Full Telemetry Platform Verification Methodology

```bash
# 1. Database & Storage Health
kubectl get pvc,pod -l app.kubernetes.io/name=vitals-db -n pulse-prod -o wide
kubectl exec -n pulse-prod vitals-db-0 -- pg_isready -U pulse_user -d pulse_vitals

# 2. Services, Ports, and EndpointSlices
kubectl get svc,endpointslices -n pulse-prod

# 3. Inter-Service Port Verification (nc -zv)
kubectl exec -n pulse-prod deploy/telemetry-api -- nc -zv vitals-db 5432
kubectl exec -n pulse-prod deploy/telemetry-api -- nc -zv session-store 6379

# 4. API Readiness and Telemetry Data
kubectl exec -n pulse-prod deploy/telemetry-api -- wget -qO- http://localhost:8080/ready
kubectl exec -n pulse-prod deploy/telemetry-api -- wget -qO- http://localhost:8080/api/vitals

# 5. Reverse Proxy & End-to-End User Simulation
kubectl exec -n pulse-prod deploy/portal-proxy -- wget -qO- http://localhost:8080/api/vitals
kubectl port-forward svc/portal-proxy -n pulse-prod 8090:80 &
curl -I http://localhost:8090/
curl -s http://localhost:8090/api/vitals

# 6. Cluster Topology & Node Distribution
kubectl get pods -n pulse-prod -o wide
```

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

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
