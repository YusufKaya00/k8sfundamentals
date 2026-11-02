# 🚨 SRE Incident Lab 3: ApexPay Financial Gateway Outage Triage & Runbook

This workspace serves as the active Incident Triage War Room during the production go-live failure of ApexPay, a real-time financial settlement and transaction processing platform.

All manifests deployed to the cluster were **schema-compliant** and validated without syntax errors by the Kubernetes API server. However, system-level issues across Linux VFS mount overlays, non-root storage permissions (`fsGroup`), socket interface binding (`127.0.0.1` vs `0.0.0.0`), CPU request limits, and named port mapping resulted in a multi-tier platform outage.

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

Apply all manifests to the cluster:

```bash
kubectl apply -f manifests/
```

Watch initial pod status:
```bash
kubectl get pods -n apex-prod -o wide -w
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the tickets sequentially:

---

### [INC-301] Ledger Database Pod Fails to Schedule — Pod Pending
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] StatefulSet apex-prod/ledger-db pod is in Pending state. Database volume unbound. Financial ledger offline.`
* **Symptoms:**
  The `ledger-db-0` StatefulSet pod cannot be assigned to any node and remains `Pending`. Its associated PVC (`ledger-storage-ledger-db-0`) cannot bind (`WaitingForFirstConsumer`). Scheduler reports node affinity mismatch.
* **Verification:**
  * `kubectl get pod ledger-db-0 -n apex-prod -o wide` shows the pod scheduled on `10.0.10.78` (`tier=database`).
  * Pod starts and storage transitions to `Bound`.

---

### [INC-302] Ledger Database Cannot Start — Non-Root Disk Permission Denied
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Pod apex-prod/ledger-db-0 entered CrashLoopBackOff. Exit code: 1. PostgreSQL initialization script aborted.`
* **Symptoms:**
  Disk binds, but PostgreSQL initialization fails at the Linux VFS filesystem layer (`Permission denied`) because the mounted block volume is owned by `root:root` while PostgreSQL runs as non-root UID 999. Pod enters `CrashLoopBackOff`.
* **Verification:**
  * `ledger-db-0` reaches `1/1 Running` with zero restarts.
  * Verify database connectivity:
    ```bash
    kubectl exec -n apex-prod ledger-db-0 -- pg_isready -U apex_admin -d apex_ledger
    ```
    *(Output must report: `/var/run/postgresql:5432 - accepting connections`).*

---

### [INC-303] Payment API Pods Unschedulable — CPU Request Exceeds Node Capacity
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Deployment apex-prod/payment-api has 0/2 available replicas. Pods unschedulable across all worker nodes.`
* **Symptoms:**
  Both `payment-api` replicas remain indefinitely in `Pending`. Kube-scheduler events report `0/3 nodes available: Insufficient cpu`.
* **Verification:**
  * `kubectl get pods -l app.kubernetes.io/name=payment-api -n apex-prod -o wide` shows both replicas scheduled onto `tier=web` worker nodes (`10.0.10.122` and `10.0.10.208`).

---

### [INC-304] Payment API Container CrashLoopBackOff — Application Entrypoint Missing
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Pod apex-prod/payment-api-* failing at startup. Python runtime error: file not found. Exit code: 2.`
* **Symptoms:**
  Pods schedule, but crash immediately on container boot (`CrashLoopBackOff`, Exit Code 2). Logs report: `python: can't open file '/app/server.py': [Errno 2] No such file or directory`. A directory volume mount masked the existing container `/app` directory.
* **Verification:**
  * Pods no longer crash due to missing files and start the application runtime.

---

### [INC-305] Payment API Containers Periodically Killed — Liveness Probe Timeout
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Deployment apex-prod/payment-api containers are periodically killed by Kubelet. Liveness probe timeout.`
* **Symptoms:**
  API starts, but Kubelet kills containers every 20-30 seconds (`RESTARTS` count increments continuously). Events report liveness probe timeouts (`context deadline exceeded`).
* **Verification:**
  * Pods remain uninterrupted in `Running` state for over 2 minutes without Kubelet termination.

---

### [INC-306] Cache Service Unreachable — Named Port Resolution Failure
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Service apex-prod/transaction-cache cannot resolve target port. Backend cache connectivity broken.`
* **Symptoms:**
  The `transaction-cache` (Redis) pod is `1/1 Running`. However, TCP traffic to `transaction-cache:6379` is rejected. The Service and Endpoint configurations show a mismatch in named port resolution.
* **Verification:**
  * `kubectl get endpointslices -l kubernetes.io/service-name=transaction-cache -n apex-prod` lists port 6379 with healthy endpoints.
  * Internal TCP ping succeeds:
    ```bash
    kubectl exec -n apex-prod deploy/gateway -- nc -zv transaction-cache 6379
    ```

---

### [INC-307] Gateway Returns 502 Bad Gateway — Localhost Socket Isolation
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Webhook / Transaction gateway returns HTTP 502 Bad Gateway on all /api/ requests. Upstream connection refused.`
* **Symptoms:**
  All pods report `Running` and `Ready`. Yet Gateway returns HTTP 502 on `/api/transactions` with Nginx upstream errors: `connect() failed (111: Connection refused) while connecting to upstream: http://payment-api:8080/`. However, running `curl 127.0.0.1:8080` from inside `payment-api` succeeds! The process is bound to loopback `127.0.0.1` instead of `0.0.0.0`.
* **Verification:**
  * `kubectl exec -n apex-prod deploy/gateway -- wget -qO- http://payment-api:8080/api/transactions` returns HTTP 200 with the transaction JSON list.
  * Gateway no longer emits 502 Bad Gateway.

---

## 🏁 Full Financial Platform Health Verification Methodology

```bash
# 1. Ledger Database & Storage Health
kubectl get pvc,pv -n apex-prod
kubectl exec -n apex-prod ledger-db-0 -- pg_isready -U apex_admin -d apex_ledger

# 2. Idempotency Cache & EndpointSlice Verification
kubectl get endpointslices -l kubernetes.io/service-name=transaction-cache -n apex-prod
kubectl exec -n apex-prod deploy/gateway -- nc -zv transaction-cache 6379

# 3. Payment API Readiness Verification
kubectl exec -n apex-prod deploy/payment-api -c payment-api -- wget -qO- http://localhost:8080/ready

# 4. Reverse Proxy L7 Integration
kubectl exec -n apex-prod deploy/gateway -- wget -qO- http://localhost:8080/api/transactions

# 5. External End-to-End Simulation
kubectl port-forward svc/gateway -n apex-prod 8089:80 &
curl -I http://localhost:8089/
curl -s http://localhost:8089/api/transactions

# 6. Cluster Topology & Node Distribution
kubectl get pods -n apex-prod -o wide
```

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# ApexPay (k8-troubleshoot-3) — SRE Incident Management & Triage Runbook

Bu çalışma alanı, ApexPay gerçek zamanlı finansal mutabakat ve işlem platformunun canlı ortama geçişinde yaşanan zincirleme operasyonel krizin olay müdahale (Incident Triage) masasıdır.

Küme genelinde uygulanan manifestolar Kubernetes API sunucusu tarafından **şema olarak hatasız kabul edilmiş**, ancak mimari, işletim sistemi izinleri ve ağ seviyesindeki uyuşmazlıklar nedeniyle servisler zincirleme biçimde çökmüş veya izole kalmıştır.

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

Pod'ların ilk durumunu izleyin:

```bash
kubectl get pods -n apex-prod -o wide -w
```

---

## 📋 Nöbetçi SRE Olay Masası (Incident Board)

Her bileti sırasıyla ele alınız; bir önceki bilet çözülmeden sonraki katmanın hata çıktısı netleşmeyebilir.

---

### [INC-301] Ledger Veritabanı Pod'u Schedule Olamıyor — Pod Pending
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] StatefulSet apex-prod/ledger-db pod is in Pending state. Database volume unbound. Financial ledger offline.`
* **Semptomlar:**
  Veritabanı StatefulSet manifestosu kümeye uygulandı ancak `ledger-db-0` pod'u hiçbir node üzerine atanamıyor ve `Pending` durumunda bekliyor. İlgili `ledger-storage-ledger-db-0` PVC'si de kalıcı depolama birimi bağlayamıyor (`WaitingForFirstConsumer`). Kubelet pod event'lerinde tüm node'ların elendiğini raporluyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pod ledger-db-0 -n apex-prod -o wide` çıktısında pod'un `10.0.10.78` (veritabanı node'u) üzerine schedule edildiği görülmelidir.
  * Pod durumu `Pending` durumundan çıkmalı ve depolama birimi (`oci-bv`) `Bound` hale gelmelidir.

> [!NOTE]
> *StatefulSet Kuralı:* StatefulSet denetleyicisi manifest güncellendiğinde takılı kalan pod'u her zaman otomatik olarak yeniden tetiklemeyebilir. Güncelleme uygulandıktan sonra pod'un silinmesi (`kubectl delete pod ledger-db-0 -n apex-prod`) gerekebilir.

---

### [INC-302] Ledger Veritabanı Başlatılamıyor — Non-Root Disk İzin Hatası (Permission Denied)
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Pod apex-prod/ledger-db-0 entered CrashLoopBackOff. Exit code: 1. PostgreSQL initialization script aborted.`
* **Semptomlar:**
  Pod veritabanı node'una yerleşti ve disk bağlandı; ancak PostgreSQL başlatma sürecinde dosya sistemi seviyesinde erişim engeline takılıyor ve pod `CrashLoopBackOff` döngüsüne giriyor. Pod logları incelendiğinde bağlanan depolama dizini altında veritabanı başlatılırken (initdb) izin hatası (`Permission denied`) alındığı görülüyor.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pod ledger-db-0 -n apex-prod` çıktısında pod `1/1 Running` olmalı ve `RESTARTS` sayısı artmamalıdır.
  * Veritabanının canlı bağlantı kabul ettiği şu komutla teyit edilmelidir:
    ```bash
    kubectl exec -n apex-prod ledger-db-0 -- pg_isready -U apex_admin -d apex_ledger
    ```
    *(Çıktı: `/var/run/postgresql:5432 - accepting connections` olmalıdır).*

---

### [INC-303] Ödeme API Pod'ları Schedule Edilemiyor — Kaynak Talebi Düğüm Sınırını Aşıyor
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Deployment apex-prod/payment-api has 0/2 available replicas. Pods unschedulable across all worker nodes.`
* **Semptomlar:**
  `payment-api` deployment'ı ayağa kaldırılmaya çalışıldığında iki replika da hiçbir worker node üzerinde çalıştırılamamakta ve sürekli `Pending` kalmaktadır. Kube-scheduler pod event'lerinde worker node'ların kaynak yetersizliği sebebiyle elendiğini bildirmektedir.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=payment-api -n apex-prod -o wide` çıktısında her iki pod'un da `tier=web` etiketli worker node'lar (`10.0.10.122` ve `10.0.10.208`) üzerine schedule edildiği görülmelidir.

---

### [INC-304] Ödeme API Konteyneri Açılırken Çöküyor — Uygulama Giriş Dosyası Bulunamadı
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Pod apex-prod/payment-api-* failing at startup. Python runtime error: file not found. Exit code: 2.`
* **Semptomlar:**
  Pod'lar web worker node'larına schedule edildi; fakat konteyner başladığı saniye çökmekte ve pod'lar `CrashLoopBackOff` durumuna düşmektedir. Pod logları incelendiğinde Python yorumlayıcısının `/app/server.py` dosyasını bulamadığı (`[Errno 2] No such file or directory`) görülmektedir.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=payment-api -n apex-prod` çıktısında konteynerler dosya eksikliği nedeniyle çökmemeli ve uygulama process'i ayağa kalkabilmelidir.

---

### [INC-305] Ödeme API Pod'ları Sürekli Öldürülüyor — Liveness Probe Zaman Aşımı
* **Öncelik:** `P2 - High`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Deployment apex-prod/payment-api containers are periodically killed by Kubelet. Liveness probe timeout.`
* **Semptomlar:**
  API servisi artık başlamakta ve loglarda çalıştığı görülmektedir. Ancak yaklaşık her 20-30 saniyede bir Kubelet pod'lara müdahale etmekte ve konteynerleri yeniden başlatmaktadır (`RESTARTS` sayacı sürekli artmaktadır). Pod event'lerinde sağlık kontrolünün zaman aşımına (`context deadline exceeded`) uğradığı belirtilmektedir.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get pods -l app.kubernetes.io/name=payment-api -n apex-prod` çıktısında pod'lar Kubelet tarafından öldürülmeden en az 2 dakika boyunca kesintisiz `Running` kalmalıdır.

---

### [INC-306] Önbellek Servisine Ulaşılamıyor — Named Port Çözümleme Hatası
* **Öncelik:** `P2 - High`
* **Alarm (PagerDuty / Slack):**
  > `[WARNING] Service apex-prod/transaction-cache cannot resolve target port. Backend cache connectivity broken.`
* **Semptomlar:**
  `transaction-cache` (Redis) pod'u `1/1 Running` durumundadır. Ancak diğer pod'lar veya servisler üzerinden `transaction-cache:6379` servisine erişilmeye çalışıldığında trafik pod'a ulaşmamakta ve bağlantı kurulamamaktadır. Servis ve Endpoint tanımları incelendiğinde port yönlendirmesinde bir uyumsuzluk olduğu görülmektedir.
* **Başarı Kriteri & Doğrulama:**
  * `kubectl get endpointslices -l kubernetes.io/service-name=transaction-cache -n apex-prod` çıktısında geçerli bir pod IP'si ve port numarası (6379) listelenmelidir.
  * Küme içinden `transaction-cache:6379` servisine ping atılabildiğinde PONG yanıtı alınmalıdır:
    ```bash
    kubectl exec -n apex-prod deploy/gateway -- nc -zv transaction-cache 6379
    ```

---

### [INC-307] Gateway API'ye Bağlanamıyor — 502 Bad Gateway & Localhost İzolasyonu
* **Öncelik:** `P1 - Blocker`
* **Alarm (PagerDuty / Slack):**
  > `[CRITICAL] Webhook / Transaction gateway returns HTTP 502 Bad Gateway on all /api/ requests. Upstream connection refused.`
* **Semptomlar:**
  Tüm pod'lar (`gateway`, `payment-api`, `transaction-cache`, `ledger-db`) `Running` ve `Ready` durumundadır. Ancak kullanıcılar veya webhook istemcileri Gateway üzerinden `/api/transactions` çağırdığında Nginx HTTP 502 dönmektedir. Nginx hata loglarında `connect() failed (111: Connection refused) while connecting to upstream: http://payment-api:8080/` yazmaktadır. İlginç şekilde `payment-api` pod'unun kendi içine girip `curl 127.0.0.1:8080` yapıldığında API çalışmaktadır!
* **Başarı Kriteri & Doğrulama:**
  * `kubectl exec -n apex-prod deploy/gateway -- wget -qO- http://payment-api:8080/api/transactions` komutu başarıyla HTTP 200 ve JSON işlem listesini döndürmelidir.
  * Gateway üzerinden yapılan `/api/transactions` sorgusu 502 vermemelidir.

---

## 🏁 FİNAL: Üretim Standardında Finansal Gateway Sağlık Kontrol Metodolojisi

Tüm biletleri çözdükten sonra, finansal bir mikroservis platformunun operasyonel doğrulaması katman katman şu sırayla yapılmalıdır:

### 1. Katman: Finansal Veri Defteri & Durum Bilgisi (Ledger Database & Storage)
```bash
# 1.1 PVC ve PV durumunu doğrula (Bound ve oci-bv olmalı)
kubectl get pvc,pv -n apex-prod

# 1.2 Veritabanı motorunun bağlantı kabul ettiğini doğrula
kubectl exec -n apex-prod ledger-db-0 -- pg_isready -U apex_admin -d apex_ledger
```

### 2. Katman: İdempotency Önbellek Servisi & EndpointSlice Doğrulaması
```bash
# 2.1 Redis servisinin arkasındaki EndpointSlice'ın hazır olduğunu gör
kubectl get endpointslices -l kubernetes.io/service-name=transaction-cache -n apex-prod

# 2.2 Redis TCP portunun açık ve dinlemede olduğunu doğrula
kubectl exec -n apex-prod deploy/gateway -- nc -zv transaction-cache 6379
```

### 3. Katman: Ödeme API'sinin Bağımlılık Doğrulaması (Readiness)
```bash
# API'nin kendi içindeki veritabanı ve önbellek bağlantısını doğruladığını gör
kubectl exec -n apex-prod deploy/payment-api -c payment-api -- wget -qO- http://localhost:8080/ready
```
*Dönen JSON'da `"ledger_database": "connected"` ve `"idempotency_cache": "connected"` bulunmalıdır.*

### 4. Katman: Gateway Ters Proxy & Yönlendirme (L7 Proxy Integration)
```bash
# Gateway üzerinden API'ye proxy edilen finansal işlem kataloğunu sorgula
kubectl exec -n apex-prod deploy/gateway -- wget -qO- http://localhost:8080/api/transactions
```
*HTTP 200 ile JSON formatında finansal işlem kayıtları (`APX-88019` vb.) dönmelidir.*

### 5. Katman: Uçtan Uca Dış Erişim & Port-Forward Simülasyonu
```bash
# Gateway servisine port-forward açarak dış istemci gibi bağlan
kubectl port-forward svc/gateway -n apex-prod 8089:80 &
curl -I http://localhost:8089/
curl -s http://localhost:8089/api/transactions
```
*HTTP 200 OK yanıtı ve JSON listesi alınmalıdır.*

### 6. Katman: Küme Topolojisi ve Düğüm Dağılım Denetimi
```bash
kubectl get pods -n apex-prod -o wide
```
*Kontrol Kriterleri:*
* `ledger-db-0` pod'u yalnızca `10.0.10.78` (`tier=database`) node'u üzerinde çalışmalıdır.
* `payment-api`, `transaction-cache` ve `gateway` pod'ları `10.0.10.122` ve `10.0.10.208` (`tier=web`) node'ları üzerinde dengeli dağılmış olmalıdır.
* Hiçbir pod `Pending`, `CrashLoopBackOff` veya `NotReady (0/1)` durumunda olmamalıdır.
