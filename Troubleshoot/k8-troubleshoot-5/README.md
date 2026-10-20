# 🚨 SRE Incident Lab 5: ApexPay Core Banking & Service Mesh Triage

This workspace serves as the active Incident Triage War Room during the production go-live failure of **ApexPay Global**, a mission-critical real-time payment settlement and fraud detection engine.

All manifests deployed to the cluster were **schema-compliant** and accepted without syntax errors by the Kubernetes API server. However, severe service discovery failures, port mapping mismatches (`port` vs `targetPort`), transport protocol discrepancies, and NodePort routing misconfigurations have caused a cascading outage across the payment mesh.

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

* **Target Namespace:** `apex-pay`
* **Networking Plane:** OCI VCN-Native Pod Networking, kube-proxy, CoreDNS.

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all broken manifests to the cluster:

```bash
kubectl apply -f manifests/
```

Watch initial status:
```bash
kubectl get pods,svc,endpointslices -n apex-pay -o wide
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the tickets sequentially:

---

### [INC-501] Database Running but Unreachable via Service — DNS NXDOMAIN & Empty Endpoints
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] StatefulSet apex-pay/ledger-db pod ledger-db-0 cannot be resolved by internal microservices. CoreDNS queries for ledger-db-0.ledger-db return NXDOMAIN.`
* **Symptoms:**
  `ledger-db-0` pod is scheduled on `Node-3` (`10.0.10.78`) and is `1/1 Running`. However, downstream microservices cannot resolve `ledger-db-0.ledger-db.apex-pay.svc.cluster.local`, and the database service has no active endpoints (`Endpoints: <none>`).
* **Verification:**
  * Database service has an active endpoint pointing to `10.0.10.78:5432`:
    ```bash
    kubectl get endpoints ledger-db -n apex-pay
    ```
  * CoreDNS resolves the deterministic StatefulSet pod DNS record:
    ```bash
    kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local
    ```
  * Direct PostgreSQL connection check succeeds:
    ```bash
    kubectl run pg-check --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
    ```

---

### [INC-502] Fraud Engine Running but Service Has No Backends — Endpoints Empty (<none>)
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service apex-pay/fraud-engine-svc has 0 active endpoints. Downstream transaction evaluation is halted.`
* **Symptoms:**
  Both `fraud-engine` deployment pods are `1/1 Running` on worker nodes. However, `fraud-engine-svc` shows `Endpoints: <none>`, and requests to `http://fraud-engine-svc:8080/` fail to route.
* **Verification:**
  * `fraud-engine-svc` shows 2 active pod endpoints:
    ```bash
    kubectl get endpoints fraud-engine-svc -n apex-pay
    kubectl get endpointslices -l kubernetes.io/service-name=fraud-engine-svc -n apex-pay
    ```
  * Service accepts HTTP traffic and returns inspection status:
    ```bash
    kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://fraud-engine-svc:8080/
    ```

---

### [INC-503] Payment Processor Service Refuses Connections — TCP Connection Refused
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] Service apex-pay/payment-processor-svc refuses TCP connections on port 80 despite pods running healthy.`
* **Symptoms:**
  `payment-processor` pods are `1/1 Running`, and the Service has active endpoints. However, any connection to `payment-processor-svc:80` is instantly rejected with `Connection refused` (TCP RST).
* **Verification:**
  * `payment-processor-svc` port mapping correctly forwards to the active application port:
    ```bash
    kubectl describe svc payment-processor-svc -n apex-pay
    ```
  * HTTP request to port 80 succeeds with HTTP 200:
    ```bash
    kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s -I http://payment-processor-svc:80/
    ```

---

### [INC-504] Notification Broker Event Stream Unreachable — Connection Timed Out
* **Priority:** `P2 - High`
* **Alert:**
  > `[WARNING] Connection to apex-pay/notification-broker-svc:9000 hangs and times out while metrics port 9090 is accessible.`
* **Symptoms:**
  The `notification-broker` application is running and its metrics on port 9090 are operational. However, TCP event stream connections sent to `notification-broker-svc:9000` hang and fail with `timed out`.
* **Verification:**
  * TCP connection to port 9000 succeeds within 1 second:
    ```bash
    kubectl run nc-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000
    ```
  * Metrics port 9090 continues to return Prometheus telemetry:
    ```bash
    kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
    ```

---

### [INC-505] Merchant Gateway NodePort Intermittent Blackhole — Node-2 Times Out
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] External payment gateway on NodePort 30080 is failing intermittently. Requests to Node-2 (10.0.10.208:30080) hang indefinitely.`
* **Symptoms:**
  Connecting to `10.0.10.122:30080` (Node-1) returns `HTTP 200 OK`. However, connecting to `10.0.10.208:30080` (Node-2) times out, causing external load balancers to drop traffic routed to Node-2.
* **Verification:**
  * NodePort 30080 returns `HTTP 200 OK` on **both** Node-1 and Node-2:
    ```bash
    kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/
    kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
    ```

---

## 🏁 Full ApexPay Service Mesh Verification Methodology

Execute this full validation script inside the cluster to confirm 100% operational readiness:

```bash
kubectl run mesh-verifier --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- sh -c '
echo "=== 1. Checking Merchant Gateway Health ==="
curl -s http://merchant-gateway-np:80/health

echo -e "\n=== 2. Checking Payment Processor via Gateway ==="
curl -s http://merchant-gateway-np:80/api/payment/

echo -e "\n=== 3. Checking Fraud Engine via Gateway ==="
curl -s http://merchant-gateway-np:80/api/fraud/

echo -e "\n=== 4. Checking Direct Payment Processor Service ==="
curl -s http://payment-processor-svc:80/

echo -e "\n=== 5. Checking Fraud Engine Service ==="
curl -s http://fraud-engine-svc:8080/

echo -e "\n=== 6. Checking Notification Broker Metrics ==="
curl -s http://notification-broker-svc:9090/
'
```

---
---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# 🚨 SRE Incident Lab 5: ApexPay Çekirdek Bankacılık & Servis Ağı Triage Labı

Bu çalışma alanı, gerçek zamanlı ödeme takas ve sahtekarlık tespit platformu olan **ApexPay Global**'in canlıya geçişi sırasında yaşanan kesintiye yönelik aktif Acil Müdahale Odasıdır (War Room).

Kümeye uygulanan tüm manifestolar **sözdizimsel (schema) olarak kusursuzdur** ve Kubernetes API sunucusu tarafından hiçbir hata verilmeden kabul edilmiştir. Ancak servis keşif hataları, port eşleme uyuşmazlıkları (`port` vs `targetPort`), taşıma protokolü çelişkileri ve NodePort yönlendirme hataları nedeniyle tüm ödeme ağı çökmüştür.

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

* **Hedef Namespace:** `apex-pay`
* **Ağ Katmanı:** OCI VCN-Native Pod Networking, kube-proxy, CoreDNS.

---

## 🚀 Ortamın Başlatılması (Hatalı Platformun Dağıtımı)

Hatalı manifestoları kümeye uygulayın:

```bash
kubectl apply -f manifests/
```

Başlangıç durumunu gözlemleyin:
```bash
kubectl get pods,svc,endpointslices -n apex-pay -o wide
```

---

## 📋 Nöbetçi SRE Olay Müdahale Panosu

Biletleri sırasıyla teşhis ve tamir edin:

---

### [INC-501] Veritabanı Çalışıyor Ancak Servis Üzerinden Erişilemiyor — DNS NXDOMAIN & Boş Endpoints
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] StatefulSet apex-pay/ledger-db podu ledger-db-0 diğer mikroservisler tarafından çözümlenemiyor. ledger-db-0.ledger-db için CoreDNS sorguları NXDOMAIN dönüyor.`
* **Belirtiler:**
  `ledger-db-0` podu `Node-3` (`10.0.10.78`) üzerinde başarıyla planlanmış ve `1/1 Running` durumundadır. Ancak diğer mikroservisler `ledger-db-0.ledger-db.apex-pay.svc.cluster.local` adresini çözümleyemez ve veritabanı servisinin hiç aktif endpoint'i yoktur (`Endpoints: <none>`).
* **Doğrulama (Çözüm Kontrolü):**
  * Veritabanı servisi `10.0.10.78:5432` hedefine işaret eden aktif bir endpoint'e sahip olmalıdır:
    ```bash
    kubectl get endpoints ledger-db -n apex-pay
    ```
  * CoreDNS, StatefulSet pod DNS kaydını başarıyla çözmelidir:
    ```bash
    kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local
    ```
  * Doğrudan PostgreSQL bağlantı kontrolü başarılı olmalıdır:
    ```bash
    kubectl run pg-check --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
    ```

---

### [INC-502] Fraud Engine Podları Çalışıyor Ancak Servisin Arkasında Pod Yok — Endpoints Boş (<none>)
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] apex-pay/fraud-engine-svc servisinin 0 aktif endpoint'i var. Ödeme akışı durduruldu.`
* **Belirtiler:**
  Her iki `fraud-engine` podu da worker node'lar üzerinde `1/1 Running` durumundadır. Ancak `fraud-engine-svc` servisi `Endpoints: <none>` olarak görünür ve `http://fraud-engine-svc:8080/` adresine giden istekler yönlendirilemez.
* **Doğrulama (Çözüm Kontrolü):**
  * `fraud-engine-svc` servisi 2 aktif pod endpoint'ine sahip olmalıdır:
    ```bash
    kubectl get endpoints fraud-engine-svc -n apex-pay
    kubectl get endpointslices -l kubernetes.io/service-name=fraud-engine-svc -n apex-pay
    ```
  * Servis HTTP trafiğini kabul etmeli ve analiz durumunu dönmelidir:
    ```bash
    kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://fraud-engine-svc:8080/
    ```

---

### [INC-503] Payment Processor Servisi Bağlantıyı Reddediyor — TCP Connection Refused
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] apex-pay/payment-processor-svc servisi, podlar sağlıklı çalıştığı halde port 80 üzerinden gelen TCP bağlantılarını reddediyor.`
* **Belirtiler:**
  `payment-processor` podları `1/1 Running` durumundadır ve servisin aktif endpoint'leri mevcuttur. Ancak `payment-processor-svc:80` adresine bağlanan herhangi bir istemci anında `Connection refused` (TCP RST) hatası alır.
* **Doğrulama (Çözüm Kontrolü):**
  * `payment-processor-svc` port eşlemesi konteynerin dinlediği gerçek portu doğru şekilde göstermelidir:
    ```bash
    kubectl describe svc payment-processor-svc -n apex-pay
    ```
  * Port 80'e atılan HTTP isteği `HTTP 200` ile başarılı dönmelidir:
    ```bash
    kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s -I http://payment-processor-svc:80/
    ```

---

### [INC-504] Notification Broker Olay Akışına Erişilemiyor — Connection Timed Out
* **Öncelik:** `P2 - High`
* **Uyarı:**
  > `[WARNING] apex-pay/notification-broker-svc:9000 bağlantısı askıda kalıp zaman aşımına uğrarken, 9090 metrik portuna erişilebiliyor.`
* **Belirtiler:**
  `notification-broker` uygulaması çalışmaktadır ve 9090 portundaki metrikler toplanabilmektedir. Ancak `notification-broker-svc:9000` adresine gönderilen TCP olay akışı bağlantıları askıda kalır ve `timed out` ile düşer.
* **Doğrulama (Çözüm Kontrolü):**
  * Port 9000'e TCP bağlantısı 1 saniye içinde başarıyla kurulmalıdır:
    ```bash
    kubectl run nc-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000
    ```
  * Metrik portu 9090 Prometheus telemetrisini dönmeye devam etmelidir:
    ```bash
    kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
    ```

---

### [INC-505] Merchant Gateway NodePort Kara Deliği — Node-2 Üzerinden Zaman Aşımı
* **Öncelik:** `P1 - Blocker`
* **Uyarı:**
  > `[CRITICAL] NodePort 30080 harici ödeme ağ geçidi aralıklı olarak istekleri düşürüyor. Node-2'ye (10.0.10.208:30080) giden istekler askıda kalıyor.`
* **Belirtiler:**
  `10.0.10.122:30080` (Node-1) bağlantısı `HTTP 200 OK` dönerken, `10.0.10.208:30080` (Node-2) bağlantısı zaman aşımına uğramakta ve dış yük dengeleyicinin trafiği kaybetmesine yol açmaktadır.
* **Doğrulama (Çözüm Kontrolü):**
  * NodePort 30080 portu **HEM** Node-1 **HEM DE** Node-2 üzerinden `HTTP 200 OK` dönmelidir:
    ```bash
    kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/
    kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
    ```

---

## 🏁 Uçtan Uca ApexPay Servis Ağı Doğrulama Metodolojisi

Tüm platformun %100 sağlıklı olduğunu tek seferde doğrulamak için şu betiği küme içinde çalıştırın:

```bash
kubectl run mesh-verifier --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- sh -c '
echo "=== 1. Merchant Gateway Sağlık Kontrolü ==="
curl -s http://merchant-gateway-np:80/health

echo -e "\n=== 2. Gateway Üzerinden Payment Processor Kontrolü ==="
curl -s http://merchant-gateway-np:80/api/payment/

echo -e "\n=== 3. Gateway Üzerinden Fraud Engine Kontrolü ==="
curl -s http://merchant-gateway-np:80/api/fraud/

echo -e "\n=== 4. Doğrudan Payment Processor Servis Kontrolü ==="
curl -s http://payment-processor-svc:80/

echo -e "\n=== 5. Doğrudan Fraud Engine Servis Kontrolü ==="
curl -s http://fraud-engine-svc:8080/

echo -e "\n=== 6. Notification Broker Metrik Kontrolü ==="
curl -s http://notification-broker-svc:9090/
'
```
