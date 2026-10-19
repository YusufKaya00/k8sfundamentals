# 🇬🇧 English Version

# 🛠️ SRE Post-Mortem & Remediation Guide: Lab 15 — QuantFlow Platform (`quantflow-prod`)

This document serves as the authoritative **Principal Site Reliability Engineering (SRE) Post-Mortem & Incident Remediation Runbook** for the cascading outage across **QuantFlow**, our enterprise algorithmic risk evaluation, orderbook liquidity calculation, and L7 edge API gateway platform running in the `quantflow-prod` namespace on Oracle Cloud Kubernetes Engine (OKE).

> [!NOTE]
> **Strict Bottom-Up Dependency Chain:**  
> QuantFlow is engineered with a linear, bottom-up dependency architecture (`Layer 0` -> `INC-1501` -> `INC-1502` -> `INC-1503` -> `INC-1504` -> `INC-1505`). Each layer depends directly on the stability of the layer beneath it. Always resolve and verify tickets in sequential order.

---

## 📑 Executive Incident Resolution Matrix

| Ticket ID | Impacted Component | Observed Symptom | Root Cause (Multi-Stage Faults) | Remediation Summary | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1501]** | `ledger-bootstrap` (`Job`) & `market-snapshot` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` & Redis port connection failure | **1A:** `secretKeyRef.key: postgres-pass` (actual: `db-password`) & `PGHOST: quant-postgres` (actual: `quant-db`)<br/>**1B:** `suspend: true` & `-p 6380` (actual port: `6379`) | Fix `manifests/20-batch-jobs.yaml` and run `kubectl replace --force -f manifests/20-batch-jobs.yaml` | Kubelet Pre-Start Secret Resolution, `Job` Spec Immutability & `CronJob` Controller Loop | `P1 - Blocker` |
| **[INC-1502]** | `liquidity-worker` (Helm Release) | Stuck in `Init:0/1`; then `OOMKilled` (`Exit Code 137`); then periodic `Liveness probe failed (HTTP 404)` restarts | **2A:** `redis.host: "quant-cache"` instead of `"quant-redis"`<br/>**2B:** `limits.memory: "32Mi"` (48 MiB matrix allocation -> set `"192Mi"`)<br/>**2C:** `livenessProbe.path: "/livez"` instead of `"/healthz"` | Fix `helm-values/liquidity-prod.yaml` and run `helm upgrade --install liquidity-worker ./charts/liquidity-worker -f helm-values/liquidity-prod.yaml -n quantflow-prod` | InitContainer Gating, Linux Kernel cgroup OOM Killer (`137`) & Kubelet Liveness Probe Lifecycle | `P1 - Blocker` |
| **[INC-1503]** | `risk-engine` (`Deployment`, `ConfigMap`, `PDB`, `HPA`) | `Running` (`0/1 Ready`), `/ready` returns `HTTP 503`; `HPA` shows `<unknown>/70%` and `0` replicas | **3A:** Inline `env` `LIQUIDITY_URL: "http://127.0.0.1:9095/healthz"` overrides `envFrom` (`ConfigMap`)<br/>**3B:** `DB_PORT: "5433"` instead of `"5432"`<br/>**3C:** HPA `scaleTargetRef.name: risk-api` (actual: `risk-engine`) & missing `requests.cpu` | Fix `manifests/30-risk-engine.yaml`, run `kubectl apply`, and `kubectl rollout restart deploy/risk-engine` | Kubernetes `env` vs `envFrom` Precedence, Readiness Gate & HPA Resource Metric Calculation | `P1 - Blocker` |
| **[INC-1504]** | `Service/risk-engine` & `DaemonSet/latency-probe` | Service has `Endpoints: <none>`; DaemonSet `DESIRED: 2` (missing Node-3) and crashing in `CrashLoopBackOff` (`Read-only file system`) | **4A:** Service has extra selector `tier: risk-core` & `targetPort: 8080` (`8000`)<br/>**4B:** Toleration `key: role` (`workload`)<br/>**4C:** VolumeMount `readOnly: true` (`false`) | Fix `manifests/40-network-and-daemon.yaml` and run `kubectl apply -f manifests/40-network-and-daemon.yaml` | EndpointSlice Label Matching, Scheduler Taint Key Matching & Linux VFS Read-Only Mounts | `P1 - Blocker` |
| **[INC-1505]** | `quant-gateway` (Helm Release) & `quant-ingress` (`Ingress`) | `Connection refused` on port `80`; then `403 Forbidden` on `/api/v1/risk/evaluate`; Ingress class/port mismatch | **5A:** `service.targetPort: 8081` (`8080`)<br/>**5B:** `gateway.signatureToken: "legacy-invalid"` (`"quant-verified"`) + `subPath` reload<br/>**5C:** Ingress `ingressClassName: nginx-legacy` (`edge-ingress`) & port `8080` (`80`) | Fix `helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml`, run `helm upgrade`, `rollout restart`, and `kubectl apply` | L4 Service TargetPort Mapping, L7 Header Auth, Kubelet `subPath` Mount Immutability & Ingress Binding | `P1 - Blocker` |

---

## 🔧 Deep-Dive Incident Analysis & Remediation

---

### [INC-1501] Ledger Bootstrap Job & Market Snapshot CronJob Failure (`manifests/20-batch-jobs.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **`CreateContainerConfigError` Means Pre-Start Failure:**
  When `kubectl get pods` shows `CreateContainerConfigError`, the container runtime (`CRI-O`) has not even started the process yet. Kubelet failed during `GenerateRunContainerOptions` while trying to resolve a `Secret` or `ConfigMap` key referenced by the pod spec.
* **Three Faults in Batch Layer (`manifests/20-batch-jobs.yaml`):**
  1. **Fault 1A (Secret Key & DB Host Mismatch):** `Job/ledger-bootstrap` references `secretKeyRef.key: postgres-pass` in `Secret/quant-db-secret` (actual key is `db-password`) and sets `PGHOST: "quant-postgres"` (actual Service is `quant-db`).
  2. **Why `kubectl apply` Fails on Jobs (Immutability):** Once a `Job` is created, its `spec.template` is immutable (`field is immutable`). You must recreate the Job via `kubectl replace --force -f manifests/20-batch-jobs.yaml`.
  3. **Fault 1B (Suspended CronJob & Redis Port Mismatch):** `CronJob/market-snapshot` has `suspend: true` and connects to Redis using `-p 6380` instead of `-p 6379`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect Job, CronJob, and pod status
kubectl get job,cronjob -n quantflow-prod
kubectl get pods -n quantflow-prod -l app.kubernetes.io/name=ledger-bootstrap

# 2. Inspect Kubelet Events on ledger-bootstrap pod
kubectl describe pod -n quantflow-prod -l app.kubernetes.io/name=ledger-bootstrap | grep -A 8 "Events:"
# Output reveals: Error: key "postgres-pass" not found in secret "quantflow-prod/quant-db-secret"

# 3. Check actual keys in quant-db-secret and Service names in quantflow-prod
kubectl get secret quant-db-secret -n quantflow-prod -o jsonpath='{.data}' && echo ""
kubectl get svc -n quantflow-prod
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Update `manifests/20-batch-jobs.yaml`:
  1. Change `PGHOST` from `"quant-postgres"` to `"quant-db"`.
  2. Change `secretKeyRef.key` from `postgres-pass` to `db-password`.
  3. In `CronJob/market-snapshot`, change `suspend: true` to `suspend: false` and change `-p 6380` to `-p 6379`.

```diff
--- a/manifests/20-batch-jobs.yaml
+++ b/manifests/20-batch-jobs.yaml
@@ -22,7 +22,7 @@ spec:
           imagePullPolicy: IfNotPresent
           env:
             - name: PGHOST
-              value: "quant-postgres"
+              value: "quant-db"
             - name: PGPORT
               value: "5432"
             - name: PGUSER
@@ -33,7 +33,7 @@ spec:
               valueFrom:
                 secretKeyRef:
                   name: quant-db-secret
-                  key: postgres-pass
+                  key: db-password
           command:
             - sh
             - -c
@@ -65,7 +65,7 @@ metadata:
     app.kubernetes.io/part-of: quantflow
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
-                - "redis-cli -h quant-redis -p 6380 SET quant:market:status ACTIVE && redis-cli -h quant-redis -p 6380 INCR quant:market:tick && echo 'Market snapshot synced successfully.'"
+                - "redis-cli -h quant-redis -p 6379 SET quant:market:status ACTIVE && redis-cli -h quant-redis -p 6379 INCR quant:market:tick && echo 'Market snapshot synced successfully.'"
```

* **Step 2:** Recreate the immutable Job and update the CronJob:
```bash
kubectl replace --force -f manifests/20-batch-jobs.yaml
```

* **Step 3:** Verify completion:
```bash
kubectl wait --for=condition=complete job/ledger-bootstrap -n quantflow-prod --timeout=45s
kubectl exec -n quantflow-prod quant-db-0 -- psql -U quant_admin -d quant_ledger -tAc "SELECT count(*) FROM risk_limits;"
# Expected: 4

kubectl create job --from=cronjob/market-snapshot manual-snapshot -n quantflow-prod && kubectl wait --for=condition=complete job/manual-snapshot -n quantflow-prod --timeout=30s
kubectl exec -n quantflow-prod deploy/quant-redis -- redis-cli GET quant:market:status
# Expected: ACTIVE
```

#### 4. 💡 SRE Production Wisdom
* Always use `kubectl replace --force` (or GitOps `Replace=true` sync options) when updating Kubernetes `batch/v1` `Job` templates because `spec.template` is immutable after creation.

---

### [INC-1502] Liquidity Worker Stuck in `Init:0/1`, `OOMKilled` (`137`) & Probe Restarts (`helm-values/liquidity-prod.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Three-Stage Failure inside `liquidity-worker`:**
  1. **Fault 2A (`Init:0/1` Deadlock):** `helm-values/liquidity-prod.yaml` overrides `redis.host: "quant-cache"`, while the actual Redis Service is `"quant-redis"`. The `wait-for-redis` InitContainer loops forever waiting on `quant-cache:6379`.
  2. **Fault 2B (`OOMKilled` / `Exit Code 137`):** Once `redis.host` is fixed to `"quant-redis"`, the main `worker` container starts and immediately allocates a **48 MiB** in-memory orderbook liquidity matrix (`bytearray(48 * 1024 * 1024)`). Because `helm-values/liquidity-prod.yaml` sets `resources.limits.memory: 32Mi`, the Linux kernel cgroup memory controller immediately sends `SIGKILL` (`Exit Code 137`, `Reason: OOMKilled`).
  3. **Fault 2C (`LivenessProbe` Path Mismatch):** Once `limits.memory` is raised to `192Mi`, the container starts cleanly, but `livenessProbe.path` is set to `"/livez"` while `worker.py` only serves `"/healthz"`. Kubelet receives `HTTP 404 Not Found` and restarts the container every ~13 seconds.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect initContainer logs
kubectl logs -n quantflow-prod deploy/liquidity-worker -c wait-for-redis
# Output: Waiting for Redis at quant-cache:6379...

# 2. Compare worker.py memory allocation & endpoints against liquidity-prod.yaml
cat charts/liquidity-worker/templates/configmap.yaml
cat helm-values/liquidity-prod.yaml
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `helm-values/liquidity-prod.yaml` to fix `redis.host`, `livenessProbe.path`, and `resources`:

```diff
--- a/helm-values/liquidity-prod.yaml
+++ b/helm-values/liquidity-prod.yaml
@@ -1,11 +1,11 @@
 replicaCount: 1
 
 redis:
-  host: "quant-cache"
+  host: "quant-redis"
   port: 6379
 
 livenessProbe:
-  path: "/livez"
+  path: "/healthz"
   initialDelaySeconds: 5
   periodSeconds: 4
   timeoutSeconds: 2
@@ -19,7 +19,7 @@ readinessProbe:
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

* **Step 2:** Upgrade the Helm release and verify rollout:
```bash
helm upgrade --install liquidity-worker ./charts/liquidity-worker -f helm-values/liquidity-prod.yaml -n quantflow-prod
kubectl rollout status deploy/liquidity-worker -n quantflow-prod --timeout=45s
kubectl exec -n quantflow-prod deploy/quant-redis -- wget -qO- http://liquidity-worker:9095/healthz
# Expected: {"status": "healthy", "service": "liquidity-worker", "matrix_buffer_mib": 48, "redis": "quant-redis:6379"}
```

#### 4. 💡 SRE Production Wisdom
* **Exit Code 137 (`128 + 9` = `SIGKILL`):** Always inspect `Last State: Terminated (Reason: OOMKilled)` in `kubectl describe pod` rather than only looking at application stdout logs, because kernel OOM kills happen instantaneously without giving the Python interpreter a chance to log an `OutOfMemory` exception.

---

### [INC-1503] Risk Engine Readiness Failure (`0/1 Ready`) & HPA Metric Starvation (`manifests/30-risk-engine.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Three Faults in `manifests/30-risk-engine.yaml`:**
  1. **Fault 3A (`env` vs `envFrom` Precedence Trap):** `ConfigMap/risk-engine-config` defines `LIQUIDITY_URL: "http://liquidity-worker:9095/healthz"`, which is imported via `envFrom`. However, `Deployment/risk-engine` also defines an explicit `env:` block with `LIQUIDITY_URL: "http://127.0.0.1:9095/healthz"`. In Kubernetes, **explicit `env` definitions always override `envFrom` values**! Thus `risk-engine` tries to connect to `127.0.0.1:9095` and fails `/ready` with `503`.
  2. **Fault 3B (`ConfigMap` Database Port Mismatch):** `ConfigMap/risk-engine-config` sets `DB_PORT: "5433"` instead of `"5432"`.
  3. **Fault 3C (HPA `scaleTargetRef` Typo & Missing CPU Request):** `HorizontalPodAutoscaler/risk-engine-hpa` targets `Deployment/risk-api` instead of `Deployment/risk-engine`, and `Deployment/risk-engine` is missing `resources.requests.cpu: 100m`, preventing the HPA controller from calculating CPU utilization percentage (`<unknown>/70%`).

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect effective environment variables inside risk-engine
kubectl exec -n quantflow-prod deploy/risk-engine -- env | grep -E "DB_|REDIS_|LIQUIDITY_"
# Output reveals:
# DB_PORT=5433
# LIQUIDITY_URL=http://127.0.0.1:9095/healthz

# 2. Inspect HPA status and events
kubectl describe hpa risk-engine-hpa -n quantflow-prod
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `manifests/30-risk-engine.yaml`:
  1. In `ConfigMap/risk-engine-config`, change `DB_PORT: "5433"` to `"5432"`.
  2. In `Deployment/risk-engine`, remove the overriding `env:` block (or set `LIQUIDITY_URL` to `"http://liquidity-worker:9095/healthz"`) and add `cpu: 100m` under `resources.requests`.
  3. In `HorizontalPodAutoscaler/risk-engine-hpa`, change `scaleTargetRef.name` from `risk-api` to `risk-engine`.

```diff
--- a/manifests/30-risk-engine.yaml
+++ b/manifests/30-risk-engine.yaml
@@ -9,7 +9,7 @@ metadata:
 data:
   PORT: "8000"
   DB_HOST: "quant-db"
-  DB_PORT: "5433"
+  DB_PORT: "5432"
   REDIS_HOST: "quant-redis"
   REDIS_PORT: "6379"
   LIQUIDITY_URL: "http://liquidity-worker:9095/healthz"
@@ -132,9 +132,6 @@ spec:
           envFrom:
             - configMapRef:
                 name: risk-engine-config
-          env:
-            - name: LIQUIDITY_URL
-              value: "http://127.0.0.1:9095/healthz"
           livenessProbe:
             httpGet:
               path: /healthz
@@ -152,6 +149,7 @@ spec:
             failureThreshold: 3
           resources:
             requests:
+              cpu: 100m
               memory: 64Mi
             limits:
               cpu: 250m
@@ -188,7 +186,7 @@ spec:
   scaleTargetRef:
     apiVersion: apps/v1
     kind: Deployment
-    name: risk-api
+    name: risk-engine
   minReplicas: 2
   maxReplicas: 5
```

* **Step 2:** Apply the updated manifest and restart `risk-engine` so the updated ConfigMap `DB_PORT` is loaded:
```bash
kubectl apply -f manifests/30-risk-engine.yaml
kubectl rollout restart deploy/risk-engine -n quantflow-prod
kubectl rollout status deploy/risk-engine -n quantflow-prod --timeout=45s
kubectl get pods,pdb,hpa -n quantflow-prod
```

---

### [INC-1504] Risk Engine Service Blackhole & Node Latency DaemonSet Failure (`manifests/40-network-and-daemon.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Fault 4A (`Service/risk-engine` Selector & TargetPort Mismatch):**
  `Service/risk-engine` specifies `selector: { app.kubernetes.io/name: risk-engine, tier: risk-core }` and `targetPort: 8080`. Because `risk-engine` pods do not carry `tier: risk-core`, `Endpoints/risk-engine` is `<none>`, and `risk-engine` listens on port `8000`, not `8080`.
* **Fault 4B & 4C (`DaemonSet/latency-probe` Toleration Key & Read-Only Mount):**
  `Node-3` has taint `workload=database:NoSchedule`, but `latency-probe` specifies `key: role` instead of `key: workload` (`DESIRED: 2` instead of `3`). Furthermore, its `/var/log/quant-probe` volumeMount has `readOnly: true`, causing `echo ... >> /var/log/quant-probe/latency.log` to fail with `Read-only file system` and crash (`CrashLoopBackOff`).

#### 2. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `manifests/40-network-and-daemon.yaml`:
  1. In `Service/risk-engine`, change `targetPort: 8080` to `8000` and remove `tier: risk-core` from `selector`.
  2. In `DaemonSet/latency-probe`, change toleration `key: role` to `key: workload` and change `readOnly: true` to `readOnly: false`.

```diff
--- a/manifests/40-network-and-daemon.yaml
+++ b/manifests/40-network-and-daemon.yaml
@@ -11,10 +11,9 @@ spec:
   ports:
     - name: http
       port: 8000
-      targetPort: 8080
+      targetPort: 8000
       protocol: TCP
   selector:
     app.kubernetes.io/name: risk-engine
-    tier: risk-core
 ---
 apiVersion: apps/v1
@@ -34,7 +33,7 @@ spec:
         app.kubernetes.io/part-of: quantflow
     spec:
       tolerations:
-        - key: role
+        - key: workload
           operator: Equal
           value: database
           effect: NoSchedule
@@ -60,7 +59,7 @@ spec:
           volumeMounts:
             - name: probe-logs
               mountPath: /var/log/quant-probe
-              readOnly: true
+              readOnly: false
       volumes:
         - name: probe-logs
           emptyDir: {}
```

* **Step 2:** Apply and verify:
```bash
kubectl apply -f manifests/40-network-and-daemon.yaml
kubectl get endpoints risk-engine -n quantflow-prod
kubectl rollout status ds/latency-probe -n quantflow-prod --timeout=45s
kubectl get ds latency-probe -n quantflow-prod
# Expected: DESIRED: 3, CURRENT: 3, READY: 3
```

---

### [INC-1505] Edge Gateway TargetPort, `403 Forbidden` & Ingress Misalignment (`helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Three Faults in Layer 5:**
  1. **Fault 5A (`Service/quant-gateway` TargetPort Mismatch):** `helm-values/gateway-prod.yaml` sets `service.targetPort: 8081`, while the Nginx container listens on port `8080`. Requests to Service port `80` fail with `Connection refused`.
  2. **Fault 5B (`X-Quant-Signature` Header Mismatch & `subPath` ConfigMap Reload):** `helm-values/gateway-prod.yaml` sets `gateway.signatureToken: "legacy-invalid"`, whereas `risk-engine` requires `"quant-verified"`. Furthermore, because `nginx.conf` is mounted using `subPath: nginx.conf`, Kubelet does not hot-reload the file after `helm upgrade` — you must run `kubectl rollout restart deploy/quant-gateway -n quantflow-prod`.
  3. **Fault 5C (`Ingress/quant-ingress` Class & Port Mismatch):** `manifests/50-ingress.yaml` uses `ingressClassName: nginx-legacy` (cluster IngressClass is `edge-ingress`) and backend port `8080` (Service `quant-gateway` port is `80`).

#### 2. 🛠️ Step-by-Step Resolution
* **Step 1:** Update `helm-values/gateway-prod.yaml`:

```diff
--- a/helm-values/gateway-prod.yaml
+++ b/helm-values/gateway-prod.yaml
@@ -3,7 +3,7 @@ replicaCount: 1
 service:
   type: LoadBalancer
   port: 80
-  targetPort: 8081
+  targetPort: 8080
   nodePort: 30085
   externalTrafficPolicy: Cluster
 
@@ -12,4 +12,4 @@ upstream:
   port: 8000
 
 gateway:
-  signatureToken: "legacy-invalid"
+  signatureToken: "quant-verified"
```

* **Step 2:** Update `manifests/50-ingress.yaml`:

```diff
--- a/manifests/50-ingress.yaml
+++ b/manifests/50-ingress.yaml
@@ -7,7 +7,7 @@ metadata:
     app.kubernetes.io/name: quant-ingress
     app.kubernetes.io/part-of: quantflow
 spec:
-  ingressClassName: nginx-legacy
+  ingressClassName: edge-ingress
   rules:
     - host: quant.local
       http:
@@ -17,4 +17,4 @@ spec:
             backend:
               service:
                 name: quant-gateway
                 port:
-                  number: 8080
+                  number: 80
```

* **Step 3:** Upgrade `quant-gateway`, restart the deployment to refresh the `subPath` mount, and apply `50-ingress.yaml`:
```bash
helm upgrade --install quant-gateway ./charts/quant-gateway -f helm-values/gateway-prod.yaml -n quantflow-prod
kubectl rollout restart deploy/quant-gateway -n quantflow-prod
kubectl rollout status deploy/quant-gateway -n quantflow-prod --timeout=45s
kubectl apply -f manifests/50-ingress.yaml
```

* **Step 4:** Run the end-to-end verification:
```bash
LB_IP=$(kubectl get svc quant-gateway -n quantflow-prod -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -i -sS "http://${LB_IP}/api/v1/risk/evaluate"
# Expected: HTTP/1.1 200 OK
# {"platform": "QuantFlow", "status": "RISK_APPROVED", "active_portfolios": ["PORTFOLIO-ALPHA", "PORTFOLIO-BETA", "PORTFOLIO-GAMMA", "PORTFOLIO-DELTA"], "liquidity_engine": "online"}
```

---

<br>

---

# 🇹🇷 Türkçe Versiyon

# 🛠️ SRE Post-Mortem ve Çözüm Rehberi: Lab 15 — QuantFlow Platformu (`quantflow-prod`)

Bu doküman, Oracle Cloud Kubernetes Engine (OKE) üzerinde `quantflow-prod` namespace'inde çalışan kurumsal algoritmik risk değerlendirme, emir defteri (orderbook) likidite matrisi ve L7 API ağ geçidi platformu **QuantFlow**'da yaşanan zincirleme kesintinin **Principal SRE Kök Neden Analizi (RCA) ve Çözüm Rehberi**dir.

---

## 📑 Yönetici Olay Çözüm Matrisi

| Bilet Kodu | Etkilenen Bileşen | Gözlemlenen Belirti (Semptom) | Kök Nedenler (Çok Aşamalı) | Çözüm Özeti | Kontrol Düzlemi & Çekirdek Mekanizması |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1501]** | `ledger-bootstrap` (`Job`) & `market-snapshot` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` ve Redis port hatası | **1A:** `secretKeyRef.key: postgres-pass` (doğrusu: `db-password`) ve `PGHOST: quant-postgres` (`quant-db`)<br/>**1B:** `suspend: true` ve `-p 6380` (`6379`) | `manifests/20-batch-jobs.yaml` dosyasını düzelt ve `kubectl replace --force -f manifests/20-batch-jobs.yaml` çalıştır | Kubelet Pre-Start Secret Doğrulaması, `Job` Spec Değişmezliği & `CronJob` Döngüsü |
| **[INC-1502]** | `liquidity-worker` (Helm Sürümü) | Önce `Init:0/1` takılması; ardından `OOMKilled` (`Exit Code 137`); sonrasında `Liveness probe failed (404)` | **2A:** `redis.host: "quant-cache"` (`"quant-redis"`)<br/>**2B:** `limits.memory: "32Mi"` (48 MiB matris -> `"192Mi"`)<br/>**2C:** `livenessProbe.path: "/livez"` (`"/healthz"`) | `helm-values/liquidity-prod.yaml` dosyasını düzelt ve `helm upgrade` çalıştır | InitContainer Kapısı, Linux Kernel cgroup OOM Killer (`137`) & Liveness Probe |
| **[INC-1503]** | `risk-engine` (`Deployment`, `ConfigMap`, `PDB`, `HPA`) | `Running` (`0/1 Ready`), `/ready` `HTTP 503` döner; `HPA` `<unknown>/70%` gösterir | **3A:** Deployment `env` içindeki `LIQUIDITY_URL: "http://127.0.0.1:9095/healthz"` tanımı `envFrom`'u eziyor<br/>**3B:** `DB_PORT: "5433"` (`"5432"`)<br/>**3C:** HPA `scaleTargetRef.name: risk-api` (`risk-engine`) & eksik `requests.cpu` | `manifests/30-risk-engine.yaml` dosyasını düzelt, `kubectl apply` ve `kubectl rollout restart deploy/risk-engine` çalıştır | `env` vs `envFrom` Öncelik Çakışması, Readiness Kapısı & HPA Metrik Hesaplaması |
| **[INC-1504]** | `Service/risk-engine` & `DaemonSet/latency-probe` | Serviste `Endpoints: <none>`; DaemonSet `DESIRED: 2` (Node-3 eksik) ve `CrashLoopBackOff` (`Read-only file system`) | **4A:** Fazladan `tier: risk-core` seçicisi & `targetPort: 8080` (`8000`)<br/>**4B:** Toleration `key: role` (`workload`)<br/>**4C:** VolumeMount `readOnly: true` (`false`) | `manifests/40-network-and-daemon.yaml` dosyasını düzelt ve `kubectl apply` çalıştır | EndpointSlice Etiket Eşleşmesi, Taint Anahtar Eşleşmesi & Linux VFS Salt Okunur Bağlama |
| **[INC-1505]** | `quant-gateway` (Helm Sürümü) & `quant-ingress` (`Ingress`) | Port `80` `Connection refused`; ardından `/api/v1/risk/evaluate` `403 Forbidden`; Ingress sınıf/port hatası | **5A:** `service.targetPort: 8081` (`8080`)<br/>**5B:** `gateway.signatureToken: "legacy-invalid"` (`"quant-verified"`) + `subPath` reload<br/>**5C:** Ingress `ingressClassName: nginx-legacy` (`edge-ingress`) & port `8080` (`80`) | `helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml` dosyalarını düzelt, `helm upgrade`, `rollout restart` ve `kubectl apply` çalıştır | L4 TargetPort Eşlemesi, L7 Başlık Doğrulaması, Kubelet `subPath` Kısıtı & Ingress Bağlama |

---

## 🔧 Adım Adım Kök Neden Analizi ve Çözüm Rehberi

### [INC-1501] Veritabanı Tohumlama Job'ı ve Market Snapshot CronJob Arızası (`manifests/20-batch-jobs.yaml`)
1. **Teşhis Mantığı:** `CreateContainerConfigError`, konteyner sürecinin henüz başlamadığını ve Kubelet'in `Secret/quant-db-secret` içinde `postgres-pass` anahtarını bulamadığını gösterir (gerçek anahtar: `db-password`). Ayrıca `PGHOST` değeri `"quant-postgres"` yerine `"quant-db"` olmalıdır. `CronJob/market-snapshot` ise `suspend: true` ile duraklatılmış ve Redis portunu `6380` (`6379` yerine) olarak kullanmaktadır.
2. **Çözüm Komutları:**
   `manifests/20-batch-jobs.yaml` içinde `PGHOST: "quant-db"`, `key: db-password`, `suspend: false` ve `-p 6379` düzeltmelerini yaptıktan sonra Job şablonlarının değişmezliği (`immutability`) nedeniyle aşağıdaki komutla yeniden oluşturun:
   ```bash
   kubectl replace --force -f manifests/20-batch-jobs.yaml
   kubectl wait --for=condition=complete job/ledger-bootstrap -n quantflow-prod --timeout=45s
   kubectl create job --from=cronjob/market-snapshot manual-snapshot -n quantflow-prod && kubectl wait --for=condition=complete job/manual-snapshot -n quantflow-prod --timeout=30s
   ```

---

### [INC-1502] Liquidity Worker `Init:0/1`, `OOMKilled` (`137`) ve Probe Yeniden Başlatmaları (`helm-values/liquidity-prod.yaml`)
1. **Teşhis Mantığı:**
   * **Aşama 1 (`Init:0/1`):** `redis.host: "quant-cache"` yazıldığı için `wait-for-redis` InitContainer'ı sonsuz döngüde bekler (`"quant-redis"` olmalı).
   * **Aşama 2 (`OOMKilled - Exit Code 137`):** `worker.py` başlangıçta 48 MiB büyüklüğünde bir bellek matrisi ayırır ancak `resources.limits.memory: 32Mi` verildiği için Linux çekirdeği cgroup OOM Killer konteyneri anında öldürür (`192Mi` olmalı).
   * **Aşama 3 (`LivenessProbe 404`):** `livenessProbe.path: "/livez"` tanımlıdır ancak uygulama `/healthz` sunmaktadır.
2. **Çözüm Komutları:**
   `helm-values/liquidity-prod.yaml` dosyasını güncelleyip Helm sürümünü yükseltin:
   ```bash
   helm upgrade --install liquidity-worker ./charts/liquidity-worker -f helm-values/liquidity-prod.yaml -n quantflow-prod
   kubectl rollout status deploy/liquidity-worker -n quantflow-prod --timeout=45s
   ```

---

### [INC-1503] Risk Engine Hazırlık (`0/1 Ready`) Hatası ve HPA Metrik Açlığı (`manifests/30-risk-engine.yaml`)
1. **Teşhis Mantığı:**
   * Kubernetes'te Pod içinde doğrudan tanımlanan `env:` değişkenleri, `envFrom:` (`ConfigMap`) üzerinden gelen değişkenleri **ezer (override)**. `Deployment/risk-engine` içindeki `LIQUIDITY_URL: "http://127.0.0.1:9095/healthz"` tanımı ConfigMap'teki doğru adresi ezmektedir.
   * `ConfigMap/risk-engine-config` içinde `DB_PORT: "5433"` yazılmıştır (`"5432"` olmalı).
   * `HorizontalPodAutoscaler/risk-engine-hpa` içinde `scaleTargetRef.name: risk-api` (`risk-engine` olmalı) yazılmıştır ve pod şablonunda `resources.requests.cpu: 100m` eksik olduğu için HPA yüzdelik CPU kullanımını hesaplayamamaktadır (`<unknown>/70%`).
2. **Çözüm Komutları:**
   `manifests/30-risk-engine.yaml` dosyasını düzeltip uygulayın ve ConfigMap değişikliğini yüklemek için Deployment'ı yeniden başlatın:
   ```bash
   kubectl apply -f manifests/30-risk-engine.yaml
   kubectl rollout restart deploy/risk-engine -n quantflow-prod
   kubectl rollout status deploy/risk-engine -n quantflow-prod --timeout=45s
   ```

---

### [INC-1504] Risk Engine Servis Kara Deliği ve Düğüm Gecikme DaemonSet Arızası (`manifests/40-network-and-daemon.yaml`)
1. **Teşhis Mantığı:**
   * `Service/risk-engine` içinde fazladan `tier: risk-core` seçicisi bulunduğu için `Endpoints` boştur (`<none>`) ve `targetPort: 8080` (`8000` yerine) yanlıştır.
   * `DaemonSet/latency-probe` içinde toleration anahtarı `key: role` (`key: workload` yerine) yazıldığı için `Node-3`'e yerleşememektedir (`DESIRED: 2`). Ayrıca `/var/log/quant-probe` bağlama noktası `readOnly: true` olduğu için pod log yazarken `Read-only file system` hatasıyla çökmektedir (`CrashLoopBackOff`).
2. **Çözüm Komutları:**
   `manifests/40-network-and-daemon.yaml` dosyasını düzeltip uygulayın:
   ```bash
   kubectl apply -f manifests/40-network-and-daemon.yaml
   kubectl rollout status ds/latency-probe -n quantflow-prod --timeout=45s
   ```

---

### [INC-1505] Edge Gateway Bağlantı Reddi, `403 Forbidden` ve Ingress Yönlendirme Hatası (`helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml`)
1. **Teşhis Mantığı:**
   * `helm-values/gateway-prod.yaml` içinde `service.targetPort: 8081` (`8080` olmalı) ve `gateway.signatureToken: "legacy-invalid"` (`"quant-verified"` olmalı) hatalıdır.
   * `nginx.conf` dosyası konteynere `subPath: nginx.conf` ile bağlandığı için `helm upgrade` sonrasında Kubelet dosyayı otomatik güncellemez; `kubectl rollout restart deploy/quant-gateway` şarttır.
   * `manifests/50-ingress.yaml` içinde `ingressClassName: nginx-legacy` (`edge-ingress` olmalı) ve servis portu `8080` (`80` olmalı) hatalıdır.
2. **Çözüm Komutları:**
   ```bash
   helm upgrade --install quant-gateway ./charts/quant-gateway -f helm-values/gateway-prod.yaml -n quantflow-prod
   kubectl rollout restart deploy/quant-gateway -n quantflow-prod
   kubectl rollout status deploy/quant-gateway -n quantflow-prod --timeout=45s
   kubectl apply -f manifests/50-ingress.yaml

   GW_IP=$(kubectl get svc quant-gateway -n quantflow-prod -o jsonpath='{.spec.clusterIP}')
   curl -i -sS "http://${GW_IP}/api/v1/risk/evaluate"
   ```
