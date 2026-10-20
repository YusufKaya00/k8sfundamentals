# 🛠️ SRE Incident Remediation Guide & Post-Mortem: Lab 6 (AeroOps)

This guide documents the root cause analyses (RCA), architectural remediation steps, and verification procedures for **Incident Lab 6 (AeroOps Flight Radar & Mesh Dispatch Outage)**.

---

## 📑 Incident Executive Summary

| Ticket ID | Impacted Component | Root Cause | Fix Strategy | Severity |
| :--- | :--- | :--- | :--- | :--- |
| **[INC-601]** | `radar-db` (StatefulSet) | Toleration value typo (`value: "db"` instead of `value: "database"`) against Node-3 taint `workload=database:NoSchedule`. | Update toleration value to `"database"`. | `P1 - Blocker` |
| **[INC-602]** | `radar-db` (Headless Service) | Service named `radar-db-headless` (mismatches StatefulSet `serviceName: "radar-db"`) & selector specifies `tier: backend` instead of `database`. | Recreate Headless Service as `radar-db` with selector `tier: database`. | `P1 - Blocker` |
| **[INC-603]** | `track-cache` (ClusterIP Service) | Service `targetPort: 6380` forwards to unused port (Redis listens on 6379). | Update `targetPort` to `6379`. | `P1 - Blocker` |
| **[INC-604]** | `telemetry-api` (Deployment) | Liveness and Readiness probes configured with port `8000` instead of application port `8080`. | Update probe ports to `8080`. | `P1 - Blocker` |
| **[INC-605]** | `telemetry-api-config` (ConfigMap) | `DB_PORT` set to `"5433"` instead of `"5432"`. | Correct `DB_PORT` to `"5432"` and restart API deployment. | `P1 - Blocker` |
| **[INC-606]** | `telemetry-api` (Service) | Service selector includes phantom label `app.kubernetes.io/version: v2` absent from Pod template. | Remove phantom label from Service selector. | `P1 - Blocker` |
| **[INC-607]** | `gateway-nginx-conf` (ConfigMap) | Nginx reverse proxy forwards `/api/radar` to `http://telemetry-api:80` instead of port `8080`. | Correct upstream port to `8080` in `nginx.conf` and restart Gateway. | `P1 - Blocker` |
| **[INC-608]** | `flight-gateway` (Deployment) | Hard anti-affinity (`requiredDuringScheduling...`) on 3 replicas across a 2-node web pool deadlocks 3rd replica. | Change anti-affinity to soft (`preferredDuringScheduling...`). | `P2 - High` |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-601] Remediation: Radar Database Pod Stuck in Pending

#### 1. Root Cause Analysis (RCA)
`Node-3` (`10.0.10.78`) carries the taint `workload=database:NoSchedule`. In `manifests/20-database.yaml`, the `radar-db` StatefulSet defines:
```yaml
tolerations:
- key: "workload"
  operator: "Equal"
  value: "db" # <-- TYPO! Node taint has value: "database"
  effect: "NoSchedule"
```
Because the toleration value `"db"` does not match the node taint value `"database"`, the Kube-scheduler marks Node-3 as untolerated. Combined with `nodeSelector: { tier: database }`, the pod cannot be scheduled on any node and remains `Pending`.

#### 2. Corrected Manifest Patch
```yaml
tolerations:
- key: "workload"
  operator: "Equal"
  value: "database" # Fixed
  effect: "NoSchedule"
```

#### 3. Execution Commands
```bash
kubectl patch statefulset radar-db -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/tolerations/0/value", "value": "database"}
]'
```

#### 4. Verification Commands
```bash
# Verify pod scheduled on Node-3 (10.0.10.78)
kubectl get pod radar-db-0 -n aero-prod -o wide

# Verify PostgreSQL is ready to accept connections
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry
```

---

### [INC-602] Remediation: Radar Database Headless Service DNS Failure

#### 1. Root Cause Analysis (RCA)
CoreDNS assigns individual StatefulSet pod records (`<pod>.<service>.<ns>.svc.cluster.local`) strictly when:
1. The Service `metadata.name` matches the StatefulSet's `spec.serviceName`.
2. The Service selector matches the pod labels.

In `manifests/20-database.yaml`:
* StatefulSet specifies `serviceName: "radar-db"`.
* Headless Service was created with `name: radar-db-headless`.
* Service selector specified `tier: backend` instead of `tier: database`.
Consequently, the service has no endpoints and CoreDNS rejects queries with `NXDOMAIN`.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: Service
metadata:
  name: radar-db # Fixed: Matches StatefulSet spec.serviceName
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: radar-db
    app.kubernetes.io/part-of: aero-ops
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: radar-db
    tier: database # Fixed: Matches Pod label
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl delete svc radar-db-headless -n aero-prod --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: radar-db
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: radar-db
    app.kubernetes.io/part-of: aero-ops
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: radar-db
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
# Check endpoints
kubectl get endpoints radar-db -n aero-prod

# Inter-pod TCP check from the cache pod
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
```

---

### [INC-603] Remediation: Flight Track Cache Refuses TCP Traffic

#### 1. Root Cause Analysis (RCA)
In `manifests/30-cache.yaml`:
```yaml
ports:
- name: redis
  port: 6379
  targetPort: 6380 # <-- BUG: Redis container listens on 6379!
```
Kube-proxy forwards connections on ClusterIP:6379 to PodIP:6380. Because nothing is listening on port 6380 inside the container, the pod network stack immediately returns a TCP RST packet (`Connection refused`).

#### 2. Corrected Manifest Patch
```yaml
ports:
- name: redis
  port: 6379
  targetPort: 6379 # Fixed
  protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl patch svc track-cache -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 6379}
]'
```

#### 4. Verification Commands
```bash
# Describe service to verify targetPort
kubectl describe svc track-cache -n aero-prod

# Verify TCP connectivity from database pod
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379
```

---

### [INC-604] Remediation: Telemetry API Containers CrashLoopBackOff

#### 1. Root Cause Analysis (RCA)
In `manifests/40-api.yaml`:
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8000 # <-- BUG: Application listens on port 8080!
readinessProbe:
  httpGet:
    path: /ready
    port: 8000 # <-- BUG: Application listens on port 8080!
```
The application logs indicate `Telemetry API listening on 0.0.0.0:8080...`. Because the probe attempts to contact port 8000, Kubelet receives connection refused, marks the container unhealthy, and restarts it in an infinite CrashLoopBackOff.

#### 2. Corrected Manifest Patch
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080 # Fixed
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /ready
    port: 8080 # Fixed
  initialDelaySeconds: 5
  periodSeconds: 5
```

#### 3. Execution Commands
```bash
kubectl patch deployment telemetry-api -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/port", "value": 8080}
]'
```

#### 4. Verification Commands
```bash
# Verify pods stabilize without restarts
kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod

# Test internal health endpoint
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
```

---

### [INC-605] Remediation: Telemetry API Stable but NotReady (0/1)

#### 1. Root Cause Analysis (RCA)
Once probe ports are aligned, `telemetry-api` pods remain `0/1 NotReady`. Invoking `/ready` returns:
```json
{
  "ready": false,
  "database": {"host": "radar-db", "port": 5433, "status": "[Errno 111] Connection refused"},
  "cache": {"host": "track-cache", "port": 6379, "status": "connected"}
}
```
In `manifests/10-config.yaml`, the `DB_PORT` was misconfigured as `"5433"` instead of `"5432"`.

#### 2. Corrected Manifest Patch
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telemetry-api-config
  namespace: aero-prod
data:
  DB_PORT: "5432" # Fixed
```

#### 3. Execution Commands
```bash
# Update ConfigMap and trigger rolling restart
kubectl patch configmap telemetry-api-config -n aero-prod --type='merge' -p '{"data":{"DB_PORT":"5432"}}'
kubectl rollout restart deployment telemetry-api -n aero-prod
kubectl rollout status deployment telemetry-api -n aero-prod
```

#### 4. Verification Commands
```bash
# Test /ready endpoint (returns HTTP 200)
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# Check pod ready state
kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod
```

---

### [INC-606] Remediation: Telemetry API Service Has Empty Endpoints

#### 1. Root Cause Analysis (RCA)
In `manifests/40-api.yaml`, the Service selector defines:
```yaml
selector:
  app.kubernetes.io/name: telemetry-api
  app.kubernetes.io/version: v2 # <-- PHANTOM LABEL!
```
The pod template only carries:
```yaml
labels:
  app.kubernetes.io/name: telemetry-api
  app.kubernetes.io/part-of: aero-ops
  tier: web
```
The Endpoint controller matches selectors via boolean AND. The missing label causes `Endpoints: <none>`.

#### 2. Corrected Manifest Patch
```yaml
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: telemetry-api # Fixed
  ports:
  - name: http
    port: 8080
    targetPort: 8080
    protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl patch svc telemetry-api -n aero-prod --type='merge' -p '{"spec":{"selector":{"app.kubernetes.io/name":"telemetry-api","app.kubernetes.io/version":null}}}'
```

#### 4. Verification Commands
```bash
# Verify 2 active endpoints
kubectl get endpoints telemetry-api -n aero-prod

# Verify port reachability from gateway pod
kubectl exec -n aero-prod deploy/flight-gateway -- nc -zv telemetry-api 8080
```

---

### [INC-607] Remediation: Flight Gateway Returns 502 Bad Gateway

#### 1. Root Cause Analysis (RCA)
In `manifests/10-config.yaml`, the Nginx configuration specifies:
```nginx
location /api/radar {
    proxy_pass http://telemetry-api:80; # <-- BUG: Service port is 8080!
}
```
Because the `telemetry-api` Service exposes port `8080` (not port 80), Nginx receives `Connection refused` when attempting to proxy traffic to port 80, returning `HTTP 502 Bad Gateway`.

#### 2. Corrected Manifest Patch
```nginx
location /api/radar {
    proxy_pass http://telemetry-api:8080; # Fixed
    proxy_connect_timeout 2s;
    proxy_read_timeout 3s;
}
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-nginx-conf
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: flight-gateway
    app.kubernetes.io/part-of: aero-ops
data:
  nginx.conf: |
    events {
        worker_connections 1024;
    }
    http {
        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log warn;

        server {
            listen 8080;
            server_name _;

            location /health {
                default_type application/json;
                return 200 '{"status": "healthy", "service": "flight-gateway"}\n';
            }

            location /api/radar {
                proxy_pass http://telemetry-api:8080;
                proxy_connect_timeout 2s;
                proxy_read_timeout 3s;
            }

            location / {
                default_type application/json;
                return 200 '{"platform": "AeroOps Air Traffic Dispatch Gateway", "version": "v4.1"}\n';
            }
        }
    }
EOF

# Restart gateway to reload configuration
kubectl rollout restart deployment flight-gateway -n aero-prod
kubectl rollout status deployment flight-gateway -n aero-prod
```

#### 4. Verification Commands
```bash
# Verify Nginx reverse proxy returns flight data
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar
```

---

### [INC-608] Remediation: Flight Gateway High Availability Warning

#### 1. Root Cause Analysis (RCA)
In `manifests/50-gateway.yaml`:
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app.kubernetes.io/name
          operator: In
          values: ["flight-gateway"]
      topologyKey: kubernetes.io/hostname
```
The cluster only possesses 2 worker nodes labeled `tier=web` (`Node-1` and `Node-2`). `Node-3` is tainted exclusively for database workloads. Hard anti-affinity strictly forbids placing 2 gateway pods on the same node. Because `replicas: 3`, the 3rd pod is deadlocked in `Pending`.

#### 2. Corrected Manifest Patch
Convert hard anti-affinity to soft (`preferredDuringScheduling...`), allowing high availability with graceful multi-pod scheduling when node capacity is constrained:
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values: ["flight-gateway"]
        topologyKey: kubernetes.io/hostname
```

#### 3. Execution Commands
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flight-gateway
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: flight-gateway
    app.kubernetes.io/part-of: aero-ops
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: flight-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: flight-gateway
        app.kubernetes.io/part-of: aero-ops
        tier: web
    spec:
      nodeSelector:
        tier: web
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values: ["flight-gateway"]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
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
# Verify 3/3 pods running
kubectl get deployment flight-gateway -n aero-prod
kubectl get pods -l app.kubernetes.io/name=flight-gateway -n aero-prod -o wide
```

---

## 🏁 Full Flight Radar Platform Verification

```bash
# 1. Database & Persistence Health
kubectl get pod radar-db-0 -n aero-prod -o wide
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry

# 2. Services & Port Reachability
kubectl get svc,endpoints -n aero-prod
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379

# 3. Microservice Readiness Checks
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# 4. Gateway Proxy & Flight Tracking Telemetry
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar

# 5. External Port-Forward Verification
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

# 🛠️ SRE Olay Müdahale ve Çözüm Rehberi: Lab 6 (AeroOps)

Bu doküman, **Incident Lab 6 (AeroOps Uçuş Radar & Servis Ağı Kesintisi)** için kök neden analizlerini (RCA), mimari düzeltme adımlarını ve doğrulama yönergelerini içermektedir.

---

## 📑 Olay Özeti (Executive Summary)

| Bilet No | Etkilenen Bileşen | Kök Neden (RCA) | Çözüm Stratejisi | Önem Derecesi |
| :--- | :--- | :--- | :--- | :--- |
| **[INC-601]** | `radar-db` (StatefulSet) | Toleration değer hatası (`value: "db"` yerine `value: "database"`) nedeniyle Node-3 taint'ine takılması. | Toleration değerini `"database"` yapın. | `P1 - Blocker` |
| **[INC-602]** | `radar-db` (Headless Service) | Servis adının `radar-db-headless` olması (`serviceName: "radar-db"` ile uyuşmuyor) ve selector'ın `tier: backend` olması. | Servisi `radar-db` adıyla ve selector `tier: database` olacak şekilde yeniden oluşturun. | `P1 - Blocker` |
| **[INC-603]** | `track-cache` (ClusterIP Service) | Servis `targetPort: 6380` atanmış, oysa Redis 6379 portunu dinliyor. | Servisin `targetPort` değerini `6379` yapın. | `P1 - Blocker` |
| **[INC-604]** | `telemetry-api` (Deployment) | Liveness ve Readiness probları 8080 yerine yanlışlıkla 8000 portuna bağlanıyor. | Prob portlarını `8080` olarak düzeltin. | `P1 - Blocker` |
| **[INC-605]** | `telemetry-api-config` (ConfigMap) | `DB_PORT` değişkeni `"5433"` olarak tanımlanmış. | `DB_PORT` değerini `"5432"` yapın ve deployment'ı yeniden başlatın. | `P1 - Blocker` |
| **[INC-606]** | `telemetry-api` (Service) | Servis selector'ında podda bulunmayan `app.kubernetes.io/version: v2` etiketi var. | Selector'dan versiyon etiketini kaldırın. | `P1 - Blocker` |
| **[INC-607]** | `gateway-nginx-conf` (ConfigMap) | Nginx ters proxy `/api/radar` isteğini 8080 yerine port 80'e yönlendiriyor. | `nginx.conf` içinde portu `8080` yapın ve gateway podlarını yeniden başlatın. | `P1 - Blocker` |
| **[INC-608]** | `flight-gateway` (Deployment) | 2 web node'lu kümede 3 pod için katı (required) anti-affinity kuralı 3. podu kilitliyor. | Anti-affinity kuralını yumuşak (`preferredDuringScheduling...`) yapın. | `P2 - High` |

---

## 🔧 Adım Adım Olay Çözüm Rehberi

---

### [INC-601] Çözüm: Radar Veritabanı Podu Pending Durumunda

#### 1. Kök Neden Analizi (RCA)
`Node-3` (`10.0.10.78`) üzerinde `workload=database:NoSchedule` taint'i bulunmaktadır. `manifests/20-database.yaml` dosyasında toleration `value: "db"` yazılmıştır. Bu değer taint ile uyuşmadığı için pod planlanamaz ve `Pending` kalır.

#### 2. Düzeltilmiş Manifesto Yaması
```yaml
tolerations:
- key: "workload"
  operator: "Equal"
  value: "database" # Düzeltildi
  effect: "NoSchedule"
```

#### 3. Uygulama Komutları
```bash
kubectl patch statefulset radar-db -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/tolerations/0/value", "value": "database"}
]'
```

#### 4. Doğrulama Komutları
```bash
# Podun Node-3 üzerinde çalıştığını doğrulayın
kubectl get pod radar-db-0 -n aero-prod -o wide

# Veritabanının hazır olduğunu test edin
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry
```

---

### [INC-602] Çözüm: Radar Veritabanı Headless Service DNS Hatası

#### 1. Kök Neden Analizi (RCA)
CoreDNS'in StatefulSet podlarına DNS kaydı (`<pod>.<servis>.<ns>.svc.cluster.local`) üretebilmesi için servisin adı StatefulSet içindeki `spec.serviceName` ile birebir aynı olmalı ve etiketler eşleşmelidir. Servis adı `radar-db-headless` ve selector `tier: backend` yapıldığı için CoreDNS sorguları `NXDOMAIN` dönmektedir.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: Service
metadata:
  name: radar-db
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: radar-db
    app.kubernetes.io/part-of: aero-ops
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: radar-db
    tier: database
  ports:
  - name: postgresql
    port: 5432
    targetPort: 5432
    protocol: TCP
```

#### 3. Uygulama Komutları
```bash
kubectl delete svc radar-db-headless -n aero-prod --ignore-not-found
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: radar-db
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: radar-db
    app.kubernetes.io/part-of: aero-ops
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: radar-db
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
# Endpoint'lerin oluştuğunu doğrulayın
kubectl get endpoints radar-db -n aero-prod

# Cache podundan veritabanı portuna erişimi test edin
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
```

---

### [INC-603] Çözüm: Uçuş İzleme Önbelleği TCP Bağlantı Reddi

#### 1. Kök Neden Analizi (RCA)
`manifests/30-cache.yaml` dosyasında `targetPort: 6380` yazılmıştır. Konteyner içindeki Redis 6379 portunu dinlediğinden, dinlenmeyen 6380 portuna giden paketler anında `Connection refused` (TCP RST) ile reddedilir.

#### 2. Düzeltilmiş Manifesto Yaması
```yaml
ports:
- name: redis
  port: 6379
  targetPort: 6379 # Düzeltildi
  protocol: TCP
```

#### 3. Uygulama Komutları
```bash
kubectl patch svc track-cache -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/ports/0/targetPort", "value": 6379}
]'
```

#### 4. Doğrulama Komutları
```bash
# Servis detaylarını kontrol edin
kubectl describe svc track-cache -n aero-prod

# Veritabanı podundan önbelleğe TCP ping atın
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379
```

---

### [INC-604] Çözüm: Telemetry API Konteynerleri CrashLoopBackOff

#### 1. Kök Neden Analizi (RCA)
Uygulama 8080 portunu dinlemektedir. Fakat liveness ve readiness probları port 8000 olarak tanımlanmıştır. Kubelet bağlantı kuramadığı için konteyneri sürekli öldürüp yeniden başlatmaktadır.

#### 2. Düzeltilmiş Manifesto Yaması
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080 # Düzeltildi
readinessProbe:
  httpGet:
    path: /ready
    port: 8080 # Düzeltildi
```

#### 3. Uygulama Komutları
```bash
kubectl patch deployment telemetry-api -n aero-prod --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/livenessProbe/httpGet/port", "value": 8080},
  {"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/port", "value": 8080}
]'
```

#### 4. Doğrulama Komutları
```bash
# Podların yeniden başlamadan çalıştığını doğrulayın
kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod

# Dahili sağlık probunu test edin
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
```

---

### [INC-605] Çözüm: Telemetry API Podları Çalışıyor Ancak 0/1 Ready

#### 1. Kök Neden Analizi (RCA)
API podları ayakta kalır ancak `/ready` kontrolü HTTP 503 döner. `manifests/10-config.yaml` içinde `DB_PORT: "5433"` yazıldığı için veritabanına bağlanılamamaktadır.

#### 2. Düzeltilmiş Manifesto
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: telemetry-api-config
  namespace: aero-prod
data:
  DB_PORT: "5432" # Düzeltildi
```

#### 3. Uygulama Komutları
```bash
kubectl patch configmap telemetry-api-config -n aero-prod --type='merge' -p '{"data":{"DB_PORT":"5432"}}'
kubectl rollout restart deployment telemetry-api -n aero-prod
kubectl rollout status deployment telemetry-api -n aero-prod
```

#### 4. Doğrulama Komutları
```bash
# /ready kontrolünün HTTP 200 döndüğünü test edin
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# Podların 1/1 Ready olduğunu doğrulayın
kubectl get pods -l app.kubernetes.io/name=telemetry-api -n aero-prod
```

---

### [INC-606] Çözüm: Telemetry API Servisinin Endpoint'leri Boş

#### 1. Kök Neden Analizi (RCA)
`manifests/40-api.yaml` dosyasında servis selector'ında pod üzerinde bulunmayan `app.kubernetes.io/version: v2` etiketi bulunmaktadır. Bu sebeple Endpoint kontrolcüsü hiçbir podu servise bağlamamıştır (`Endpoints: <none>`).

#### 2. Düzeltilmiş Manifesto Yaması
```yaml
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: telemetry-api # Düzeltildi
```

#### 3. Uygulama Komutları
```bash
kubectl patch svc telemetry-api -n aero-prod --type='merge' -p '{"spec":{"selector":{"app.kubernetes.io/name":"telemetry-api","app.kubernetes.io/version":null}}}'
```

#### 4. Doğrulama Komutları
```bash
# 2 adet aktif endpoint olduğunu doğrulayın
kubectl get endpoints telemetry-api -n aero-prod

# Gateway podundan API portuna erişimi test edin
kubectl exec -n aero-prod deploy/flight-gateway -- nc -zv telemetry-api 8080
```

---

### [INC-607] Çözüm: Flight Gateway 502 Bad Gateway Dönüyor

#### 1. Kök Neden Analizi (RCA)
Nginx yapılandırmasında `proxy_pass http://telemetry-api:80;` yazılmıştır. Ancak `telemetry-api` servisi 8080 portunu açmaktadır. Bu sebeple Nginx `Connection refused` alarak istemciye `502 Bad Gateway` dönmektedir.

#### 2. Düzeltilmiş Manifesto
```nginx
location /api/radar {
    proxy_pass http://telemetry-api:8080; # Düzeltildi
    proxy_connect_timeout 2s;
    proxy_read_timeout 3s;
}
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gateway-nginx-conf
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: flight-gateway
    app.kubernetes.io/part-of: aero-ops
data:
  nginx.conf: |
    events {
        worker_connections 1024;
    }
    http {
        access_log /var/log/nginx/access.log;
        error_log /var/log/nginx/error.log warn;

        server {
            listen 8080;
            server_name _;

            location /health {
                default_type application/json;
                return 200 '{"status": "healthy", "service": "flight-gateway"}\n';
            }

            location /api/radar {
                proxy_pass http://telemetry-api:8080;
                proxy_connect_timeout 2s;
                proxy_read_timeout 3s;
            }

            location / {
                default_type application/json;
                return 200 '{"platform": "AeroOps Air Traffic Dispatch Gateway", "version": "v4.1"}\n';
            }
        }
    }
EOF

kubectl rollout restart deployment flight-gateway -n aero-prod
kubectl rollout status deployment flight-gateway -n aero-prod
```

#### 4. Doğrulama Komutları
```bash
# Gateway üzerinden uçuş verisinin geldiğini doğrulayın
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar
```

---

### [INC-608] Çözüm: Flight Gateway Yüksek Erişilebilirlik Uyarısı

#### 1. Kök Neden Analizi (RCA)
Kümede yalnızca 2 adet `tier=web` node'u vardır (`Node-1` ve `Node-2`). Katı anti-affinity (`requiredDuringScheduling...`) kuralı sebebiyle 3. replica hiçbir node'a yerleşemez ve `Pending` kalır.

#### 2. Düzeltilmiş Manifesto
Kuralı esnek/yumuşak (`preferredDuringScheduling...`) hale getirerek 3. podun da planlanmasına izin verin:
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app.kubernetes.io/name
            operator: In
            values: ["flight-gateway"]
        topologyKey: kubernetes.io/hostname
```

#### 3. Uygulama Komutları
```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flight-gateway
  namespace: aero-prod
  labels:
    app.kubernetes.io/name: flight-gateway
    app.kubernetes.io/part-of: aero-ops
spec:
  replicas: 3
  selector:
    matchLabels:
      app.kubernetes.io/name: flight-gateway
  template:
    metadata:
      labels:
        app.kubernetes.io/name: flight-gateway
        app.kubernetes.io/part-of: aero-ops
        tier: web
    spec:
      nodeSelector:
        tier: web
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values: ["flight-gateway"]
              topologyKey: kubernetes.io/hostname
      containers:
      - name: gateway
        image: docker.io/library/nginx:1.25-alpine
        ports:
        - name: http
          containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 128Mi
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
# 3/3 podun çalıştığını doğrulayın
kubectl get deployment flight-gateway -n aero-prod
kubectl get pods -l app.kubernetes.io/name=flight-gateway -n aero-prod -o wide
```

---

## 🏁 Uçtan Uca Uçuş Radar Platformu Doğrulama

```bash
# 1. Veritabanı ve Kalıcılık Durumu
kubectl get pod radar-db-0 -n aero-prod -o wide
kubectl exec -n aero-prod radar-db-0 -- pg_isready -U aero_admin -d aero_telemetry

# 2. Servisler ve Port Erişilebilirliği
kubectl get svc,endpoints -n aero-prod
kubectl exec -n aero-prod deploy/track-cache -- nc -zv radar-db 5432
kubectl exec -n aero-prod radar-db-0 -- nc -zv track-cache 6379

# 3. Mikroservis Hazırlık Durumu Kontrolleri
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/health
kubectl exec -n aero-prod deploy/telemetry-api -c api -- wget -qO- http://localhost:8080/ready

# 4. Gateway Proxy ve Uçuş Radar Verisi
kubectl exec -n aero-prod deploy/flight-gateway -- wget -qO- http://localhost:8080/api/radar

# 5. Harici Port-Forward Doğrulaması
kubectl port-forward svc/flight-gateway -n aero-prod 8080:80 &
PF_PID=$!
sleep 2
curl -s http://localhost:8080/health
curl -s http://localhost:8080/api/radar
kill $PF_PID
```
