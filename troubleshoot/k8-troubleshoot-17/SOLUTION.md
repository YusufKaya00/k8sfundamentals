# 🇬🇧 English Version

# 🛠️ SRE Post-Mortem & Remediation Guide: Lab 17 (Master Review) — AetherMesh Platform (`aether-prod`)

This document serves as the authoritative **Principal Site Reliability Engineering (SRE) Post-Mortem & Master Remediation Runbook** for the 7-layer cascading outage across **AetherMesh**, our enterprise real-time payment settlement, in-memory event stream processing, node health telemetry, and L7 API gateway platform running in the `aether-prod` namespace.

> [!NOTE]
> **Strict 7-Layer Bottom-Up Dependency Chain:**  
> AetherMesh is engineered as a comprehensive master review (`INC-1701` -> `INC-1702` -> `INC-1703` -> `INC-1704` -> `INC-1705` -> `INC-1706` -> `INC-1707`). Always resolve and verify tickets in sequential order.

---

## 📑 Executive Incident Resolution Matrix (18 Sub-Faults Across 7 Tickets)

| Ticket ID | Impacted Component | Observed Symptom | Root Cause (Multi-Stage Sub-Faults) | Remediation Summary | Control Plane & Kernel Mechanics |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1701]** | `aether-db` (`StatefulSet`) & `aether-cache` (`Service`) | `aether-db-0` & PVC `Pending`, then `CrashLoopBackOff` (`initdb` error); Redis Service refuses connections | **1A:** Toleration `value: storage` (`database`)<br/>**1B:** Missing `subPath: pgdata` (ext4 `lost+found`)<br/>**1C:** `Service/aether-cache` `targetPort: 6380` (`6379`) | Fix `manifests/10-stateful-data.yaml`, run `kubectl apply`, and `kubectl delete pod aether-db-0 -n aether-prod` | Scheduler Taint Matching, CSI Block Volume, Ext4 `lost+found` & StatefulSet `OrderedReady` |
| **[INC-1702]** | `schema-migrator` (`Job`) & `cluster-heartbeat` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` & Redis host lookup failure | **2A:** `secretKeyRef.key: db_pass` (`db-password`)<br/>**2B:** `PGHOST: aether-postgres` (`aether-db`) + Job Immutability<br/>**2C:** `suspend: true` & `-h redis-service` (`aether-cache`) | Fix `manifests/20-batch-jobs.yaml` and run `kubectl replace --force -f manifests/20-batch-jobs.yaml` | Kubelet Pre-Start Secret Validation, `Job` Spec Immutability & `CronJob` Controller Loop |
| **[INC-1703]** | `stream-worker` (Helm Release) | Stuck in `Init:0/1`, then `OOMKilled` (`Exit Code 137`), then killed at 4s by `startupProbe` | **3A:** `db.port: 5433` (`5432`)<br/>**3B:** `limits.memory: 32Mi` (64 MiB allocation -> `256Mi`)<br/>**3C:** `startupProbe.failureThreshold: 2` (4s budget vs 7s warmup -> `10`) | Fix `helm-values/worker-prod.yaml` and run `helm upgrade --install stream-worker ./charts/stream-worker -f helm-values/worker-prod.yaml -n aether-prod` | InitContainer Gating, Linux Kernel cgroup OOM Killer (`137`) & Kubelet `startupProbe` Budgeting |
| **[INC-1704]** | `settlement-api` (`Deployment`, `ConfigMap`, `PDB`) | 2/3 pods `0/1 Running`, 3rd pod `Pending` on 2-node web tier; `/ready` fails (`:8080` & `127.0.0.1`) | **4A:** Hard `requiredDuringSchedulingIgnoredDuringExecution` anti-affinity on 2 web nodes (`preferred`)<br/>**4B:** `readinessProbe.port: 8080` (`8000`)<br/>**4C:** Inline `env` `CACHE_HOST: 127.0.0.1` overrides `envFrom`<br/>**4D:** `PDB` `minAvailable: 3` (`1`) | Fix `manifests/30-settlement-api.yaml` and run `kubectl apply -f manifests/30-settlement-api.yaml` | Hard vs Soft `podAntiAffinity`, Readiness Probe Port & `env` vs `envFrom` Precedence |
| **[INC-1705]** | `settlement-api-hpa` (`HPA`) & `Service/settlement-api` | HPA `<unknown>/70%` (`REPLICAS: 0`); `Service/settlement-api` has `Endpoints: <none>` | **5A:** Extra selector `role: core-engine`<br/>**5B:** `targetPort: 8080` (`8000`)<br/>**5C:** HPA `scaleTargetRef.name: settlement-service` (`settlement-api`) & missing `requests.cpu: 100m` | Add `requests.cpu: 100m` in `30-settlement-api.yaml`, fix `40-scaling-and-service.yaml`, and run `kubectl apply` | HPA Resource Utilization Formula (`requests.cpu`) & EndpointSlice Label Matching |
| **[INC-1706]** | `node-telemetry` (`DaemonSet`) | `DESIRED: 2` (missing Node-3) and pods crashing in `CrashLoopBackOff` (`Read-only file system`) | **6A:** Toleration `key: dedicated` (`workload`)<br/>**6B:** VolumeMount `readOnly: true` (`false`) | Fix `manifests/50-daemonset.yaml` and run `kubectl apply -f manifests/50-daemonset.yaml` | DaemonSet Taint Toleration Key Matching & Linux VFS Read-Only Mounts |
| **[INC-1707]** | `aether-gateway` (Helm Release) & `aether-ingress` (`Ingress`) | Port `80` `Connection refused`, then `/api/v1/settlements` `403 Forbidden`; Ingress class/port mismatch | **7A:** `service.targetPort: 8081` (`8080`)<br/>**7B:** `gateway.authToken: invalid-token` (`aether-prod-access-2026`) + `subPath` reload<br/>**7C:** Ingress `ingressClassName: nginx-internal` (`nginx`) & port `8080` (`80`) | Fix `helm-values/gateway-prod.yaml` & `manifests/60-ingress.yaml`, run `helm upgrade`, `rollout restart`, and `kubectl apply` | L4 Service TargetPort, L7 Header Auth, Kubelet `subPath` Inode Immutability & Ingress Binding |

---

## 🔧 Step-by-Step Deep-Dive Remediation

---

### [INC-1701] Stateful Database Scheduling, Ext4 `lost+found` & Redis Service Port (`manifests/10-stateful-data.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 1A (Taint Value Mismatch):** `Node-3` has taint `workload=database:NoSchedule`, but `StatefulSet/aether-db` toleration specifies `value: storage`. The Kubernetes scheduler filters out Node-3, leaving `aether-db-0` in `Pending`.
2. **Fault 1B (Ext4 `lost+found` & Missing `subPath: pgdata`):** Once scheduled, newly formatted ext4 block volumes contain a `lost+found` directory at their root mount. PostgreSQL `initdb` expects a completely empty directory; mounting directly to `/var/lib/postgresql/data` aborts `initdb`. Adding `subPath: pgdata` isolates the database files into a clean subfolder.
3. **Fault 1C (Redis Service TargetPort):** `Deployment/aether-cache` listens on `6379`, but `Service/aether-cache` forwards `port: 6379` to `targetPort: 6380`.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/10-stateful-data.yaml
+++ b/manifests/10-stateful-data.yaml
@@ -52,7 +52,7 @@ spec:
       tolerations:
         - key: workload
           operator: Equal
-          value: storage
+          value: database
           effect: NoSchedule
       containers:
         - name: postgres
@@ -103,6 +103,7 @@ spec:
           volumeMounts:
             - name: data
               mountPath: /var/lib/postgresql/data
+              subPath: pgdata
   volumeClaimTemplates:
     - metadata:
         name: data
@@ -128,7 +129,7 @@ spec:
   ports:
     - name: redis
       port: 6379
-      targetPort: 6380
+      targetPort: 6379
       protocol: TCP
   selector:
     app.kubernetes.io/name: aether-cache
```

Apply and recreate `aether-db-0`:
```bash
kubectl apply -f manifests/10-stateful-data.yaml
kubectl delete pod aether-db-0 -n aether-prod
kubectl wait --for=condition=ready pod/aether-db-0 -n aether-prod --timeout=90s
kubectl exec -n aether-prod deploy/aether-cache -- redis-cli -h aether-cache -p 6379 ping
```

---

### [INC-1702] Schema Migrator Job & Cluster Heartbeat CronJob Failure (`manifests/20-batch-jobs.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 2A (Secret Key Mismatch):** `aether-db-secret` defines `db-password`, but the Job template specifies `key: db_pass`. Kubelet fails container initialization with `CreateContainerConfigError`.
2. **Fault 2B (Database Host DNS & Job Immutability):** `PGHOST` is set to `aether-postgres` instead of `aether-db`. Because Kubernetes Jobs have immutable template specifications, running `kubectl apply` will fail with a spec validation error. You must force replacement via `kubectl replace --force -f ...`.
3. **Fault 2C (CronJob Suspended & Redis Host):** The CronJob is halted because `suspend: true`. Additionally, the Redis sync command targets non-existent `redis-service:6379` instead of `aether-cache:6379`.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/20-batch-jobs.yaml
+++ b/manifests/20-batch-jobs.yaml
@@ -46,7 +46,7 @@ spec:
           env:
             - name: PGHOST
-              value: "aether-postgres"
+              value: "aether-db"
             - name: PGPORT
               value: "5432"
             - name: PGDATABASE
@@ -57,7 +57,7 @@ spec:
               valueFrom:
                 secretKeyRef:
                   name: aether-db-secret
-                  key: db_pass
+                  key: db-password
 ---
 apiVersion: batch/v1
 kind: CronJob
@@ -72,7 +72,7 @@ spec:
   concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 3
   failedJobsHistoryLimit: 3
-  suspend: true
+  suspend: false
   jobTemplate:
     spec:
       backoffLimit: 2
@@ -91,4 +91,4 @@ spec:
                   echo "Sending heartbeat ping to Redis cache..."
-                  redis-cli -h redis-service -p 6379 SET aether:cluster:heartbeat "ONLINE_$(date +%s)" EX 120
+                  redis-cli -h aether-cache -p 6379 SET aether:cluster:heartbeat "ONLINE_$(date +%s)" EX 120
                   echo "Heartbeat registered successfully."
```

Apply and verify:
```bash
kubectl replace --force -f manifests/20-batch-jobs.yaml
kubectl wait --for=condition=complete job/schema-migrator -n aether-prod --timeout=45s
kubectl exec -n aether-prod aether-db-0 -- psql -U aether_admin -d aether_settlement -tAc "SELECT count(*) FROM settlements;"
kubectl create job --from=cronjob/cluster-heartbeat manual-heartbeat -n aether-prod && kubectl wait --for=condition=complete job/manual-heartbeat -n aether-prod --timeout=30s
kubectl exec -n aether-prod deploy/aether-cache -- redis-cli GET aether:cluster:heartbeat
```

---

### [INC-1703] Stream Worker `Init:0/1`, `OOMKilled` (`137`) & StartupProbe Failure (`helm-values/worker-prod.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 3A (InitContainer TCP Gating Port):** `worker-prod.yaml` configures `db.port: 5433`. The `nc -z -w 2 aether-db 5433` check loops endlessly because PostgreSQL listens on `5432`.
2. **Fault 3B (cgroup Memory OOMKilled):** The Python worker initializes a 64 MiB in-memory event buffer. The production override specifies `limits.memory: 32Mi`. When memory consumption exceeds the cgroup limit, the Linux kernel invokes the OOM killer (`kill -9`, Exit Code `137`).
3. **Fault 3C (StartupProbe Budget Calculation):** The worker takes 7 seconds to complete initialization. The startup probe is configured with `failureThreshold: 2` and `periodSeconds: 2`, giving a maximum budget of only 4 seconds. The container is terminated and restarted before completing warmup.

#### 2. 🛠️ Resolution
```diff
--- a/helm-values/worker-prod.yaml
+++ b/helm-values/worker-prod.yaml
@@ -2,7 +2,7 @@ replicaCount: 1
 
 db:
   host: "aether-db"
-  port: 5433
+  port: 5432
 
 cache:
   host: "aether-cache"
@@ -12,7 +12,7 @@ startupProbe:
   path: "/healthz"
   periodSeconds: 2
   timeoutSeconds: 2
-  failureThreshold: 2
+  failureThreshold: 10
 
 resources:
   requests:
@@ -21,4 +21,4 @@ resources:
   limits:
     cpu: 250m
-    memory: 32Mi
+    memory: 256Mi
```

Deploy the updated Helm release:
```bash
helm upgrade --install stream-worker ./charts/stream-worker -f helm-values/worker-prod.yaml -n aether-prod
kubectl rollout status deploy/stream-worker -n aether-prod --timeout=60s
kubectl exec -n aether-prod deploy/aether-cache -- wget -qO- http://stream-worker:9090/healthz
```

---

### [INC-1704] Settlement API Scheduling Deadlock, Probe Port & Env Precedence (`manifests/30-settlement-api.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 4A (2-Node Hard Anti-Affinity):** With 3 replicas and only 2 untainted web nodes, a hard `requiredDuringSchedulingIgnoredDuringExecution` rule ensures the 3rd replica cannot find an available node. Converting to `preferredDuringSchedulingIgnoredDuringExecution` allows colocation when necessary.
2. **Fault 4B (Readiness Probe Port Mismatch):** The Python server listens on port `8000`, but the readiness probe connects to port `8080`.
3. **Fault 4C (Environment Variable Precedence):** `envFrom` loads `CACHE_HOST: aether-cache` from ConfigMap, but an explicit inline `env` variable sets `CACHE_HOST: 127.0.0.1`. In Kubernetes, explicit `env` takes precedence over `envFrom`.
4. **Fault 4D (PDB Deadlock):** `minAvailable: 3` prevents node maintenance when only 2 replicas are running.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/30-settlement-api.yaml
+++ b/manifests/30-settlement-api.yaml
@@ -107,13 +107,15 @@ spec:
       affinity:
         podAntiAffinity:
-          requiredDuringSchedulingIgnoredDuringExecution:
-            - labelSelector:
-                matchExpressions:
-                  - key: app.kubernetes.io/name
-                    operator: In
-                    values:
-                      - settlement-api
-              topologyKey: kubernetes.io/hostname
+          preferredDuringSchedulingIgnoredDuringExecution:
+            - weight: 100
+              podAffinityTerm:
+                labelSelector:
+                  matchExpressions:
+                    - key: app.kubernetes.io/name
+                      operator: In
+                      values:
+                        - settlement-api
+                topologyKey: kubernetes.io/hostname
       containers:
         - name: api
@@ -137,9 +139,6 @@ spec:
           envFrom:
             - configMapRef:
                 name: settlement-api-config
-          env:
-            - name: CACHE_HOST
-              value: "127.0.0.1"
           livenessProbe:
             httpGet:
               path: /healthz
@@ -152,7 +151,7 @@ spec:
           readinessProbe:
             httpGet:
               path: /ready
-              port: 8080
+              port: 8000
             initialDelaySeconds: 5
             periodSeconds: 5
             timeoutSeconds: 2
@@ -160,6 +159,8 @@ spec:
           resources:
+            requests:
+              cpu: 100m
+              memory: 64Mi
             limits:
               cpu: 300m
               memory: 128Mi
@@ -176,6 +177,6 @@ apiVersion: policy/v1
 kind: PodDisruptionBudget
 metadata:
   name: settlement-api-pdb
   namespace: aether-prod
 spec:
-  minAvailable: 3
+  minAvailable: 1
```

Apply and verify:
```bash
kubectl apply -f manifests/30-settlement-api.yaml
kubectl rollout status deploy/settlement-api -n aether-prod --timeout=60s
kubectl exec -n aether-prod deploy/aether-cache -- wget -qO- http://settlement-api:8000/ready
```

---

### [INC-1705] Settlement API Service Selector & HPA Metric Starvation (`manifests/40-scaling-and-service.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 5A & 5B (Service Selector Drift & TargetPort):** `Service/settlement-api` specifies an extra label `role: core-engine` not present on any pod, causing `Endpoints: <none>`. Furthermore, `targetPort` is set to `8080` instead of `8000`.
2. **Fault 5C (HPA Target Name & Missing CPU Requests):** The HPA references `settlement-service` instead of `settlement-api`. In addition, the deployment container was missing `resources.requests.cpu`, preventing the metrics pipeline from computing utilization percentages.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/40-scaling-and-service.yaml
+++ b/manifests/40-scaling-and-service.yaml
@@ -10,11 +10,10 @@ spec:
   ports:
     - name: http
       port: 8000
-      targetPort: 8080
+      targetPort: 8000
       protocol: TCP
   selector:
     app.kubernetes.io/name: settlement-api
-    role: core-engine
 ---
 apiVersion: autoscaling/v2
 kind: HorizontalPodAutoscaler
@@ -26,7 +25,7 @@ spec:
   scaleTargetRef:
     apiVersion: apps/v1
     kind: Deployment
-    name: settlement-service
+    name: settlement-api
   minReplicas: 3
   maxReplicas: 6
```

Apply and verify:
```bash
kubectl apply -f manifests/40-scaling-and-service.yaml
kubectl get endpoints settlement-api -n aether-prod
kubectl get hpa settlement-api-hpa -n aether-prod
```

---

### [INC-1706] Node Telemetry DaemonSet Taint Key & Read-Only VFS Crash (`manifests/50-daemonset.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 6A (Toleration Key Typo):** Node-3 has taint `workload=database:NoSchedule`, but the DaemonSet tolerates `key: dedicated`. The DaemonSet controller skips Node-3, scheduling on only 2 nodes (`DESIRED: 2`).
2. **Fault 6B (Read-Only Mount):** The volume mount sets `readOnly: true`, preventing the collector script from writing `/var/log/aether/telemetry.log`.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/50-daemonset.yaml
+++ b/manifests/50-daemonset.yaml
@@ -16,7 +16,7 @@ spec:
     spec:
       tolerations:
-        - key: dedicated
+        - key: workload
           operator: Exists
           effect: NoSchedule
       containers:
@@ -46,7 +46,7 @@ spec:
           volumeMounts:
             - name: log-dir
               mountPath: /var/log/aether
-              readOnly: true
+              readOnly: false
```

Apply and verify:
```bash
kubectl apply -f manifests/50-daemonset.yaml
kubectl rollout status ds/node-telemetry -n aether-prod --timeout=45s
kubectl get ds node-telemetry -n aether-prod
kubectl logs -n aether-prod ds/node-telemetry --tail=5
```

---

### [INC-1707] L7 Edge API Gateway TargetPort, Security Header & Ingress Binding

#### 1. 🧠 Diagnostic Mindset
1. **Fault 7A (Gateway Service TargetPort):** `service.targetPort: 8081` forwards traffic to an unopened port on the Nginx container (`8080`).
2. **Fault 7B (L7 Header Token & `subPath` Inode Reload):** The upstream `settlement-api` verifies `X-Aether-Token: aether-prod-access-2026`. Updating `gateway-prod.yaml` and running `helm upgrade` updates the ConfigMap, but because `nginx.conf` is mounted via `subPath`, the running container retains the old inode until restarted via `kubectl rollout restart`.
3. **Fault 7C (Ingress Class & Port):** Ingress specifies `ingressClassName: nginx-internal` instead of `nginx`, and forwards to port `8080` instead of port `80`.

#### 2. 🛠️ Resolution
Update `helm-values/gateway-prod.yaml`:
```diff
--- a/helm-values/gateway-prod.yaml
+++ b/helm-values/gateway-prod.yaml
@@ -3,7 +3,7 @@ replicaCount: 1
 service:
   type: LoadBalancer
   port: 80
-  targetPort: 8081
+  targetPort: 8080
 
 gateway:
-  authToken: "invalid-token"
+  authToken: "aether-prod-access-2026"
```

Update `manifests/60-ingress.yaml`:
```diff
--- a/manifests/60-ingress.yaml
+++ b/manifests/60-ingress.yaml
@@ -8,7 +8,7 @@ metadata:
   annotations:
     kubernetes.io/ingress.class: nginx
 spec:
-  ingressClassName: nginx-internal
+  ingressClassName: nginx
   rules:
     - http:
         paths:
@@ -17,4 +17,4 @@ spec:
             backend:
               service:
                 name: aether-gateway
                 port:
-                  number: 8080
+                  number: 80
```

Deploy, trigger rolling restart, and verify:
```bash
helm upgrade --install aether-gateway ./charts/aether-gateway -f helm-values/gateway-prod.yaml -n aether-prod
kubectl rollout restart deployment/aether-gateway -n aether-prod
kubectl rollout status deployment/aether-gateway -n aether-prod --timeout=45s
kubectl apply -f manifests/60-ingress.yaml

# Verification: Full End-to-End Pipeline
kubectl exec -n aether-prod deploy/aether-cache -- curl -s http://aether-gateway:80/api/v1/settlements
```

---
---

# 🇹🇷 Türkçe Sürüm

# 🛠️ SRE Kök Neden Analizi (RCA) ve Onarım Kılavuzu: Lab 17 (Kapsamlı Tekrar) — AetherMesh Platformu

Bu belge, `aether-prod` ad alanında çalışan **AetherMesh** gerçek zamanlı ödeme takas, stream işleme ve L7 API gateway platformunda yaşanan 7 katmanlı kesintinin yetkili **Kıdemli SRE Kök Neden Analizi ve Onarım Kılavuzu**dur.

### 🎯 Katman Bazında Hızlı Onarım Adımları:
1. **[INC-1701] Veritabanı ve Redis:** `manifests/10-stateful-data.yaml` dosyasında toleration değerini `database`, mountPath altına `subPath: pgdata`, ve Redis servisinde `targetPort: 6379` yapın. `kubectl apply` sonrası `kubectl delete pod aether-db-0 -n aether-prod` çalıştırın.
2. **[INC-1702] Batch Job'lar:** `manifests/20-batch-jobs.yaml` dosyasında `PGHOST: "aether-db"`, secret key `db-password`, `suspend: false` ve `-h aether-cache` olarak güncelleyin. Job değişmezliği nedeniyle `kubectl replace --force -f manifests/20-batch-jobs.yaml` çalıştırın.
3. **[INC-1703] Stream Worker:** `helm-values/worker-prod.yaml` dosyasında `db.port: 5432`, `startupProbe.failureThreshold: 10`, ve `limits.memory: 256Mi` yapıp `helm upgrade --install stream-worker ./charts/stream-worker -f helm-values/worker-prod.yaml -n aether-prod` komutunu verin.
4. **[INC-1704] Settlement API:** `manifests/30-settlement-api.yaml` dosyasında anti-affinity kuralını `preferredDuringSchedulingIgnoredDuringExecution` yapın, inline `CACHE_HOST` değişkenini silin, `readinessProbe` portunu `8000` yapın, `requests.cpu: 100m` ekleyin ve PDB `minAvailable: 1` yapın. `kubectl apply` ile uygulayın.
5. **[INC-1705] Service ve HPA:** `manifests/40-scaling-and-service.yaml` dosyasında `targetPort: 8000` yapın, `role: core-engine` etiketini kaldırın ve HPA `scaleTargetRef.name: settlement-api` olarak düzeltip `kubectl apply` yapın.
6. **[INC-1706] DaemonSet:** `manifests/50-daemonset.yaml` dosyasında toleration key'ini `workload` yapın, `readOnly: false` yapıp `kubectl apply` ile güncelleyin.
7. **[INC-1707] L7 Gateway ve Ingress:** `helm-values/gateway-prod.yaml` dosyasında `targetPort: 8080`, `authToken: "aether-prod-access-2026"` yapıp `helm upgrade` çalıştırın. ConfigMap `subPath` inode yenilenmesi için `kubectl rollout restart deployment/aether-gateway -n aether-prod` komutunu verin. `manifests/60-ingress.yaml` dosyasında `ingressClassName: nginx` ve port `80` yapıp `kubectl apply` yapın.
