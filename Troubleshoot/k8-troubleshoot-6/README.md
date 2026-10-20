# 🚨 SRE Incident Lab 6: AeroOps Flight Radar & Mesh Dispatch Triage

This workspace serves as the active Incident Triage War Room during the production go-live failure of **AeroOps Global**, a mission-critical real-time flight telemetry, transponder tracking, and air traffic control dispatch mesh.

All manifests deployed to the cluster were **schema-compliant** and accepted without syntax errors by the Kubernetes API server. However, database taint scheduling failures, Headless Service DNS mismatches, cache port translation bugs, container probe failures, upstream ConfigMap typos, Service selector label drift, reverse proxy upstream mismatches, and strict pod anti-affinity scheduling conflicts have paralyzed the flight tracking platform.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Senior SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Cluster Topology & Infrastructure Constraints

The incident scenario is grounded strictly in the following 3-node cluster topology:

| Node Name | IP | Label | Constraint / Taint | Allocated Tier Role |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-2** | `10.0.10.208` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Database Workloads Only (Isolated) |

* **Target Namespace:** `aero-prod`
* **Networking Plane:** OCI VCN-Native Pod Networking, kube-proxy, CoreDNS.

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all broken manifests to the cluster:

```bash
kubectl apply -f manifests/
```

Watch initial status:
```bash
kubectl get pods,svc,endpointslices -n aero-prod -o wide
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the tickets sequentially:

---

### [INC-601] Radar Database Pod Stuck in Pending — Toleration Mismatch
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] StatefulSet aero-prod/radar-db pod radar-db-0 cannot be scheduled. Pod stuck in Pending.`
* **Symptoms:**
  The `radar-db-0` StatefulSet pod cannot bind to any node. Events report `0/3 nodes are available: 1 node has untolerated taint, 2 nodes didn't match Pod's node affinity/selector`.
* **Verification:**
  * `kubectl get pod radar-db-0 -n aero-prod -o wide` shows the pod scheduled on `10.0.10.78` (`Node-3`) and reaching `1/1 Running`.
  * Database accepts connections on port 5432:
    ```bash
    kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry
    ```

---

### [INC-602] Radar Database Running but Unreachable via Service — DNS NXDOMAIN & Empty Endpoints
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service aero-prod/radar-db has 0 active endpoints. CoreDNS queries for radar-db-0.radar-db return NXDOMAIN.`
* **Symptoms:**
  `radar-db-0` is `1/1 Running` on Node-3. However, other microservices fail to resolve `radar-db-0.radar-db.aero-prod.svc.cluster.local`, and the database service has no endpoints (`Endpoints: <none>`).
* **Verification:**
  * `kubectl get endpoints radar-db -n aero-prod` shows `10.0.10.78:5432`.
  * TCP port check from the cache pod succeeds:
    ```bash
    kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
    ```

---

### [INC-603] Flight Track Cache Refuses TCP Traffic — Connection Refused
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service aero-prod/track-cache refuses TCP connections on port 6379 despite Redis pod running healthy.`
* **Symptoms:**
  The `track-cache` (Redis) pod is `1/1 Running` and listening on port 6379. The Service has endpoints. However, TCP connections to `track-cache:6379` are rejected with `Connection refused`.
* **Verification:**
  * `kubectl describe svc track-cache -n aero-prod` confirms port mapping forwards to the active Redis port.
  * Internal TCP ping from the database pod succeeds:
    ```bash
    kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379
    ```

---

### [INC-604] Telemetry API Containers CrashLoopBackOff — Probe Connection Refused
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Deployment aero-prod/telemetry-api containers restarting continuously. Health probes failing with connection refused.`
* **Symptoms:**
  `telemetry-api` starts and logs `Listening on 0.0.0.0:8080`. Yet Kubelet reports healthcheck probe failures (`connection refused`), keeps the pod `0/1 NotReady`, and terminates the containers repeatedly.
* **Verification:**
  * `kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod` shows restart count stabilized with zero container restarts.
  * Internal health probe returns HTTP 200:
    ```bash
    kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
    ```

---

### [INC-605] Telemetry API Stable but NotReady (0/1) — Upstream Database Port Mismatch
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Deployment aero-prod/telemetry-api pods running but 0/1 Ready. /ready endpoint returns HTTP 503.`
* **Symptoms:**
  API pods stop crashing and remain `Running`, but report `0/1 NotReady`. The `/ready` check returns HTTP 503 indicating that while Redis is connected, attempts to reach `radar-db` fail because the application config attempts port 5433 instead of 5432.
* **Verification:**
  * `/ready` returns HTTP 200 with `"ready": true`:
    ```bash
    kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready
    ```
  * API pods reach `1/1 Ready`.

---

### [INC-606] Telemetry API Service Has Empty Endpoints — Selector Label Drift
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service aero-prod/telemetry-api has 0 active endpoints. Downstream gateway traffic cannot route.`
* **Symptoms:**
  Both `telemetry-api` pods are `1/1 Ready`. However, `kubectl get endpoints telemetry-api` returns `<none>`, and requests sent to `telemetry-api:8080` are dropped.
* **Verification:**
  * `kubectl get endpoints telemetry-api -n aero-prod` shows 2 active pod endpoints on port 8080.
  * Port check from the gateway pod succeeds:
    ```bash
    kubectl exec -n aero-prod deploy/flight-gateway -- nc -zv telemetry-api 8080
    ```

---

### [INC-607] Flight Gateway Returns 502 Bad Gateway — Nginx Upstream Port Mismatch
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Flight Gateway returns HTTP 502 Bad Gateway on /api/radar. Upstream telemetry-api unreachable.`
* **Symptoms:**
  `telemetry-api` pods are `1/1 Ready`. But accessing `/api/radar` through `flight-gateway` returns `502 Bad Gateway`. Nginx error logs report `Connection refused` while connecting to upstream `http://telemetry-api:80/`. The Service exposes port 8080.
* **Verification:**
  * Gateway successfully proxies radar telemetry with HTTP 200:
    ```bash
    kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar
    ```

---

### [INC-608] Flight Gateway High Availability Warning — 3rd Replica Pending
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Deployment aero-prod/flight-gateway desired replicas: 3, available: 2. One pod stuck in Pending.`
* **Symptoms:**
  Two `flight-gateway` replicas run on web nodes, but the 3rd replica remains `Pending` due to strict hard anti-affinity rules on a 2-web-node cluster topology.
* **Verification:**
  * `kubectl get deployment flight-gateway -n aero-prod` reports `READY 3/3`, `AVAILABLE 3`, with zero pending pods:
    ```bash
    kubectl get deployment flight-gateway -n aero-prod
    kubectl get pods -l app.kubernetes.io/name=flight-gateway -n aero-prod -o wide
    ```

---

## 🏁 Full Flight Radar Platform Verification Methodology

Execute these standard SRE verification commands across existing workloads to confirm complete platform recovery:

```bash
# 1. Database & Persistence Health
kubectl get pod radar-db-0 -n aero-prod -o wide
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry

# 2. Services, Endpoints, and Port Reachability
kubectl get svc,endpoints -n aero-prod
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379

# 3. Microservice Readiness Checks
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# 4. Gateway Proxy & End-to-End Flight Tracking Data
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar

# 5. External Port-Forward Access Simulation
kubectl port-forward svc/flight-gateway -n aero-prod 8080:80 &
PF_PID=$!
sleep 2
curl -s http://localhost:8080/health
curl -s http://localhost:8080/api/radar
kill $PF_PID
```

---
---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# 🚨 SRE Incident Lab 6: AeroOps Uçuş Radar & Servis Ağı Triage Labı

Bu çalışma alanı, gerçek zamanlı uçuş telemetrisi, transponder takibi ve hava trafik kontrol dağıtım ağı olan **AeroOps Global**'in canlıya geçişi sırasında yaşanan kesintiye yönelik aktif Acil Müdahale Odasıdır (War Room).

Kümeye uygulanan tüm manifestolar **sözdizimsel (schema) olarak kusursuzdur** ve Kubernetes API sunucusu tarafından hiçbir hata verilmeden kabul edilmiştir. Ancak veritabanı toleration hatası, Headless Service DNS uyumsuzluğu, önbellek port eşleme hatası, konteyner probe hataları, ConfigMap port yanlışlığı, Service selector etiket sürüklenmesi, ters proxy port çelişkisi ve katı pod anti-affinity kilitlenmesi platformu tamamen çalışamaz hale getirmiştir.

> 📖 **Post-Mortem & Kapsamlı Kök Neden Analizleri (RCA):**  
> 👉 **[Kıdemli SRE Çözüm ve İnceleme Rehberini İnceleyin (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Küme Topolojisi ve Altyapı Kısıtları

Olay müdahale senaryosu doğrudan aşağıdaki 3-node küme yapısına dayanmaktadır:

| Node Adı | IP | Label | Kısıt / Taint | Tahsis Edilen Rol |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *Yok* | Web / API / Gateway İş Yükleri |
| **Node-2** | `10.0.10.208` | `tier=web` | *Yok* | Web / API / Gateway İş Yükleri |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Yalnızca Veritabanı İş Yükleri (İzole) |

* **Hedef Namespace:** `aero-prod`
* **Ağ Katmanı:** OCI VCN-Native Pod Networking, kube-proxy, CoreDNS.

---

## 🚀 Ortamın Başlatılması (Hatalı Platformun Dağıtımı)

Hatalı manifestoları kümeye uygulayın:

```bash
kubectl apply -f manifests/
```

Başlangıç durumunu gözlemleyin:
```bash
kubectl get pods,svc,endpointslices -n aero-prod -o wide
```

---

## 📋 Nöbetçi SRE Olay Müdahale Panosu

Biletleri sırasıyla teşhis ve tamir edin:

---

### [INC-601] Radar Veritabanı Podu Pending Durumunda — Toleration Uyuşmazlığı
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] StatefulSet aero-prod/radar-db podu radar-db-0 hiçbir node üzerinde planlanamıyor. Pod Pending durumunda takılı kaldı.`
* **Belirtiler:**
  `radar-db-0` podu hiçbir node'a bağlanamaz. Pod olayları `0/3 nodes are available: 1 node has untolerated taint, 2 nodes didn't match Pod's node affinity/selector` hatası vermektedir.
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl get pod radar-db-0 -n aero-prod -o wide` çıktısı podun `10.0.10.78` (`Node-3`) üzerinde `1/1 Running` olduğunu göstermelidir.
  * Veritabanı port 5432 üzerinden bağlantıları kabul etmelidir:
    ```bash
    kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry
    ```

---

### [INC-602] Veritabanı Çalışıyor Ancak Servis Üzerinden Erişilemiyor — DNS NXDOMAIN & Boş Endpoints
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] Service aero-prod/radar-db servisinin 0 aktif endpoint'i var. radar-db-0.radar-db DNS sorguları NXDOMAIN dönüyor.`
* **Belirtiler:**
  `radar-db-0` Node-3 üzerinde `1/1 Running` durumundadır. Ancak diğer mikroservisler `radar-db-0.radar-db.aero-prod.svc.cluster.local` adresini çözümleyemez ve servisin endpoint listesi boştur (`Endpoints: <none>`).
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl get endpoints radar-db -n aero-prod` çıktısı `10.0.10.78:5432` değerini göstermelidir.
  * Cache podu üzerinden yapılan TCP port kontrolü başarılı olmalıdır:
    ```bash
    kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
    ```

---

### [INC-603] Uçuş İzleme Önbelleği TCP Bağlantısını Reddediyor — Connection Refused
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] aero-prod/track-cache servisi, Redis podu sağlıklı çalıştığı halde port 6379 üzerinden TCP bağlantılarını reddediyor.`
* **Belirtiler:**
  `track-cache` (Redis) podu `1/1 Running` durumundadır ve 6379 portunu dinlemektedir. Servisin endpoint'leri vardır. Ancak `track-cache:6379` adresine giden TCP bağlantıları `Connection refused` hatası almaktadır.
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl describe svc track-cache -n aero-prod` port eşlemesinin çalışan Redis portuna yönlendiğini doğrulamalıdır.
  * Veritabanı podundan önbelleğe atılan TCP ping başarılı olmalıdır:
    ```bash
    kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379
    ```

---

### [INC-604] Telemetry API Konteynerleri CrashLoopBackOff — Probe Connection Refused
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] aero-prod/telemetry-api Deployment konteynerleri sürekli yeniden başlıyor. Sağlık probları connection refused ile başarısız oluyor.`
* **Belirtiler:**
  `telemetry-api` başlar ve `Listening on 0.0.0.0:8080` logunu basar. Fakat Kubelet sağlık probu hatası alarak (`connection refused`), podu `0/1 NotReady` tutar ve konteyneri her 30 saniyede bir öldürür.
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod` çıktısında yeniden başlama (restart) sayısı sıfırda sabitlenmelidir.
  * Dahili sağlık probu `HTTP 200` dönmelidir:
    ```bash
    kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
    ```

---

### [INC-605] Telemetry API Podları Çalışıyor Ancak 0/1 Ready — ConfigMap Veritabanı Port Hatası
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] aero-prod/telemetry-api podları çalışıyor ancak 0/1 Ready. /ready uç noktası HTTP 503 dönüyor.`
* **Belirtiler:**
  API podlarının çökmesi durur ve `Running` kalır, fakat `0/1 NotReady` görünür. `/ready` kontrolü HTTP 503 dönerek Redis bağlı olduğu halde uygulamanın 5432 yerine 5433 portuna bağlanmaya çalıştığını gösterir.
* **Doğrulama (Çözüm Kontrolü):**
  * `/ready` kontrolü `"ready": true` ile HTTP 200 dönmelidir:
    ```bash
    kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready
    ```
  * API podları `1/1 Ready` durumuna ulaşmalıdır.

---

### [INC-606] Telemetry API Servisinin Endpoint'leri Boş — Selector Etiket Sürüklenmesi
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] aero-prod/telemetry-api servisinin 0 aktif endpoint'i var. Gateway trafiği yönlendirilemiyor.`
* **Belirtiler:**
  Her iki `telemetry-api` podu da `1/1 Ready` durumundadır. Ancak `kubectl get endpoints telemetry-api` çıktısı `<none>` döner ve `telemetry-api:8080` adresine giden istekler kaybolur.
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl get endpoints telemetry-api -n aero-prod` çıktısı port 8080 üzerinde 2 aktif pod IP'si göstermelidir.
  * Gateway podu üzerinden yapılan port kontrolü başarılı olmalıdır:
    ```bash
    kubectl exec -n aero-prod deploy/flight-gateway -- nc -zv telemetry-api 8080
    ```

---

### [INC-607] Flight Gateway 502 Bad Gateway Dönüyor — Nginx Upstream Port Uyuşmazlığı
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] Flight Gateway /api/radar üzerinde HTTP 502 Bad Gateway dönüyor. Upstream telemetry-api erişilemez.`
* **Belirtiler:**
  `telemetry-api` podları `1/1 Ready` durumundadır. Fakat `flight-gateway` üzerinden `/api/radar` istendiğinde `502 Bad Gateway` alınır. Nginx logları `http://telemetry-api:80/` hedefine bağlanırken `Connection refused` hatası bildirmektedir. Servis ise 8080 portunu açmaktadır.
* **Doğrulama (Çözüm Kontrolü):**
  * Gateway, radar telemetrisini `HTTP 200` ile başarıyla iletmelidir:
    ```bash
    kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar
    ```

---

### [INC-608] Flight Gateway Yüksek Erişilebilirlik Uyarısı — 3. Pod Pending Durumunda
* **Öncelik:** `P2 - High`
* **Uyarı:**
  > `[WARNING] aero-prod/flight-gateway istenen kopya: 3, çalışan: 2. Bir pod Pending durumunda takılı kaldı.`
* **Belirtiler:**
  İki `flight-gateway` podu web node'larında çalışır, fakat 3. pod 2 web node'lu bir kümede katı (required) pod anti-affinity kuralı nedeniyle `Pending` kalır.
* **Doğrulama (Çözüm Kontrolü):**
  * `kubectl get deployment flight-gateway -n aero-prod` çıktısı `READY 3/3`, `AVAILABLE 3` olarak sıfır bekleyen pod bildirmelidir:
    ```bash
    kubectl get deployment flight-gateway -n aero-prod
    kubectl get pods -l app.kubernetes.io/name=flight-gateway -n aero-prod -o wide
    ```

---

## 🏁 Uçtan Uca Uçuş Radar Platformu Doğrulama Metodolojisi

Mevcut podlar üzerinden tüm platformun kurtarıldığını doğrulamak için şu standart SRE komutlarını çalıştırın:

```bash
# 1. Veritabanı ve Kalıcılık Durumu
kubectl get pod radar-db-0 -n aero-prod -o wide
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry

# 2. Servisler, Endpoint'ler ve Port Erişilebilirliği
kubectl get svc,endpoints -n aero-prod
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379

# 3. Mikroservis Hazırlık Durumu Kontrolleri
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# 4. Gateway Proxy ve Uçtan Uca Radar Verisi
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar

# 5. Harici Port-Forward Erişim Testi
kubectl port-forward svc/flight-gateway -n aero-prod 8080:80 &
PF_PID=$!
sleep 2
curl -s http://localhost:8080/health
curl -s http://localhost:8080/api/radar
kill $PF_PID
```
