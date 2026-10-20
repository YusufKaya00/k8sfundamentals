# 🇬🇧 English Version

# 🛠️ SRE Post-Mortem & Remediation Guide: Lab 16 (Grand Finale Capstone) — OmniCore Platform (`omnicore-prod`)

This document serves as the authoritative **Principal Site Reliability Engineering (SRE) Post-Mortem & Capstone Remediation Runbook** for the 7-layer cascading outage across **OmniCore**, our enterprise order fulfillment, ledger settlement, real-time catalog indexing, node telemetry, and L7 API gateway platform running in the `omnicore-prod` namespace on Oracle Cloud Kubernetes Engine (OKE).

> [!NOTE]
> **Strict 7-Layer Bottom-Up Dependency Chain:**  
> OmniCore is engineered as a comprehensive master review (`INC-1601` -> `INC-1602` -> `INC-1603` -> `INC-1604` -> `INC-1605` -> `INC-1606` -> `INC-1607`). Always resolve and verify tickets in sequential order.

---

## 📑 Executive Incident Resolution Matrix (18 Sub-Faults Across 7 Tickets)

| Ticket ID | Impacted Component | Observed Symptom | Root Cause (Multi-Stage Sub-Faults) | Remediation Summary | Control Plane & Kernel Mechanics |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1601]** | `omnicore-db` (`StatefulSet`) & `omnicore-redis` (`Service`) | `omnicore-db-0` & PVC `Pending`, then `CrashLoopBackOff` (`initdb` error); Redis Service refuses connections | **1A:** Toleration `effect: NoExecute` (`NoSchedule`)<br/>**1B:** Missing `subPath: pgdata` (ext4 `lost+found`)<br/>**1C:** `Service/omnicore-redis` `targetPort: 6380` (`6379`) | Fix `manifests/10-stateful-data.yaml`, run `kubectl apply`, and `kubectl delete pod omnicore-db-0 -n omnicore-prod` | Scheduler Taint Effect Matching, CSI `WaitForFirstConsumer`, Ext4 `lost+found` & StatefulSet `OrderedReady` |
| **[INC-1602]** | `schema-migrator` (`Job`) & `state-heartbeat` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` & Redis host lookup failure | **2A:** `secretKeyRef.key: postgres-pass` (`db-password`)<br/>**2B:** `PGHOST: omnicore-postgres` (`omnicore-db`) + Job Immutability<br/>**2C:** `suspend: true` & `-h redis-master` (`omnicore-redis`) | Fix `manifests/20-batch-jobs.yaml` and run `kubectl replace --force -f manifests/20-batch-jobs.yaml` | Kubelet Pre-Start Secret Validation, `Job` Spec Immutability & `CronJob` Controller Loop |
| **[INC-1603]** | `catalog-worker` (Helm Release) | Stuck in `Init:0/1`, then `OOMKilled` (`Exit Code 137`), then killed at 4s by `StartupProbe` | **3A:** `db.port: 5433` (`5432`)<br/>**3B:** `limits.memory: 32Mi` (48 MiB allocation -> `192Mi`)<br/>**3C:** `startupProbe.failureThreshold: 2` (4s budget vs 6s warmup -> `10`) | Fix `helm-values/catalog-prod.yaml` and run `helm upgrade --install catalog-worker ./charts/catalog-worker -f helm-values/catalog-prod.yaml -n omnicore-prod` | InitContainer Gating, Linux Kernel cgroup OOM Killer (`137`) & Kubelet `startupProbe` Budgeting |
| **[INC-1604]** | `checkout-api` (`Deployment`, `ConfigMap`, `PDB`) | 2/3 pods `0/1 Running`, 3rd pod `Pending` on 2-node web tier; `/ready` fails (`:8080` & `127.0.0.1`) | **4A:** Hard `requiredDuringSchedulingIgnoredDuringExecution` anti-affinity on 2 web nodes (`preferred`)<br/>**4B:** `readinessProbe.port: 8080` (`8000`)<br/>**4C:** Inline `env` `CATALOG_HOST: 127.0.0.1` overrides `envFrom` | Fix `manifests/30-checkout-api.yaml` and run `kubectl apply -f manifests/30-checkout-api.yaml` | Hard vs Soft `podAntiAffinity`, Readiness Probe Port & `env` vs `envFrom` Precedence |
| **[INC-1605]** | `checkout-api-hpa` (`HPA`) & `Service/checkout-api` | HPA `<unknown>/70%` (`REPLICAS: 0`); `Service/checkout-api` has `Endpoints: <none>` | **5A:** HPA `scaleTargetRef.name: checkout-engine` (`checkout-api`) & missing `requests.cpu: 100m`<br/>**5B:** Extra selector `tier: checkout-core` & `targetPort: 8080` (`8000`) | Add `requests.cpu: 100m` in `30-checkout-api.yaml`, fix `40-scaling-and-service.yaml`, and run `kubectl apply` | HPA Resource Utilization Formula (`requests.cpu`) & EndpointSlice Label Matching |
| **[INC-1606]** | `node-telemetry` (`DaemonSet`) | `DESIRED: 2` (missing Node-3) and pods crashing in `CrashLoopBackOff` (`Read-only file system`) | **6A:** Toleration `key: role` (`workload`)<br/>**6B:** VolumeMount `readOnly: true` (`false`) | Fix `manifests/50-daemonset.yaml` and run `kubectl apply -f manifests/50-daemonset.yaml` | DaemonSet Taint Toleration Key Matching & Linux VFS Read-Only Mounts |
| **[INC-1607]** | `omni-gateway` (Helm Release) & `omni-ingress` (`Ingress`) | Port `80` `Connection refused`, then `/api/v1/checkout` `403 Forbidden`; Ingress class/port mismatch | **7A:** `service.targetPort: 8081` (`8080`)<br/>**7B:** `gateway.authToken: legacy-invalid` (`omnicore-verified`) + `subPath` reload<br/>**7C:** Ingress `ingressClassName: nginx-legacy` (`edge-ingress`) & port `8080` (`80`) | Fix `helm-values/gateway-prod.yaml` & `manifests/60-ingress.yaml`, run `helm upgrade`, `rollout restart`, and `kubectl apply` | L4 Service TargetPort, L7 Header Auth, Kubelet `subPath` Inode Immutability & Ingress Binding |

---

## 🔧 Step-by-Step Deep-Dive Remediation

---

### [INC-1601] Stateful Database Scheduling, Ext4 `lost+found` & Redis Service Port (`manifests/10-stateful-data.yaml`)

#### 1. 🧠 Diagnostic Mindset
1. **Fault 1A (Taint Effect Mismatch & `WaitForFirstConsumer` PVC):** `Node-3` has taint `workload=database:NoSchedule`, but `StatefulSet/omnicore-db` has toleration `effect: NoExecute`. Because Kubernetes requires an exact `effect` match, `omnicore-db-0` remains `Pending`, and the `oci-bv` PVC (`WaitForFirstConsumer`) also waits in `Pending`.
2. **Fault 1B (Ext4 `lost+found` & Missing `subPath: pgdata`):** Once scheduled, a newly formatted `oci-bv` ext4 block volume contains a `lost+found` directory at its root. Mounting the volume directly at `/var/lib/postgresql/data` without `subPath: pgdata` causes PostgreSQL `initdb` to abort (`directory "/var/lib/postgresql/data" exists but is not empty`).
3. **Fault 1C (Redis Service TargetPort):** `Deployment/omnicore-redis` listens on `6379`, but `Service/omnicore-redis` forwards `port: 6379` to `targetPort: 6380`.

#### 2. 🛠️ Resolution
```diff
--- a/manifests/10-stateful-data.yaml
+++ b/manifests/10-stateful-data.yaml
@@ -54,7 +54,7 @@ spec:
         - key: workload
           operator: Equal
           value: database
-          effect: NoExecute
+          effect: NoSchedule
       containers:
         - name: postgres
           image: docker.io/library/postgres:16-alpine
@@ -103,6 +103,7 @@ spec:
           volumeMounts:
             - name: data
               mountPath: /var/lib/postgresql/data
+              subPath: pgdata
   volumeClaimTemplates:
     - metadata:
         name: data
@@ -126,7 +127,7 @@ spec:
   ports:
     - name: redis
       port: 6379
-      targetPort: 6380
+      targetPort: 6379
       protocol: TCP
   selector:
     app.kubernetes.io/name: omnicore-redis
```

Apply and recreate `omnicore-db-0`:
```bash
kubectl apply -f manifests/10-stateful-data.yaml
kubectl delete pod omnicore-db-0 -n omnicore-prod
kubectl wait --for=condition=ready pod/omnicore-db-0 -n omnicore-prod --timeout=90s
kubectl exec -n omnicore-prod deploy/omnicore-redis -- redis-cli -h omnicore-redis -p 6379 ping
```

---

### [INC-1602] Schema Migrator Job & State Heartbeat CronJob Failure (`manifests/20-batch-jobs.yaml`)

#### 1. 🛠️ Resolution
Fix `PGHOST: "omnicore-db"`, `secretKeyRef.key: db-password`, `suspend: false`, and `-h omnicore-redis`:

```diff
--- a/manifests/20-batch-jobs.yaml
+++ b/manifests/20-batch-jobs.yaml
@@ -22,7 +22,7 @@ spec:
           imagePullPolicy: IfNotPresent
           env:
             - name: PGHOST
-              value: "omnicore-postgres"
+              value: "omnicore-db"
             - name: PGPORT
               value: "5432"
             - name: PGUSER
@@ -33,7 +33,7 @@ spec:
               valueFrom:
                 secretKeyRef:
                   name: omnicore-db-secret
-                  key: postgres-pass
+                  key: db-password
           command:
             - sh
             - -c
@@ -65,7 +65,7 @@ metadata:
     app.kubernetes.io/part-of: omnicore
 spec:
   schedule: "*/2 * * * *"
-  suspend: true
+  suspend: false
   concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 2
   failedJobsHistoryLimit: 2
@@ -85,4 +85,4 @@ spec:
               command:
                 - sh
                 - -c
-                - "redis-cli -h redis-master -p 6379 SET omnicore:cluster:heartbeat ONLINE && redis-cli -h redis-master -p 6379 INCR omnicore:cluster:ticks && echo 'Cluster heartbeat recorded.'"
+                - "redis-cli -h omnicore-redis -p 6379 SET omnicore:cluster:heartbeat ONLINE && redis-cli -h omnicore-redis -p 6379 INCR omnicore:cluster:ticks && echo 'Cluster heartbeat recorded.'"
```

Recreate the immutable Job and verify:
```bash
kubectl replace --force -f manifests/20-batch-jobs.yaml
kubectl wait --for=condition=complete job/schema-migrator -n omnicore-prod --timeout=45s
kubectl exec -n omnicore-prod omnicore-db-0 -- psql -U omni_admin -d omnicore_ledger -tAc "SELECT count(*) FROM ledger_accounts;"
kubectl create job --from=cronjob/state-heartbeat manual-heartbeat -n omnicore-prod && kubectl wait --for=condition=complete job/manual-heartbeat -n omnicore-prod --timeout=30s
```

---

### [INC-1603] Catalog Worker `Init:0/1`, `OOMKilled` (`137`) & StartupProbe Failure (`helm-values/catalog-prod.yaml`)

#### 1. 🛠️ Resolution
```diff
--- a/helm-values/catalog-prod.yaml
+++ b/helm-values/catalog-prod.yaml
@@ -2,7 +2,7 @@ replicaCount: 1
 
 db:
   host: "omnicore-db"
-  port: 5433
+  port: 5432
 
 redis:
   host: "omnicore-redis"
@@ -12,11 +12,11 @@ startupProbe:
   path: "/healthz"
   periodSeconds: 2
   timeoutSeconds: 2
-  failureThreshold: 2
+  failureThreshold: 10
 
 resources:
   requests:
     cpu: 50m
-    memory: 16Mi
+    memory: 64Mi
   limits:
     cpu: 250m
-    memory: 32Mi
+    memory: 192Mi
```

Upgrade and verify:
```bash
helm upgrade --install catalog-worker ./charts/catalog-worker -f helm-values/catalog-prod.yaml -n omnicore-prod
kubectl rollout status deploy/catalog-worker -n omnicore-prod --timeout=60s
```

---

### [INC-1604] & [INC-1605] Checkout API Anti-Affinity, Probe Port, Env Precedence, HPA & Service (`manifests/30-checkout-api.yaml` & `manifests/40-scaling-and-service.yaml`)

#### 1. 🛠️ Resolution
Update `manifests/30-checkout-api.yaml` (change `requiredDuringSchedulingIgnoredDuringExecution` to `preferredDuringSchedulingIgnoredDuringExecution`, remove overriding `env:` block, fix `readinessProbe.port: 8000`, and add `resources.requests.cpu: 100m`):

```diff
--- a/manifests/30-checkout-api.yaml
+++ b/manifests/30-checkout-api.yaml
@@ -117,11 +117,13 @@ spec:
         tier: web
       affinity:
         podAntiAffinity:
-          requiredDuringSchedulingIgnoredDuringExecution:
-            - labelSelector:
-                matchLabels:
-                  app.kubernetes.io/name: checkout-api
-              topologyKey: kubernetes.io/hostname
+          preferredDuringSchedulingIgnoredDuringExecution:
+            - weight: 100
+              podAffinityTerm:
+                labelSelector:
+                  matchLabels:
+                    app.kubernetes.io/name: checkout-api
+                topologyKey: kubernetes.io/hostname
       containers:
         - name: checkout-api
           image: docker.io/library/python:3.12-slim
@@ -137,9 +139,6 @@ spec:
           envFrom:
             - configMapRef:
                 name: checkout-api-config
-          env:
-            - name: CATALOG_HOST
-              value: "127.0.0.1"
           livenessProbe:
             httpGet:
               path: /healthz
@@ -151,12 +150,13 @@ spec:
           readinessProbe:
             httpGet:
               path: /ready
-              port: 8080
+              port: 8000
             initialDelaySeconds: 3
             periodSeconds: 5
             timeoutSeconds: 2
             failureThreshold: 3
           resources:
             requests:
+              cpu: 100m
               memory: 64Mi
             limits:
```

Update `manifests/40-scaling-and-service.yaml`:
```diff
--- a/manifests/40-scaling-and-service.yaml
+++ b/manifests/40-scaling-and-service.yaml
@@ -10,7 +10,7 @@ spec:
   scaleTargetRef:
     apiVersion: apps/v1
     kind: Deployment
-    name: checkout-engine
+    name: checkout-api
   minReplicas: 3
   maxReplicas: 6
@@ -31,8 +31,7 @@ spec:
   ports:
     - name: http
       port: 8000
-      targetPort: 8080
+      targetPort: 8000
       protocol: TCP
   selector:
     app.kubernetes.io/name: checkout-api
-    tier: checkout-core
```

Apply and verify:
```bash
kubectl apply -f manifests/30-checkout-api.yaml -f manifests/40-scaling-and-service.yaml
kubectl rollout status deploy/checkout-api -n omnicore-prod --timeout=60s
kubectl get endpoints checkout-api -n omnicore-prod
kubectl get hpa checkout-api-hpa -n omnicore-prod
```

---

### [INC-1606] Node Telemetry DaemonSet Taint Key & Read-Only VFS Crash (`manifests/50-daemonset.yaml`)

#### 1. 🛠️ Resolution
```diff
--- a/manifests/50-daemonset.yaml
+++ b/manifests/50-daemonset.yaml
@@ -18,7 +18,7 @@ spec:
         app.kubernetes.io/part-of: omnicore
     spec:
       tolerations:
-        - key: role
+        - key: workload
           operator: Equal
           value: database
           effect: NoSchedule
@@ -45,7 +45,7 @@ spec:
           volumeMounts:
             - name: telemetry-logs
               mountPath: /var/log/omnicore-node
-              readOnly: true
+              readOnly: false
       volumes:
```

Apply and verify:
```bash
kubectl apply -f manifests/50-daemonset.yaml
kubectl rollout status ds/node-telemetry -n omnicore-prod --timeout=45s
kubectl get ds node-telemetry -n omnicore-prod
```

---

### [INC-1607] Edge Gateway TargetPort, `403 Forbidden` (`subPath` Reload) & Ingress Binding (`helm-values/gateway-prod.yaml` & `manifests/60-ingress.yaml`)

#### 1. 🛠️ Resolution
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
   nodePort: 30086
   externalTrafficPolicy: Cluster
 
@@ -12,4 +12,4 @@ upstream:
   port: 8000
 
 gateway:
-  authToken: "legacy-invalid"
+  authToken: "omnicore-verified"
```

Update `manifests/60-ingress.yaml`:
```diff
--- a/manifests/60-ingress.yaml
+++ b/manifests/60-ingress.yaml
@@ -7,7 +7,7 @@ metadata:
     app.kubernetes.io/name: omni-ingress
     app.kubernetes.io/part-of: omnicore
 spec:
-  ingressClassName: nginx-legacy
+  ingressClassName: edge-ingress
   rules:
     - host: omnicore.local
       http:
@@ -17,4 +17,4 @@ spec:
             backend:
               service:
                 name: omni-gateway
                 port:
-                  number: 8080
+                  number: 80
```

Upgrade, restart `omni-gateway` (for `subPath` reload), and verify via External LoadBalancer IP:
```bash
helm upgrade --install omni-gateway ./charts/omni-gateway -f helm-values/gateway-prod.yaml -n omnicore-prod
kubectl rollout restart deploy/omni-gateway -n omnicore-prod
kubectl rollout status deploy/omni-gateway -n omnicore-prod --timeout=45s
kubectl apply -f manifests/60-ingress.yaml

LB_IP=$(kubectl get svc omni-gateway -n omnicore-prod -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -i -sS -H "Host: omnicore.local" "http://${LB_IP}/api/v1/checkout"
```

---

<br>

---

# 🇹🇷 Türkçe Versiyon

# 🛠️ SRE Post-Mortem ve Çözüm Rehberi: Lab 16 (Büyük Final / Genel Tekrar) — OmniCore Platformu (`omnicore-prod`)

Bu doküman, Oracle Cloud Kubernetes Engine (OKE) üzerinde `omnicore-prod` namespace'inde çalışan kurumsal sipariş işleme, mutabakat defteri, gerçek zamanlı katalog indeksleme, düğüm telemetrisi ve L7 API ağ geçidi platformu **OmniCore**'da yaşanan 7 katmanlı zincirleme kesintinin **Principal SRE Kök Neden Analizi (RCA) ve Çözüm Rehberi**dir.

---

## 🔧 Adım Adım Kök Neden Analizi ve Çözüm Özeti

1. **[INC-1601] (`manifests/10-stateful-data.yaml`):**
   * `omnicore-db` StatefulSet içinde toleration `effect: NoExecute` -> `effect: NoSchedule` yapılır, `/var/lib/postgresql/data` volumeMount altına `subPath: pgdata` eklenir ve `Service/omnicore-redis` içindeki `targetPort: 6380` -> `6379` yapılır.
   * Uygulandıktan sonra `kubectl delete pod omnicore-db-0 -n omnicore-prod` komutuyla pod yeniden oluşturulur.
2. **[INC-1602] (`manifests/20-batch-jobs.yaml`):**
   * `Job/schema-migrator` içinde `PGHOST: "omnicore-db"` ve `secretKeyRef.key: db-password` yapılır.
   * `CronJob/state-heartbeat` içinde `suspend: false` ve `-h omnicore-redis` yapılır; `kubectl replace --force -f manifests/20-batch-jobs.yaml` ile uygulanır.
3. **[INC-1603] (`helm-values/catalog-prod.yaml`):**
   * `db.port: 5432`, `startupProbe.failureThreshold: 10`, `resources.requests.memory: 64Mi` ve `resources.limits.memory: 192Mi` yapılarak `helm upgrade` çalıştırılır.
4. **[INC-1604] (`manifests/30-checkout-api.yaml`):**
   * `requiredDuringSchedulingIgnoredDuringExecution` kuralı `preferredDuringSchedulingIgnoredDuringExecution` yapılır, `env:` altındaki `CATALOG_HOST: "127.0.0.1"` satırı silinir, `readinessProbe.port: 8000` yapılır ve `resources.requests.cpu: 100m` eklenir.
5. **[INC-1605] (`manifests/40-scaling-and-service.yaml`):**
   * `HPA` içinde `scaleTargetRef.name: checkout-api` yapılır; `Service/checkout-api` içinde `targetPort: 8000` yapılır ve `tier: checkout-core` seçicisi silinir.
6. **[INC-1606] (`manifests/50-daemonset.yaml`):**
   * `DaemonSet/node-telemetry` içinde toleration `key: workload` ve volumeMount `readOnly: false` yapılır.
7. **[INC-1607] (`helm-values/gateway-prod.yaml` & `manifests/60-ingress.yaml`):**
   * `service.targetPort: 8080` ve `gateway.authToken: "omnicore-verified"` yapılıp `helm upgrade` ve `kubectl rollout restart deploy/omni-gateway -n omnicore-prod` çalıştırılır.
   * `Ingress/omni-ingress` içinde `ingressClassName: edge-ingress` ve port `80` yapılır.
