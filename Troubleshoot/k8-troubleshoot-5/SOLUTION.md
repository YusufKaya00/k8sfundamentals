# 🛠️ SRE Incident Remediation Guide & Post-Mortem: Lab 5 (ApexPay)

This guide documents the root cause analyses (RCA), architectural remediation steps, and verification procedures for **Incident Lab 5 (ApexPay Global Banking & Mesh Outage)**.

---

## 📑 Incident Executive Summary

| Ticket ID | Impacted Component | Root Cause | Fix Strategy | Severity |
| :--- | :--- | :--- | :--- | :--- |
| **[INC-501]** | `ledger-db` (StatefulSet / Headless) | Service name mismatch (`ledger-service` vs `serviceName: "ledger-db"`) & selector mismatch (`tier: backend` vs `database`). | Rename Service to `ledger-db` and align selector to `tier: database`. | `P1 - Blocker` |
| **[INC-502]** | `fraud-engine-svc` (ClusterIP) | Over-specified label `environment: production` in Service selector not present on Deployment pods. | Remove `environment: production` from Service selector. | `P1 - Blocker` |
| **[INC-503]** | `payment-processor-svc` (ClusterIP) | TargetPort mismatch (`targetPort: 80` while container listens on port `8080`). | Change `targetPort` to `8080` (or `http-api`). | `P1 - Blocker` |
| **[INC-504]** | `notification-broker-svc` (Multi-Port) | Transport protocol declared as `UDP` on event port 9000 instead of `TCP`. | Change protocol to `TCP` in Service port definition. | `P2 - High` |
| **[INC-505]** | `merchant-gateway-np` (NodePort) | `externalTrafficPolicy: Local` drops packets on Node-2 because the single pod replica lives only on Node-1. | Set `externalTrafficPolicy: Cluster` OR scale to 2 replicas across both web nodes. | `P1 - Blocker` |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-501] Remediation: Headless Service DNS Resolution Failure

#### 1. Root Cause Analysis (RCA)
Kubernetes assigns stable, deterministic A/AAAA records to individual StatefulSet pods in the format:
`<pod-name>.<service-name>.<namespace>.svc.cluster.local`

For CoreDNS to synthesize this record:
1. A Service with `clusterIP: None` (Headless) must exist.
2. The `metadata.name` of this service must match **verbatim** the StatefulSet's `spec.serviceName`.
3. In `manifests/20-database.yaml`, the Service was named `ledger-service`, but the StatefulSet specified `serviceName: "ledger-db"`.
4. Furthermore, the Service selector specified `tier: backend`, whereas the pod template carried `tier: database`. As a result, the Service had zero endpoints, and CoreDNS rejected queries with `NXDOMAIN`.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ledger-db # Fixed: Matches StatefulSet spec.serviceName
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: ledger-db
    app.kubernetes.io/part-of: apex-pay
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: ledger-db
    tier: database # Fixed: Aligned with Pod template label
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
```

#### 3. Execution Commands
```bash
# Delete the old mismatched service and recreate with correct name and selector
kubectl delete svc ledger-service -n apex-pay --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ledger-db
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: ledger-db
    app.kubernetes.io/part-of: apex-pay
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: ledger-db
    tier: database
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
EOF
```

#### 4. Verification Commands
```bash
# Verify Endpoints are populated
kubectl get endpoints ledger-db -n apex-pay

# Test DNS resolution for individual StatefulSet pod
kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local

# Test database connection from another pod
kubectl run pg-ping --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
```

---

### [INC-502] Remediation: Fraud Engine Endpoints Missing

#### 1. Root Cause Analysis (RCA)
In `manifests/30-fraud-engine.yaml`, the Service selector contained:
```yaml
selector:
  app.kubernetes.io/name: fraud-engine
  component: inspector
  environment: production # <-- Phantom label!
```
The Deployment pods only carried:
```yaml
labels:
  app.kubernetes.io/name: fraud-engine
  app.kubernetes.io/part-of: apex-pay
  component: inspector
```
Because the Endpoint controller evaluates selectors with strict boolean **AND**, the absence of `environment: production` on the pods resulted in an empty EndpointSlice (`Endpoints: <none>`). Kube-proxy created no forwarding rules, causing incoming requests to blackhole.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: Service
metadata:
  name: fraud-engine-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: fraud-engine
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: fraud-engine
    component: inspector # Fixed: Removed 'environment: production'
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fraud-engine-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: fraud-engine
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: fraud-engine
    component: inspector
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
EOF
```

#### 4. Verification Commands
```bash
# Verify both pod IPs are attached as endpoints
kubectl get endpoints fraud-engine-svc -n apex-pay
kubectl get endpointslices -n apex-pay -l kubernetes.io/service-name=fraud-engine-svc

# Test HTTP request to Service
kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://fraud-engine-svc:8080/
```

---

### [INC-503] Remediation: Payment Processor Port vs TargetPort Mismatch

#### 1. Root Cause Analysis (RCA)
In `manifests/40-payment-api.yaml`:
```yaml
ports:
- name: http
  port: 80
  targetPort: 80 # <-- BUG: Container listens on 8080!
```
Kube-proxy forwards packets destined for `ClusterIP:80` to `<PodIP>:80`. However, the Python application inside the pod network namespace listens on `0.0.0.0:8080`. When a TCP SYN packet hits port 80, the Linux kernel finds no listening socket and immediately responds with a TCP RST (Reset) packet, producing `Connection refused`.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-processor-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payment-processor
  ports:
  - name: http
    port: 80
    targetPort: 8080 # Fixed: Correctly maps to container listening port
    protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: payment-processor-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payment-processor
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
EOF
```

#### 4. Verification Commands
```bash
# Test connection to port 80
kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://payment-processor-svc:80/
```

---

### [INC-504] Remediation: Notification Broker Multi-Port Protocol Mismatch

#### 1. Root Cause Analysis (RCA)
In `manifests/50-notification-broker.yaml`:
```yaml
ports:
- name: metrics
  port: 9090
  targetPort: 9090
  protocol: TCP
- name: events
  port: 9000
  targetPort: 9000
  protocol: UDP # <-- BUG: Application uses TCP!
```
The broker listens for TCP stream connections on port 9000. Because the Service declared port 9000 as `UDP`, kube-proxy only configured UDP packet filtering rules. TCP SYN packets sent to port 9000 failed to match any iptables rule and were dropped, causing connection timeouts.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: Service
metadata:
  name: notification-broker-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: notification-broker
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: notification-broker
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  - name: events
    port: 9000
    targetPort: 9000
    protocol: TCP # Fixed: Changed from UDP to TCP
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: notification-broker-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: notification-broker
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: notification-broker
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  - name: events
    port: 9000
    targetPort: 9000
    protocol: TCP
EOF
```

#### 4. Verification Commands
```bash
# Test TCP stream socket on event port 9000
kubectl run nc-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000

# Test metrics endpoint on port 9090
kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
```

---

### [INC-505] Remediation: Merchant Gateway NodePort External Blackhole

#### 1. Root Cause Analysis (RCA)
In `manifests/60-merchant-gateway.yaml`:
```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
```
* **The `externalTrafficPolicy: Local` Contract:**
  When `externalTrafficPolicy` is set to `Local`, kube-proxy routes external traffic arriving on a node's NodePort **only to local pods running on that exact node**. This preserves the original client IP address and avoids an unnecessary inter-node hop. However, if a node has **no pod replica**, kube-proxy drops incoming packets on that node!
* **The Failure:**
  The `merchant-gateway` deployment only had 1 replica, scheduled exclusively on `Node-1` (`10.0.10.122`). Any traffic or health check directed to `Node-2:30080` (`10.0.10.208:30080`) was blackholed.

#### 2. Corrected Manifest Patch
Two valid production remediation patterns exist:
* **Option A (Cluster-wide routing):** Change `externalTrafficPolicy: Cluster`. Kube-proxy on Node-2 will forward packets to Node-1 (at the cost of SNAT).
* **Option B (Preserve Client IP & High Availability - Recommended):** Keep `externalTrafficPolicy: Local` AND scale `replicas: 2` with pod anti-affinity so that **both** web nodes run a local gateway instance!

Let's apply Option B (or update policy to `Cluster` if 1 replica is desired):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: merchant-gateway-np
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  type: NodePort
  externalTrafficPolicy: Cluster # Fixed: Cluster-wide cross-node load balancing
  selector:
    app.kubernetes.io/name: merchant-gateway
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: 30080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: merchant-gateway
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  replicas: 2 # Scale to 2 replicas
  selector:
    matchLabels:
      app.kubernetes.io/name: merchant-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: merchant-gateway
        app.kubernetes.io/part-of: apex-pay
    spec:
      nodeSelector:
        tier: web # Target all web nodes (Node-1 and Node-2)
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values: ["merchant-gateway"]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-conf
        configMap:
          name: gateway-nginx-conf
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: merchant-gateway-np
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/name: merchant-gateway
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: 30080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: merchant-gateway
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: merchant-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: merchant-gateway
        app.kubernetes.io/part-of: apex-pay
    spec:
      nodeSelector:
        tier: web
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-conf
        configMap:
          name: gateway-nginx-conf
EOF
```

#### 4. Verification Commands
```bash
# Verify pods are distributed across Node-1 and Node-2
kubectl get pods -n apex-pay -l app.kubernetes.io/name=merchant-gateway -o wide

# Test NodePort on Node-1 (10.0.10.122) -> HTTP 200 OK
kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/

# Test NodePort on Node-2 (10.0.10.208) -> HTTP 200 OK
kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
```

---

## 🔬 End-to-End Mesh Health Verification

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

# 🛠️ SRE Olay Müdahale ve Çözüm Rehberi: Lab 5 (ApexPay)

Bu doküman, **Incident Lab 5 (ApexPay Global Bankacılık & Servis Ağı Kesintisi)** için kök neden analizlerini (RCA), mimari düzeltme adımlarını ve doğrulama yönergelerini içermektedir.

---

## 📑 Olay Özeti (Executive Summary)

| Bilet No | Etkilenen Bileşen | Kök Neden (RCA) | Çözüm Stratejisi | Önem Derecesi |
| :--- | :--- | :--- | :--- | :--- |
| **[INC-501]** | `ledger-db` (StatefulSet / Headless) | Servis ismi uyumsuzluğu (`ledger-service` vs `serviceName: "ledger-db"`) ve selector etiketi hatası (`tier: backend` vs `database`). | Servis adını `ledger-db` yapın ve selector'ı `tier: database` olarak düzeltin. | `P1 - Blocker` |
| **[INC-502]** | `fraud-engine-svc` (ClusterIP) | Servis selector'ında tanımlı `environment: production` etiketinin pod template'inde bulunmaması. | Servis selector'ından `environment: production` etiketini kaldırın. | `P1 - Blocker` |
| **[INC-503]** | `payment-processor-svc` (ClusterIP) | TargetPort uyumsuzluğu (`targetPort: 80` ancak konteyner 8080 portunu dinliyor). | Servisin `targetPort` değerini `8080` (veya `http-api`) olarak güncelleyin. | `P1 - Blocker` |
| **[INC-504]** | `notification-broker-svc` (Multi-Port) | 9000 portu için protokolün yanlışlıkla `TCP` yerine `UDP` tanımlanması. | Servis port tanımındaki protokolü `TCP` olarak düzeltin. | `P2 - High` |
| **[INC-505]** | `merchant-gateway-np` (NodePort) | `externalTrafficPolicy: Local` ayarı nedeniyle Node-2'ye gelen isteklerin yerel pod olmaması sebebiyle düşürülmesi. | `externalTrafficPolicy: Cluster` yapın VEYA gateway podunu 2 kopyaya çıkararak her iki web node'una dağıtın. | `P1 - Blocker` |

---

## 🔧 Adım Adım Olay Çözüm Rehberi

---

### [INC-501] Çözüm: Headless Service DNS Çözümleme Hatası

#### 1. Kök Neden Analizi (RCA)
Kubernetes, StatefulSet podlarına şu formatta kararlı ve deterministik DNS kayıtları atar:
`<pod-adı>.<servis-adı>.<namespace>.svc.cluster.local`

CoreDNS'in bu kaydı üretebilmesi için:
1. `clusterIP: None` (Headless) bir Service bulunmalıdır.
2. Bu servisin `metadata.name` değeri ile StatefulSet'in `spec.serviceName` değeri **birebir aynı olmalıdır**.
3. `manifests/20-database.yaml` dosyasında servis adı `ledger-service` iken StatefulSet içinde `serviceName: "ledger-db"` yazılmıştır.
4. Ayrıca servisin selector'ı `tier: backend` olarak belirtilmiş, oysa pod etiketinde `tier: database` yer almaktadır. Bu sebeple servisin hiç endpoint'i oluşmamış ve CoreDNS sorguları `NXDOMAIN` dönmüştür.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: Service
metadata:
  name: ledger-db # Düzeltildi: StatefulSet spec.serviceName ile eşitlendi
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: ledger-db
    app.kubernetes.io/part-of: apex-pay
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: ledger-db
    tier: database # Düzeltildi: Pod etiketiyle eşitlendi
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
```

#### 3. Uygulama Komutları
```bash
kubectl delete svc ledger-service -n apex-pay --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ledger-db
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: ledger-db
    app.kubernetes.io/part-of: apex-pay
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: ledger-db
    tier: database
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
EOF
```

#### 4. Doğrulama Komutları
```bash
# Endpoint'lerin bağlandığını doğrulayın
kubectl get endpoints ledger-db -n apex-pay

# StatefulSet pod DNS çözümlemesini test edin
kubectl run dns-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nslookup ledger-db-0.ledger-db.apex-pay.svc.cluster.local

# Veritabanı bağlantı testini çalıştırın
kubectl run pg-ping --rm -it --image=docker.io/library/postgres:16-alpine --restart=Never -n apex-pay -- pg_isready -h ledger-db -p 5432 -U apex_admin
```

---

### [INC-502] Çözüm: Fraud Engine Endpoints Kayıp

#### 1. Kök Neden Analizi (RCA)
`manifests/30-fraud-engine.yaml` dosyasında servis selector'ı şu şekilde tanımlanmıştı:
```yaml
selector:
  app.kubernetes.io/name: fraud-engine
  component: inspector
  environment: production # <-- Pod üzerinde olmayan hayali etiket!
```
Deployment podları ise yalnızca şu etiketlere sahipti:
```yaml
labels:
  app.kubernetes.io/name: fraud-engine
  app.kubernetes.io/part-of: apex-pay
  component: inspector
```
Endpoint kontrolcüsü selector etiketlerini katı mantıksal **VE (AND)** sorgusuyla arar. Podlar üzerinde `environment: production` bulunmadığı için hiçbir pod servise bağlanamamış (`Endpoints: <none>`) ve kube-proxy herhangi bir yönlendirme kuralı oluşturmamıştır.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: Service
metadata:
  name: fraud-engine-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: fraud-engine
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: fraud-engine
    component: inspector # Düzeltildi: 'environment: production' kaldırıldı
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fraud-engine-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: fraud-engine
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: fraud-engine
    component: inspector
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
EOF
```

#### 4. Doğrulama Komutları
```bash
# Her iki pod IP'sinin de endpoint listesinde olduğunu doğrulayın
kubectl get endpoints fraud-engine-svc -n apex-pay
kubectl get endpointslices -n apex-pay -l kubernetes.io/service-name=fraud-engine-svc

# Servise HTTP isteği atarak yanıtı kontrol edin
kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://fraud-engine-svc:8080/
```

---

### [INC-503] Çözüm: Payment Processor Port / TargetPort Uyuşmazlığı

#### 1. Kök Neden Analizi (RCA)
`manifests/40-payment-api.yaml` dosyasında:
```yaml
ports:
- name: http
  port: 80
  targetPort: 80 # <-- HATA: Konteyner içindeki uygulama 8080 portunu dinliyor!
```
Kube-proxy, `ClusterIP:80` adresine gelen paketleri `<PodIP>:80` hedefine yönlendirir. Fakat pod içindeki Python sunucusu `0.0.0.0:8080` adresini dinlemektedir. Pod ağ arayüzüne port 80 üzerinden gelen TCP SYN paketi dinleyen bir socket bulamadığında Linux çekirdeği anında TCP RST (Reset) cevabı döner ve istemci `Connection refused` hatası alır.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-processor-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payment-processor
  ports:
  - name: http
    port: 80
    targetPort: 8080 # Düzeltildi: Uygulamanın dinlediği 8080 portuna bağlandı
    protocol: TCP
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: payment-processor-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: payment-processor
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: payment-processor
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
EOF
```

#### 4. Doğrulama Komutları
```bash
# Port 80 üzerinden servise bağlanmayı test edin
kubectl run curl-test --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://payment-processor-svc:80/
```

---

### [INC-504] Çözüm: Notification Broker Protokol Çelişkisi

#### 1. Kök Neden Analizi (RCA)
`manifests/50-notification-broker.yaml` dosyasında:
```yaml
ports:
- name: metrics
  port: 9090
  targetPort: 9090
  protocol: TCP
- name: events
  port: 9000
  targetPort: 9000
  protocol: UDP # <-- HATA: Uygulama TCP soketi dinliyor!
```
Broker uygulaması port 9000 üzerinde TCP soketi dinlemektedir. Servis tanımında protokol `UDP` olarak yazıldığı için kube-proxy yalnızca UDP paket kuralları üretmiştir. Port 9000'e gelen TCP SYN paketleri eşleşen kural bulamadığından sessizce düşürülmüş (drop) ve bağlantı zaman aşımına uğramıştır.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: Service
metadata:
  name: notification-broker-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: notification-broker
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: notification-broker
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  - name: events
    port: 9000
    targetPort: 9000
    protocol: TCP # Düzeltildi: UDP yerine TCP yapıldı
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: notification-broker-svc
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: notification-broker
    app.kubernetes.io/part-of: apex-pay
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: notification-broker
  ports:
  - name: metrics
    port: 9090
    targetPort: 9090
    protocol: TCP
  - name: events
    port: 9000
    targetPort: 9000
    protocol: TCP
EOF
```

#### 4. Doğrulama Komutları
```bash
# Olay portu 9000 üzerinde TCP soket erişimini doğrulayın
kubectl run nc-test --rm -it --image=docker.io/library/busybox:1.36 --restart=Never -n apex-pay -- nc -z -v -w 3 notification-broker-svc 9000

# Metrik portu 9090'ı test edin
kubectl run curl-metrics --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -s http://notification-broker-svc:9090/
```

---

### [INC-505] Çözüm: Merchant Gateway NodePort Kara Deliği

#### 1. Kök Neden Analizi (RCA)
`manifests/60-merchant-gateway.yaml` dosyasında:
```yaml
spec:
  type: NodePort
  externalTrafficPolicy: Local
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30080
```
* **`externalTrafficPolicy: Local` Davranışı:**
  Bu ayar seçildiğinde kube-proxy bir node'a gelen trafiği **yalnızca o node üzerinde yerel olarak koşan podlara** yönlendirir (orijinal istemci IP adresini saklamak ve node'lar arası ekstra sekmeyi önlemek için). Ancak ilgili node üzerinde çalışan bir pod kopyası yoksa, kube-proxy paketi diğer node'lara iletmez ve paketi doğrudan düşürür!
* **Kesintinin Sebebi:**
  `merchant-gateway` tek bir replica ile yalnızca `Node-1` (`10.0.10.122`) üzerinde koşuyordu. Bu sebeple `Node-2:30080` (`10.0.10.208:30080`) adresine gelen tüm istekler kara deliğe düşmekteydi.

#### 2. Düzeltilmiş Manifesto (Çözüm Stratejisi)
Üretim ortamlarında iki yöntem uygulanabilir:
* **Yöntem A (Küme genelinde yönlendirme):** `externalTrafficPolicy: Cluster` yapılır. Node-2'ye gelen paket kube-proxy tarafından Node-1'deki poda iletilir (SNAT uygulanır).
* **Yöntem B (İstemci IP'sini Koru & Yüksek Erişilebilirlik - Önerilen):** `externalTrafficPolicy: Cluster` ayarlanır ve deployment 2 kopyaya çıkarılarak web node'ları arasına dengeli şekilde dağıtılır.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: merchant-gateway-np
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  type: NodePort
  externalTrafficPolicy: Cluster # Düzeltildi: Tüm node'lardan küme geneli yük dengeleme
  selector:
    app.kubernetes.io/name: merchant-gateway
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: 30080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: merchant-gateway
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  replicas: 2 # 2 kopyaya çıkarıldı
  selector:
    matchLabels:
      app.kubernetes.io/name: merchant-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: merchant-gateway
        app.kubernetes.io/part-of: apex-pay
    spec:
      nodeSelector:
        tier: web # Her iki web node'una dağıt
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-conf
        configMap:
          name: gateway-nginx-conf
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: merchant-gateway-np
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  type: NodePort
  externalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/name: merchant-gateway
  ports:
  - name: http
    port: 80
    targetPort: 8080
    nodePort: 30080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: merchant-gateway
  namespace: apex-pay
  labels:
    app.kubernetes.io/name: merchant-gateway
    app.kubernetes.io/part-of: apex-pay
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: merchant-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: merchant-gateway
        app.kubernetes.io/part-of: apex-pay
    spec:
      nodeSelector:
        tier: web
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        volumeMounts:
        - name: nginx-conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: nginx-conf
        configMap:
          name: gateway-nginx-conf
EOF
```

#### 4. Doğrulama Komutları
```bash
# Podların Node-1 ve Node-2 üzerine dağıldığını doğrulayın
kubectl get pods -n apex-pay -l app.kubernetes.io/name=merchant-gateway -o wide

# Node-1 (10.0.10.122) üzerinden NodePort erişimini test edin -> HTTP 200 OK
kubectl run curl-n1 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.122:30080/

# Node-2 (10.0.10.208) üzerinden NodePort erişimini test edin -> HTTP 200 OK
kubectl run curl-n2 --rm -it --image=docker.io/library/curlimages/curl:8.5.0 --restart=Never -n apex-pay -- curl -m 3 -s -I http://10.0.10.208:30080/
```

---

## 🔬 Uçtan Uca Servis Ağı Doğrulama Betiği

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
