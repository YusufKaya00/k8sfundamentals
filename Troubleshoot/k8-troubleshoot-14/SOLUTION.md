# 🇬🇧 English Version

# 🛠️ SRE Post-Mortem & Remediation Guide: Lab 14 — AegisGrid Platform (`aegis-prod`)

This document serves as the authoritative **Principal Site Reliability Engineering (SRE) Post-Mortem & Incident Remediation Runbook** for the cascading outage across **AegisGrid**, our distributed threat intelligence, malware signature scanning, and security telemetry platform running in the `aegis-prod` namespace on Oracle Cloud Kubernetes Engine (OKE).

> [!NOTE]
> **Strict Bottom-Up Dependency Chain:**  
> AegisGrid is engineered with a linear, bottom-up dependency architecture (`Layer 0` -> `INC-1401` -> `INC-1402` -> `INC-1403` -> `INC-1404` -> `INC-1405`). Each layer depends directly on the stability of the layer beneath it. Always resolve and verify tickets in sequential order.

---

## 📑 Executive Incident Resolution Matrix

| Ticket ID | Impacted Component | Observed Symptom | Root Cause (Fault A & Fault B) | Remediation Summary | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1401]** | `threat-db-seed` (`Job`) & `feed-rotator` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` & Redis host lookup failure | **1A:** `secretKeyRef.key: postgres-password` (actual key: `database-password`)<br/>**1B/1C:** `suspend: true` & `-h redis-cache` (actual Service: `aegis-redis`) | Fix `manifests/20-feed-jobs.yaml` and run `kubectl replace --force -f manifests/20-feed-jobs.yaml` | Kubelet Pre-Start Secret Resolution, `Job` Spec Immutability & `CronJob` Controller Loop | `P1 - Blocker` |
| **[INC-1402]** | `scanner-worker` (Helm Release) | Stuck in `Init:0/1`; then `CrashLoopBackOff` (`Startup probe failed`) | **2A:** `db.port: 5433` instead of `5432`<br/>**2B:** `startupProbe.failureThreshold: 2` (4s budget vs 6s warmup) | Set `db.port: 5432` & `startupProbe.failureThreshold: 10` in `helm-values/scanner-prod.yaml` & `helm upgrade` | Sequential InitContainer Gating & Kubelet `startupProbe` Grace Budgeting | `P1 - Blocker` |
| **[INC-1403]** | `intel-api` (`Deployment`, `ConfigMap`, `PDB`) | `Running` (`0/1 Ready`), `connection refused` on `:8080`, then `HTTP 503` on `/ready` | **3A:** `readinessProbe.httpGet.port: 8080` (app listens on `8000`)<br/>**3B:** `SCANNER_HOST: "scanner-service"` instead of `"scanner-worker"` | Fix `manifests/30-intel-api.yaml`, `kubectl apply`, and `kubectl rollout restart deploy/intel-api` | Readiness Gate, PDB Disruption Blocking & `envFrom` Rollout Mechanics | `P1 - Blocker` |
| **[INC-1404]** | `intel-api` (`Service`) & `node-shield` (`DaemonSet`) | Gateway -> API connection refused (`Endpoints: <none>`); DaemonSet `DESIRED: 2` (missing Node-3) | **4A:** `Service/intel-api` has `selector: intel-backend` & `targetPort: 8080` instead of `intel-api` & `8000`<br/>**4B:** Toleration `effect: NoExecute` instead of `NoSchedule` | Fix `manifests/40-security-and-daemon.yaml` and run `kubectl apply -f manifests/40-security-and-daemon.yaml` | EndpointSlice Controller Selector Matching, `kube-proxy` DNAT & Scheduler Taint Matching | `P1 - Blocker` |
| **[INC-1405]** | `aegis-gateway` (Helm Release) & `aegis-ingress` (`Ingress`) | `504 Gateway Time-out` / `502 Bad Gateway` on `/api/v1/threats`, then `403 Forbidden`, and stale Nginx config | **5A:** `upstream.port: 8080` instead of `8000`<br/>**5B:** `gateway.securityToken: "legacy-unverified"` instead of `"aegis-verified"` + `subPath` mount reload | Fix `helm-values/gateway-prod.yaml`, run `helm upgrade`, and `kubectl rollout restart deploy/aegis-gateway` | L4 `504/502` vs L7 `403` Proxy Triage & Kubelet `subPath` Volume Mount Immutability | `P1 - Blocker` |

---

## 🔧 Deep-Dive Incident Analysis & Remediation

---

### [INC-1401] Threat Feed Seed Job & CronJob Schedule Failure (`manifests/20-feed-jobs.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **`CreateContainerConfigError` vs `CrashLoopBackOff`:**
  When a pod displays `CreateContainerConfigError`, a senior SRE immediately knows that **the container process never even started**. There are no application logs to read because the failure occurred inside the Kubelet's `GenerateRunContainerOptions` pre-start phase before invoking the container runtime (`containerd`). Specifically, Kubelet validates all referenced `ConfigMap` and `Secret` keys required to construct the container's environment variable table or volume mounts.
* **Three Sequential Faults in Batch Layer (`manifests/20-feed-jobs.yaml`):**
  1. **Fault 1A (Secret Key Mismatch):** `Job/threat-db-seed` injects `POSTGRES_PASSWORD` from `Secret/aegis-db-secret` using `key: postgres-password`. However, inspecting `manifests/10-core-infra.yaml` (or querying the Secret in the cluster) reveals the actual key name is `database-password`.
  2. **Why `kubectl apply` Fails on Fixed Jobs (Pod Template Immutability):** Once you fix `manifests/20-feed-jobs.yaml` and run `kubectl apply`, the Kubernetes API server rejects the update with `Invalid value: ...: field is immutable`. In Kubernetes, `batch/v1` `Job` objects lock `spec.template` upon creation because modifying the pod spec of an already-running or failed Job would create ambiguous completion accounting. You must delete and recreate the Job using `kubectl replace --force -f manifests/20-feed-jobs.yaml`.
  3. **Fault 1B & 1C (Suspended CronJob & Wrong Redis Service Hostname):** `CronJob/feed-rotator` is configured with `suspend: true`, which instructs the `cronjob-controller` loop in `kube-controller-manager` to skip all scheduled ticks. Furthermore, its container command attempts to run `redis-cli -h redis-cache`, whereas the Layer 0 Redis Service is named `aegis-redis`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check Job, CronJob, and batch pod states
kubectl get job,cronjob -n aegis-prod
# Expected faulty output:
# NAME                       COMPLETIONS   DURATION   AGE
# job.batch/threat-db-seed   0/1           4m         4m
#
# NAME                         SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# cronjob.batch/feed-rotator   */2 * * * *   True      0        <none>          4m

kubectl get pods -n aegis-prod -l app.kubernetes.io/name=threat-db-seed
# Expected faulty output:
# NAME                   READY   STATUS                       RESTARTS   AGE
# threat-db-seed-xxxxx   0/1     CreateContainerConfigError   0          4m

# 2. Inspect the exact Kubelet config error on the threat-db-seed pod
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=threat-db-seed | grep -A 8 "Events:"
# Expected faulty output:
# Warning  Failed  ...  kubelet  Error: secret "aegis-db-secret" not found or key "postgres-password" not found in secret "aegis-prod/aegis-db-secret"

# 3. Compare available keys inside aegis-db-secret and active Services in aegis-prod
kubectl get secret aegis-db-secret -n aegis-prod -o jsonpath='{.data}' && echo ""
# Expected output:
# {"database-password":"QWVnaXNTdXBlclNlY3JldDIwMjYh"}

kubectl get svc -n aegis-prod
# Expected output shows Service name is "aegis-redis" (port 6379), NOT "redis-cache"!
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Open `manifests/20-feed-jobs.yaml` and apply all three fixes:
  1. In `Job/threat-db-seed`, change `secretKeyRef.key` from `postgres-password` to `database-password`.
  2. In `CronJob/feed-rotator`, change `suspend: true` to `suspend: false`.
  3. In `CronJob/feed-rotator`, change both occurrences of `-h redis-cache` to `-h aegis-redis`.

```diff
--- a/manifests/20-feed-jobs.yaml
+++ b/manifests/20-feed-jobs.yaml
@@ -26,7 +26,7 @@ spec:
               valueFrom:
                 secretKeyRef:
                   name: aegis-db-secret
-                  key: postgres-password
+                  key: database-password
           command:
             - sh
             - -c
@@ -62,7 +62,7 @@ metadata:
     app.kubernetes.io/part-of: aegisgrid
 spec:
   schedule: "*/2 * * * *"
-  suspend: true
+  suspend: false
   concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 2
   failedJobsHistoryLimit: 2
@@ -84,4 +84,4 @@ spec:
               command:
                 - sh
                 - -c
-                - "redis-cli -h redis-cache -p 6379 SET aegis:feed:last_sync $(date -u +%Y-%m-%dT%H:%M:%SZ) && redis-cli -h redis-cache -p 6379 INCR aegis:feed:sync_count && echo 'Feed rotation synced successfully.'"
+                - "redis-cli -h aegis-redis -p 6379 SET aegis:feed:last_sync $(date -u +%Y-%m-%dT%H:%M:%SZ) && redis-cli -h aegis-redis -p 6379 INCR aegis:feed:sync_count && echo 'Feed rotation synced successfully.'"
```

* **Step 2:** Recreate the immutable `Job` and update the `CronJob` using `kubectl replace --force`:
```bash
kubectl replace --force -f manifests/20-feed-jobs.yaml
```

* **Step 3:** Wait for `threat-db-seed` to finish and run the verification suite:
```bash
# 1. Verify threat-db-seed Job completed (1/1)
kubectl wait --for=condition=complete job/threat-db-seed -n aegis-prod --timeout=45s
kubectl get job threat-db-seed -n aegis-prod
# Expected output: COMPLETIONS: 1/1

# 2. Verify PostgreSQL threat_signatures table contains exactly 3 rows
kubectl exec -n aegis-prod aegis-db-0 -- psql -U aegis_admin -d aegis_intel -tAc "SELECT count(*) FROM threat_signatures;"
# Expected output: 3

# 3. Verify feed-rotator CronJob is unsuspended (SUSPEND: False)
kubectl get cronjob feed-rotator -n aegis-prod
# Expected output: SUSPEND: False

# 4. Trigger a manual job from feed-rotator and wait for completion
kubectl create job --from=cronjob/feed-rotator manual-feed-sync -n aegis-prod && kubectl wait --for=condition=complete job/manual-feed-sync -n aegis-prod --timeout=30s
# Expected output: job.batch/manual-feed-sync condition met
```

#### 4. 💡 SRE Production Wisdom & Real-World Comparisons
* **Why `Job` Templates Are Immutable:** Unlike a `Deployment` (which creates a new `ReplicaSet` on every pod template modification), a `Job` tracks historical completions directly against a single pod template. In GitOps pipelines (Argo CD / Flux), database migration Jobs are configured with `Replace=true` sync options or PreSync hooks with `hook-delete-policy: BeforeHookCreation` to avoid immutability collisions.
* **Emergency CronJob Suspension Trap:** During database maintenance windows, SREs frequently pause background CronJobs via `kubectl patch cronjob <name> -p '{"spec":{"suspend":true}}'`. Always track suspended CronJobs via Prometheus alerts (`kube_cronjob_spec_suspend == 1`) so critical sync tasks are never left permanently disabled after maintenance ends.

---

### [INC-1402] Scanner Worker Stuck in Init:0/1 & Failing Startup Probe (`charts/scanner-worker/` & `helm-values/scanner-prod.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Decoding `Init:0/1` vs `Running`:**
  When `kubectl get pods` shows `STATUS: Init:0/1`, Kubernetes guarantees that **none of the main application containers have started yet**. Init containers execute sequentially to completion (`Exit Code 0`) before Kubelet starts any app container. Running `kubectl logs deploy/scanner-worker` without specifying `-c wait-for-db` fails or returns nothing because the default container (`scanner`) is still in `PodInitializing`.
* **Two-Stage Failure in `scanner-worker`:**
  1. **Fault 2A (InitContainer Database Port Mismatch):** Inspecting `kubectl logs -n aegis-prod deploy/scanner-worker -c wait-for-db` shows `Waiting for database at aegis-db:5433...`. The chart's default `values.yaml` has `db.port: 5432`, but the production override file `helm-values/scanner-prod.yaml` overrides `db.port: 5433`. Because PostgreSQL listens on `5432`, `nc -z -w 2 aegis-db 5433` fails indefinitely.
  2. **Fault 2B (Startup Probe Budget Starvation):** Once `db.port` is fixed to `5432`, `wait-for-db` completes (`0` exit code) and Kubelet starts the main `scanner` container. However, `scanner.py` takes **6 seconds** (`time.sleep(6)`) to load threat signatures into memory before opening socket `0.0.0.0:9090`. In `helm-values/scanner-prod.yaml`, `startupProbe` is configured with `periodSeconds: 2` and `failureThreshold: 2` (`2 * 2 = 4 seconds` maximum startup budget!). At second 4, Kubelet kills the container (`Startup probe failed: dial tcp ...:9090: connect: connection refused`) before the 6-second warmup finishes, trapping the pod in an infinite `CrashLoopBackOff`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check scanner-worker pod status
kubectl get pods -n aegis-prod -l app.kubernetes.io/name=scanner-worker
# Expected faulty output:
# NAME                              READY   STATUS     RESTARTS   AGE
# scanner-worker-xxxxxxxxxx-xxxxx   0/1     Init:0/1   0          5m

# 2. Check logs of the blocking init container
kubectl logs -n aegis-prod deploy/scanner-worker -c wait-for-db --tail=20
# Expected faulty output:
# Waiting for database at aegis-db:5433...
# Waiting for database at aegis-db:5433...

# 3. Inspect active Helm release override values and rendered template
helm get values scanner-worker -n aegis-prod
# Expected faulty output:
# USER-SUPPLIED VALUES:
# db:
#   host: aegis-db
#   port: 5433
# replicaCount: 1
# startupProbe:
#   failureThreshold: 2
#   periodSeconds: 2
#   timeoutSeconds: 2

# 4. Inspect scanner.py warmup duration in the chart ConfigMap
helm template scanner-worker ./charts/scanner-worker -f helm-values/scanner-prod.yaml -n aegis-prod | grep -A 6 "Initializing scanner engine"
# Expected output shows: time.sleep(6) before HTTPServer binds port 9090!
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `helm-values/scanner-prod.yaml` to set `db.port: 5432` and increase `startupProbe.failureThreshold` to `10` (or `12`, giving a `20s–24s` startup budget for the `6s` warmup):

```diff
--- a/helm-values/scanner-prod.yaml
+++ b/helm-values/scanner-prod.yaml
@@ -2,8 +2,8 @@ replicaCount: 1
 
 db:
   host: "aegis-db"
-  port: 5433
+  port: 5432
 
 startupProbe:
   periodSeconds: 2
-  failureThreshold: 2
+  failureThreshold: 10
   timeoutSeconds: 2
```

* **Step 2:** Upgrade the `scanner-worker` Helm release in `aegis-prod`:
```bash
helm upgrade scanner-worker ./charts/scanner-worker -f helm-values/scanner-prod.yaml -n aegis-prod
```

* **Step 3:** Verify that the rollout completes and the scanner engine responds on port `9090`:
```bash
# 1. Wait for scanner-worker rollout to succeed
kubectl rollout status deploy/scanner-worker -n aegis-prod --timeout=45s
# Expected output: deployment "scanner-worker" successfully rolled out

# 2. Verify in-cluster health endpoint on port 9090
kubectl exec -n aegis-prod deploy/scanner-worker -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9090/healthz').read().decode())"
# Expected output: {"status": "healthy", "engine": "scanner-worker", "signatures_loaded": 3}
```

#### 4. 💡 SRE Production Wisdom & Real-World Comparisons
* **Why `startupProbe` Exists (vs `livenessProbe.initialDelaySeconds`):** Heavy workloads (JVM services, ML model servers, signature scanners) often take variable time to boot (e.g., 5–30 seconds depending on CPU throttling or cold caches) but should fail fast (within 5–10 seconds) if they deadlock *after* startup. `startupProbe` disables `livenessProbe` and `readinessProbe` until it succeeds once. Always size `startupProbe` budget (`periodSeconds × failureThreshold`) to at least `2x–3x` the worst-case cold-start time.
* **Helm Value Override Auditing:** When triaging a Helm release, never look only at `charts/<name>/values.yaml`. Always run `helm get values <release> -n <ns>` (and `helm get manifest <release> -n <ns>`) to see what environment-specific overrides were injected at deploy time.

---

### [INC-1403] Intel API Readiness Probe Port & Upstream Service Discovery (`manifests/30-intel-api.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **`Running (0/1 Ready)` with `RESTARTS: 0`:**
  When pods show `STATUS: Running` with `0` restarts but `READY: 0/1`, **the `livenessProbe` is succeeding, while the `readinessProbe` is failing**. Unlike a failing liveness probe (which restarts the container), a failing readiness probe keeps the container running while marking the Pod condition `Ready=False` and causing `PodDisruptionBudget/intel-api-pdb` (`minAvailable: 1`) to drop to `ALLOWED DISRUPTIONS: 0`, blocking voluntary node drains.
* **Distinguishing TCP `connection refused` from `HTTP 503`:**
  1. **Fault 3A (Probe Port Mismatch -> TCP `connection refused`):** In `manifests/30-intel-api.yaml`, the container listens on port `8000` (`PORT: "8000"`, `containerPort: 8000`, `livenessProbe.httpGet.port: 8000`), but `readinessProbe.httpGet.port` is set to `8080`. When Kubelet sends a TCP `SYN` to `<pod-ip>:8080`, nothing is listening on port `8080`, so the Linux kernel immediately replies with a TCP `RST` (`connect: connection refused`).
  2. **Fault 3B (Upstream DNS Name Mismatch -> `HTTP 503`):** Once you change `readinessProbe.httpGet.port` to `8000`, Kubelet connects to the Python HTTP server, which executes the `/ready` handler. However, `/ready` checks PostgreSQL (`aegis-db:5432`), Redis (`aegis-redis:6379`), and `http://${SCANNER_HOST}:${SCANNER_PORT}/healthz`. In `ConfigMap/intel-api-config`, `SCANNER_HOST` is set to `"scanner-service"`, whereas the actual Service created by the Helm release in INC-1402 is `"scanner-worker"`. CoreDNS returns `NXDOMAIN` (`[Errno -2] Name or service not known`), causing `/ready` to return `HTTP 503 Service Unavailable`.
  3. **Why `kubectl rollout restart` Is Required:** Because `SCANNER_HOST` is injected into the pod via `envFrom: configMapRef`, modifying `ConfigMap/intel-api-config` alone does not update environment variables inside already-running processes.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check intel-api pods and PDB status
kubectl get pods,pdb -n aegis-prod -l app.kubernetes.io/name=intel-api
# Expected faulty output:
# NAME                             READY   STATUS    RESTARTS   AGE
# pod/intel-api-xxxxxxxxxx-xxxxx   0/1     Running   0          6m
# pod/intel-api-xxxxxxxxxx-yyyyy   0/1     Running   0          6m
#
# NAME                                        MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# poddisruptionbudget.policy/intel-api-pdb    1               N/A               0                     6m

# 2. Inspect pod readiness probe definition and failure events
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=intel-api | grep -A 10 "Readiness:"
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=intel-api | grep -A 10 "Events:"
# Expected faulty output:
# Readiness: http-get http://:8080/ready delay=3s timeout=2s period=5s #success=1 #failure=3
# Warning  Unhealthy  ...  kubelet  Readiness probe failed: Get "http://10.244.x.x:8080/ready": dial tcp 10.244.x.x:8080: connect: connection refused

# 3. Inspect ConfigMap environment variables vs actual Service names
kubectl get configmap intel-api-config -n aegis-prod -o yaml | grep -E "PORT|HOST"
# Expected faulty output:
#   DB_HOST: aegis-db
#   DB_PORT: "5432"
#   PORT: "8000"
#   REDIS_HOST: aegis-redis
#   REDIS_PORT: "6379"
#   SCANNER_HOST: scanner-service   <-- Mismatch!
#   SCANNER_PORT: "9090"

kubectl get svc -n aegis-prod
# Expected output shows scanner service is named "scanner-worker", NOT "scanner-service"!
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `manifests/30-intel-api.yaml`:
  1. In `ConfigMap/intel-api-config`, change `SCANNER_HOST: "scanner-service"` to `SCANNER_HOST: "scanner-worker"`.
  2. In `Deployment/intel-api`, change `readinessProbe.httpGet.port` from `8080` to `8000`.

```diff
--- a/manifests/30-intel-api.yaml
+++ b/manifests/30-intel-api.yaml
@@ -12,7 +12,7 @@ data:
   DB_PORT: "5432"
   REDIS_HOST: "aegis-redis"
   REDIS_PORT: "6379"
-  SCANNER_HOST: "scanner-service"
+  SCANNER_HOST: "scanner-worker"
   SCANNER_PORT: "9090"
   REQUIRED_GATEWAY_TOKEN: "aegis-verified"
   server.py: |
@@ -140,7 +140,7 @@ spec:
           readinessProbe:
             httpGet:
               path: /ready
-              port: 8080
+              port: 8000
             initialDelaySeconds: 3
             periodSeconds: 5
             timeoutSeconds: 2
```

* **Step 2:** Apply the updated manifest and trigger a rolling restart of `deploy/intel-api` so the new ConfigMap environment variable (`SCANNER_HOST=scanner-worker`) is loaded:
```bash
kubectl apply -f manifests/30-intel-api.yaml
kubectl rollout restart deploy/intel-api -n aegis-prod
```

* **Step 3:** Verify that both replicas become `1/1 Ready`, `intel-api-pdb` allows disruptions (`ALLOWED DISRUPTIONS: 1`), and `/ready` returns HTTP 200:
```bash
# 1. Wait for intel-api Deployment rollout to complete (2/2 Ready)
kubectl rollout status deploy/intel-api -n aegis-prod --timeout=45s

# 2. Verify /ready endpoint returns HTTP 200 JSON from inside the pod
kubectl exec -n aegis-prod deploy/intel-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/ready').read().decode())"
# Expected output: {"status": "ready", "db": "connected", "redis": "connected", "scanner": "connected"}
```

#### 4. 💡 SRE Production Wisdom & Real-World Comparisons
* **Shallow vs Deep Readiness Probes:** Note how `intel-api` separates `/healthz` (`livenessProbe` — shallow check confirming the Python HTTP loop is responsive) from `/ready` (`readinessProbe` — deep check verifying DB, Redis, and upstream dependency reachability). Never put deep upstream checks inside a `livenessProbe`, or a temporary downstream blip will cause cascading container restarts across your entire fleet!
* **Automatic Rollout on ConfigMap Change:** In production Helm charts, SREs add `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}` to `spec.template.metadata.annotations` or use the `Reloader` controller so ConfigMap edits automatically trigger a rolling update.

---

### [INC-1404] Intel API Service Routing Blackhole & Node-Shield DaemonSet Toleration (`manifests/40-security-and-daemon.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Why `localhost:8000/ready` Works Inside the Pod While `http://intel-api:8000/ready` Fails Across the Cluster:**
  In INC-1403, we proved that both `intel-api` pods are `1/1 Ready` and serving `/ready` on port `8000`. Yet when `aegis-gateway` calls `http://intel-api:8000/ready`, it immediately fails with `wget: can't connect to remote host: Connection refused`.
  Whenever a pod is healthy on `localhost` but unreachable via its Kubernetes `Service`, a senior SRE immediately inspects **the `Service` object's `selector`, `port`, `targetPort`, and `Endpoints` / `EndpointSlice`**.
* **Analyzing Both Faults in `manifests/40-security-and-daemon.yaml`:**
  1. **Fault 4A (`Service/intel-api` Selector Drift & `targetPort` Mismatch):**
     - First, `Service/intel-api` specifies `selector.app.kubernetes.io/name: intel-backend`, whereas the `intel-api` pods actually carry `app.kubernetes.io/name: intel-api`. Because no pods match `intel-backend`, the EndpointSlice controller populates `Endpoints: <none>`, causing `kube-proxy` to reject connections to the ClusterIP.
     - Second, even after fixing the selector to `intel-api`, `Service/intel-api` specifies `targetPort: 8080` while `intel-api` pods listen on container port `8000`. `targetPort` must be changed to `8000` so `kube-proxy` DNATs `ClusterIP:8000` -> `PodIP:8000`.
  2. **Fault 4B (`node-shield` DaemonSet Taint Toleration Effect Mismatch):** The cluster has 3 nodes (`Node-1`, `Node-2`, and `Node-3`). `Node-3` has the taint `workload=database:NoSchedule`. `DaemonSet/node-shield` has `DESIRED: 2` because its toleration specifies `effect: NoExecute` instead of `effect: NoSchedule`. In Kubernetes scheduling semantics, a toleration with `effect: NoExecute` **only** matches a taint with `effect: NoExecute` (unless `effect` is omitted to match all effects). Because `NoExecute != NoSchedule`, `daemonset-controller` refuses to schedule `node-shield` onto `Node-3`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Reproduce the Service connection failure from aegis-gateway to intel-api
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready || true
# Expected faulty output:
# wget: can't connect to remote host (10.96.x.x): Connection refused

# 2. Inspect Service/intel-api selector, targetPort, and Endpoints vs intel-api pod labels
kubectl describe svc intel-api -n aegis-prod
# Expected faulty output:
# Selector:          app.kubernetes.io/name=intel-backend   <-- Wrong selector!
# Port:              http  8000/TCP
# TargetPort:        8080/TCP                               <-- Wrong targetPort!
# Endpoints:         <none>

kubectl get pods -n aegis-prod -l app.kubernetes.io/name=intel-api --show-labels
# Expected output shows label: app.kubernetes.io/name=intel-api

# 3. Inspect DaemonSet status and node taints across the 3-node cluster
kubectl get ds node-shield -n aegis-prod
# Expected faulty output:
# NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
# node-shield   2         2         2       2            2           <none>          7m

kubectl get nodes -o custom-columns=NAME:.metadata.name,TIER:.metadata.labels.tier,TAINTS:.spec.taints
# Expected output shows Node-3 taint has effect: NoSchedule (workload=database:NoSchedule)
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `manifests/40-security-and-daemon.yaml`:
  1. In `Service/intel-api`, change `targetPort: 8080` to `targetPort: 8000`, and change `selector.app.kubernetes.io/name: intel-backend` to `app.kubernetes.io/name: intel-api`.
  2. In `DaemonSet/node-shield`, change the toleration `effect: NoExecute` to `effect: NoSchedule`.

```diff
--- a/manifests/40-security-and-daemon.yaml
+++ b/manifests/40-security-and-daemon.yaml
@@ -11,10 +11,10 @@ spec:
   ports:
     - name: http
       port: 8000
-      targetPort: 8080
+      targetPort: 8000
       protocol: TCP
   selector:
-    app.kubernetes.io/name: intel-backend
+    app.kubernetes.io/name: intel-api
 ---
 apiVersion: apps/v1
 kind: DaemonSet
@@ -40,7 +40,7 @@ spec:
         - key: workload
           operator: Equal
           value: database
-          effect: NoExecute
+          effect: NoSchedule
       containers:
         - name: shield-agent
           image: docker.io/library/busybox:1.36
```

* **Step 2:** Apply the updated Service and DaemonSet manifest:
```bash
kubectl apply -f manifests/40-security-and-daemon.yaml
```

* **Step 3:** Verify that `node-shield` is running on all 3 nodes (`3/3`) and `aegis-gateway` can reach `intel-api:8000/ready`:
```bash
# 1. Verify node-shield DaemonSet is scheduled and Ready across all 3 nodes
kubectl rollout status ds/node-shield -n aegis-prod --timeout=45s
kubectl get ds node-shield -n aegis-prod
# Expected output: DESIRED: 3, CURRENT: 3, READY: 3

# 2. Verify aegis-gateway can reach intel-api:8000/ready via Service/intel-api
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready
# Expected output: {"status": "ready", "db": "connected", "redis": "connected", "scanner": "connected"}
```

#### 4. 💡 SRE Production Wisdom & Real-World Comparisons
* **Named TargetPorts Prevent Port Drift:** Instead of hardcoding numeric `targetPort: 8000` in a `Service`, reference the container's named port (`targetPort: http`, matching `ports[0].name: http` on the Pod). That way, even if an application team changes the container listening port in the `Deployment`, the `Service` automatically routes to the updated port without breaking.
* **Wildcard Taint Tolerations for Node Agents:** For cluster-wide security/logging DaemonSets (Falco, Cilium, Node-Problem-Detector), setting `operator: Exists` without specifying `key` or `effect` (`tolerations: [{operator: Exists}]`) guarantees the agent schedules onto every node regardless of custom workload taints.

---

### [INC-1405] Edge Gateway 504/502 Upstream Error, 403 Token Rejection & ConfigMap Reload (`helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml`)

#### 1. 🧠 Diagnostic Mindset (How to Think When You See This Symptom)
* **Distinguishing `504 Gateway Time-out` / `502 Bad Gateway` vs `403 Forbidden` at the Edge:**
  1. **Fault 5A (`504 Gateway Time-out` / `502 Bad Gateway` — L4 Upstream Port Mismatch):** Now that `Service/intel-api` routes port `8000` to the ready backend pods, testing `http://localhost:8080/api/v1/threats` on `aegis-gateway` returns `504 Gateway Time-out` (or `502 Bad Gateway`). Inspecting `kubectl logs deploy/aegis-gateway` reveals Nginx error `upstream timed out (110: Operation timed out) while connecting to upstream, upstream: "http://10.96.x.x:8080/api/v1/threats"`. Why? Because `helm-values/gateway-prod.yaml` sets `upstream.port: 8080` instead of `8000`! On OCI VCN-Native CNI, packets sent to a ClusterIP (`10.96.x.x`) on an unmapped Service port (`8080`) do not match any `kube-proxy` `iptables` DNAT rule and time out after Nginx's `proxy_connect_timeout 3s;`.
  2. **Fault 5B (`403 Forbidden` — L7 Security Header Mismatch):** In `charts/aegis-gateway/templates/configmap.yaml`, Nginx injects the HTTP header `proxy_set_header X-Aegis-Token "{{ .Values.gateway.securityToken }}";`. In `helm-values/gateway-prod.yaml`, `gateway.securityToken` is set to `"legacy-unverified"`, whereas `intel-api` (`REQUIRED_GATEWAY_TOKEN` in `manifests/30-intel-api.yaml`) requires `"aegis-verified"`. When the token mismatches, `intel-api` rejects the request with `HTTP 403 Forbidden` (`{"error": "untrusted proxy: invalid or missing X-Aegis-Token header"}`).
  3. **Why `helm upgrade` Alone Does Not Reload `aegis-gateway`:** Look closely at `charts/aegis-gateway/templates/deployment.yaml`:
     - First, the ConfigMap volume mount uses `subPath: nginx.conf` (`mountPath: /etc/nginx/nginx.conf`). In Kubernetes, **a volume mount using `subPath` never receives automatic Kubelet ConfigMap updates**!
     - Second, even without `subPath`, Nginx parses `/etc/nginx/nginx.conf` into memory once at master process startup. Therefore, after running `helm upgrade`, you **must** execute `kubectl rollout restart deploy/aegis-gateway -n aegis-prod` so new pods mount the updated ConfigMap and start fresh Nginx workers.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect current Helm values and gateway ConfigMap
helm get values aegis-gateway -n aegis-prod
# Expected faulty output:
# USER-SUPPLIED VALUES:
# gateway:
#   securityToken: legacy-unverified
# replicaCount: 2
# upstream:
#   host: intel-api
#   port: 8080

kubectl get configmap aegis-gateway-config -n aegis-prod -o yaml | grep -E "proxy_set_header X-Aegis-Token|proxy_pass"
# Expected faulty output:
#   proxy_set_header X-Aegis-Token "legacy-unverified";
#   proxy_pass http://intel-api:8080/api/v1/threats;

# 2. Test gateway response in-cluster and check Nginx error/access logs
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -S -O- http://localhost:8080/api/v1/threats 2>&1 || true
# Expected faulty output:
#   HTTP/1.1 504 Gateway Time-out (or 502 Bad Gateway)

kubectl logs -n aegis-prod deploy/aegis-gateway --tail=20
# Expected faulty output shows upstream connection timed out / refused on port 8080

# 3. Check expected token in intel-api-config and inspect Ingress resource
kubectl get configmap intel-api-config -n aegis-prod -o yaml | grep REQUIRED_GATEWAY_TOKEN
# Expected output:
#   REQUIRED_GATEWAY_TOKEN: aegis-verified

kubectl get ingress aegis-ingress -n aegis-prod -o yaml
```

#### 3. 🛠️ Step-by-Step Resolution
* **Step 1:** Edit `helm-values/gateway-prod.yaml` to fix both `upstream.port` (`8000`) and `gateway.securityToken` (`"aegis-verified"`):

```diff
--- a/helm-values/gateway-prod.yaml
+++ b/helm-values/gateway-prod.yaml
@@ -2,7 +2,7 @@ replicaCount: 2
 
 upstream:
   host: "intel-api"
-  port: 8080
+  port: 8000
 
 gateway:
-  securityToken: "legacy-unverified"
+  securityToken: "aegis-verified"
```

* **Step 2:** Upgrade the `aegis-gateway` Helm release and restart the `aegis-gateway` Deployment so the updated ConfigMap is mounted and loaded by Nginx:
```bash
helm upgrade aegis-gateway ./charts/aegis-gateway -f helm-values/gateway-prod.yaml -n aegis-prod
kubectl rollout restart deploy/aegis-gateway -n aegis-prod
kubectl rollout status deploy/aegis-gateway -n aegis-prod --timeout=45s
```

* **Step 3:** Verify end-to-end threat intelligence retrieval both in-cluster and via the external LoadBalancer:
```bash
# 1. Verify in-cluster request through aegis-gateway returns HTTP 200 JSON with 3 threat signatures
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- http://localhost:8080/api/v1/threats
# Expected output:
# {"platform": "AegisGrid", "status": "operational", "active_signatures": ["SQLI-9001", "XSS-9002", "RCE-9003"], "scanner_engine": "online"}

# 2. Verify external access via OCI LoadBalancer IP (when EXTERNAL-IP is assigned)
LB_IP=$(kubectl get svc aegis-gateway -n aegis-prod -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway LoadBalancer IP: ${LB_IP:-Pending}"
if [ -n "${LB_IP}" ]; then
  curl -s -H "Host: aegis.local" "http://${LB_IP}/api/v1/threats"
fi
```

#### 4. 💡 SRE Production Wisdom & Real-World Comparisons
* **The Kubernetes `subPath` ConfigMap Gotcha:** When a ConfigMap is mounted as a whole directory, Kubelet uses an atomic `..data` symlink swap to update files on disk within ~60–90 seconds. However, when a single file is mounted via `subPath`, Linux bind-mounts that specific inode at container creation time. When the ConfigMap updates, Kubelet cannot swap the bind-mounted inode, leaving the file inside the container frozen forever until the pod is recreated!
* **Defense-in-Depth (Service Isolation + L7 Context Headers / mTLS):** Combining strict L4 Service port scoping (INC-1404) with L7 gateway authentication tokens or mutual TLS (INC-1405) ensures that internal APIs reject unauthorized requests with a clear `403 Forbidden` audit trail.

---

## 🏁 End-to-End Production Health Check (Bottom-Up Checklist)

Run this complete bottom-up verification script from your `kubectl` client to certify that **AegisGrid** is 100% healthy:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="aegis-prod"
echo "=================================================================="
echo " 🏁 AEGISGRID END-TO-END PRODUCTION HEALTH CHECK (aegis-prod)"
echo "=================================================================="

echo "--> [Layer 0] Checking Stateful Foundation (PostgreSQL 16 & Redis 7.2)..."
kubectl get statefulset aegis-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -qx "1"
kubectl get deploy aegis-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -qx "1"
echo "    ✅ aegis-db (1/1) & aegis-redis (1/1) are Healthy."

echo "--> [INC-1401] Checking Threat DB Seed Job & Feed Rotator CronJob..."
kubectl get job threat-db-seed -n "${NS}" -o jsonpath='{.status.succeeded}' | grep -qx "1"
SIG_COUNT=$(kubectl exec -n "${NS}" aegis-db-0 -- psql -U aegis_admin -d aegis_intel -tAc "SELECT count(*) FROM threat_signatures;" | tr -d '[:space:]')
[ "${SIG_COUNT}" = "3" ]
kubectl get cronjob feed-rotator -n "${NS}" -o jsonpath='{.spec.suspend}' | grep -qx "false"
echo "    ✅ threat-db-seed Completed (3 signatures in DB) & feed-rotator active."

echo "--> [INC-1402] Checking Scanner Worker Deployment & Startup Probe..."
kubectl rollout status deploy/scanner-worker -n "${NS}" --timeout=30s >/dev/null
SCAN_RESP=$(kubectl exec -n "${NS}" deploy/scanner-worker -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9090/healthz').read().decode())")
echo "${SCAN_RESP}" | grep -q '"status": "healthy"'
echo "    ✅ scanner-worker (1/1 Ready) responding on :9090/healthz."

echo "--> [INC-1403] Checking Intel API Readiness, Upstream Discovery & PDB..."
kubectl rollout status deploy/intel-api -n "${NS}" --timeout=30s >/dev/null
API_READY=$(kubectl exec -n "${NS}" deploy/intel-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/ready').read().decode())")
echo "${API_READY}" | grep -q '"status": "ready"'
echo "    ✅ intel-api (2/2 Ready) connected to DB, Redis, and scanner-worker."

echo "--> [INC-1404] Checking Intel API Service Routing & Node-Shield DaemonSet..."
DESIRED_DS=$(kubectl get ds node-shield -n "${NS}" -o jsonpath='{.status.desiredNumberScheduled}')
READY_DS=$(kubectl get ds node-shield -n "${NS}" -o jsonpath='{.status.numberReady}')
[ "${DESIRED_DS}" = "3" ] && [ "${READY_DS}" = "3" ]
kubectl exec -n "${NS}" deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready | grep -q '"status": "ready"'
echo "    ✅ node-shield running on 3/3 nodes & Service/intel-api routes gateway -> intel-api:8000."

echo "--> [INC-1405] Checking Edge Gateway L7 Routing & Threat Signatures Payload..."
THREATS_JSON=$(kubectl exec -n "${NS}" deploy/aegis-gateway -- wget -qO- http://localhost:8080/api/v1/threats)
echo "${THREATS_JSON}" | grep -q "SQLI-9001"
echo "${THREATS_JSON}" | grep -q "XSS-9002"
echo "${THREATS_JSON}" | grep -q "RCE-9003"
echo "    ✅ aegis-gateway returned HTTP 200 with SQLI-9001, XSS-9002, RCE-9003."

LB_IP=$(kubectl get svc aegis-gateway -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -n "${LB_IP}" ]; then
  echo "--> [External LoadBalancer Check] Testing http://${LB_IP}/api/v1/threats..."
  curl -sf -H "Host: aegis.local" "http://${LB_IP}/api/v1/threats" | grep -q "SQLI-9001"
  echo "    ✅ External LoadBalancer (${LB_IP}) verified!"
fi

echo "=================================================================="
echo " 🎉 ALL AEGISGRID PRODUCTION SYSTEMS ARE 100% HEALTHY!"
echo "=================================================================="
```

---

# 🇹🇷 Türkçe Versiyon

# 🛠️ SRE Post-Mortem ve Çözüm Rehberi: Lab 14 — AegisGrid Platformu (`aegis-prod`)

Bu belge, Oracle Cloud Kubernetes Engine (OKE) kümesi üzerindeki `aegis-prod` namespace'inde çalışan dağıtık tehdit istihbaratı, zararlı yazılım imza tarama ve güvenlik telemetrisi platformu **AegisGrid**'de meydana gelen zincirleme kesintinin **Kıdemli SRE (Principal Site Reliability Engineering) Post-Mortem ve Kök Neden Analizi (RCA)** rehberidir.

> [!NOTE]
> **Kesin Aşağıdan Yukarıya (Bottom-Up) Bağımlılık Zinciri:**  
> AegisGrid; `Katman 0` -> `INC-1401` -> `INC-1402` -> `INC-1403` -> `INC-1404` -> `INC-1405` sırasıyla doğrusal bir bağımlılık mimarisine sahiptir. Her katman bir altındaki katmanın sağlıklı çalışmasına bağlıdır; biletleri sırasıyla çözüp doğrulayın.

---

## 📑 Yönetici Özeti (Olay Çözüm Matrisi)

| Bilet No | Etkilenen Bileşen | Gözlemlenen Semptom | Kök Neden (Hata A & Hata B) | Çözüm Özeti | Kontrol Düzlemi & Çekirdek Mekanizması | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-1401]** | `threat-db-seed` (`Job`) & `feed-rotator` (`CronJob`) | `CreateContainerConfigError` (`0/1 Completed`); `CronJob` `SUSPEND: True` ve Redis bağlantı hatası | **1A:** `secretKeyRef.key: postgres-password` (gerçek anahtar: `database-password`)<br/>**1B/1C:** `suspend: true` & `-h redis-cache` (gerçek Servis: `aegis-redis`) | `manifests/20-feed-jobs.yaml` dosyasını düzelt ve `kubectl replace --force -f manifests/20-feed-jobs.yaml` çalıştır | Kubelet Başlatma Öncesi Secret Doğrulaması, `Job` Değişmezliği (Immutability) & `CronJob` Döngüsü | `P1 - Blocker` |
| **[INC-1402]** | `scanner-worker` (Helm Sürümü) | `Init:0/1` aşamasında kilitlenme; ardından `CrashLoopBackOff` (`Startup probe failed`) | **2A:** `db.port: 5433` (gerçek port `5432`)<br/>**2B:** `startupProbe.failureThreshold: 2` (6sn yüklemeye karşılık 4sn bütçe) | `helm-values/scanner-prod.yaml` içinde `db.port: 5432` & `failureThreshold: 10` yap ve `helm upgrade` çalıştır | Sıralı InitContainer Kilidi & Kubelet `startupProbe` Başlangıç Bütçesi | `P1 - Blocker` |
| **[INC-1403]** | `intel-api` (`Deployment`, `ConfigMap`, `PDB`) | `Running` (`0/1 Ready`), `:8080` üzerinde `connection refused`, ardından `/ready` üzerinde `HTTP 503` | **3A:** `readinessProbe.httpGet.port: 8080` (uygulama `8000` dinliyor)<br/>**3B:** `SCANNER_HOST: "scanner-service"` (`"scanner-worker"` olmalı) | `manifests/30-intel-api.yaml` dosyasını düzelt, `kubectl apply` ve `kubectl rollout restart deploy/intel-api` çalıştır | Readiness Kontrolü, PDB Kesinti Kilidi & `envFrom` Yeniden Başlatma Gereksinimi | `P1 - Blocker` |
| **[INC-1404]** | `intel-api` (`Service`) & `node-shield` (`DaemonSet`) | Gateway -> API `Connection refused` (`Endpoints: <none>`); DaemonSet `DESIRED: 2` (Node-3 eksik) | **4A:** `Service/intel-api` içinde `selector: intel-backend` & `targetPort: 8080` (`intel-api` & `8000` olmalı)<br/>**4B:** Toleration `effect: NoExecute` (`NoSchedule` olmalı) | `manifests/40-security-and-daemon.yaml` dosyasını düzelt ve `kubectl apply -f manifests/40-security-and-daemon.yaml` çalıştır | EndpointSlice Seçici Eşleşmesi, `kube-proxy` DNAT & Scheduler Taint Eşleşmesi | `P1 - Blocker` |
| **[INC-1405]** | `aegis-gateway` (Helm Sürümü) & `aegis-ingress` (`Ingress`) | `/api/v1/threats` üzerinde `504 Gateway Time-out` / `502 Bad Gateway`, ardından `403 Forbidden` ve eski Nginx konfigürasyonu | **5A:** `upstream.port: 8080` (`8000` olmalı)<br/>**5B:** `gateway.securityToken: "legacy-unverified"` (`"aegis-verified"` olmalı) + `subPath` mount yenilenmemesi | `helm-values/gateway-prod.yaml` dosyasını düzelt, `helm upgrade` ve `kubectl rollout restart deploy/aegis-gateway` çalıştır | L4 `504/502` vs L7 `403` Proxy Analizi & Kubelet `subPath` Volume Mount Değişmezliği | `P1 - Blocker` |

---

## 🔧 Bilet Bazında Derinlemesine Kök Neden Analizi ve Çözüm Adımları

---

### [INC-1401] Threat Feed Seed Job & CronJob Zamanlama Hatası (`manifests/20-feed-jobs.yaml`)

#### 1. 🧠 Teşhis Zihniyeti (Bu Semptomu Gördüğünde Nasıl Düşünmelisin?)
* **`CreateContainerConfigError` ile `CrashLoopBackOff` Arasındaki Fark:**
  Bir pod `CreateContainerConfigError` durumunda kaldığında, kıdemli bir SRE **konteyner sürecinin (entrypoint) henüz hiç çalışmadığını** anında bilir. Uygulama logu oluşmaz; çünkü hata Kubelet'in konteyner çalışma zamanını (`containerd`) çağırmadan hemen önce çalıştırdığı `GenerateRunContainerOptions` hazırlık aşamasında gerçekleşmiştir. Kubelet, konteynerin ortam değişkenlerini (`env`) oluştururken referans verilen tüm `ConfigMap` ve `Secret` anahtarlarının varlığını doğrular.
* **Batch Katmanındaki Üç Sıralı Hata (`manifests/20-feed-jobs.yaml`):**
  1. **Hata 1A (Secret Anahtar Adı Uyuşmazlığı):** `Job/threat-db-seed`, `POSTGRES_PASSWORD` değişkenini `Secret/aegis-db-secret` içinden `key: postgres-password` adıyla çekmeye çalışmaktadır. Oysa `manifests/10-core-infra.yaml` (veya kümedeki Secret) incelendiğinde gerçek anahtar adının `database-password` olduğu görülür.
  2. **Neden `kubectl apply` Job Üzerinde Başarısız Olur? (Job Şablon Değişmezliği / Immutability):** `manifests/20-feed-jobs.yaml` dosyasını düzelttikten sonra `kubectl apply` çalıştırdığınızda Kubernetes API sunucusu `Invalid value: ...: field is immutable` hatası verir. Çünkü Kubernetes'te `batch/v1` `Job` nesnelerinin `spec.template` alanı oluşturulduktan sonra değiştirilemez (immutable). Bu nedenle eski Job silinip yenisi oluşturulmalıdır (`kubectl replace --force -f manifests/20-feed-jobs.yaml`).
  3. **Hata 1B ve 1C (Askıya Alınmış CronJob ve Yanlış Redis Servis Adı):** `CronJob/feed-rotator` üzerinde `suspend: true` tanımlıdır; bu ayar `kube-controller-manager` içindeki `cronjob-controller` döngüsünün zamanlanmış işleri tetiklemesini tamamen durdurur. Ayrıca konteyner komutu `redis-cli -h redis-cache` adresine bağlanmaya çalışmaktadır; oysa Katman 0'daki Redis Servisinin gerçek adı `aegis-redis`'tir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Job, CronJob ve ilgili pod durumlarını kontrol edin
kubectl get job,cronjob -n aegis-prod
# Beklenen hatalı çıktı:
# NAME                       COMPLETIONS   DURATION   AGE
# job.batch/threat-db-seed   0/1           4m         4m
#
# NAME                         SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE   AGE
# cronjob.batch/feed-rotator   */2 * * * *   True      0        <none>          4m

kubectl get pods -n aegis-prod -l app.kubernetes.io/name=threat-db-seed
# Beklenen hatalı çıktı:
# NAME                   READY   STATUS                       RESTARTS   AGE
# threat-db-seed-xxxxx   0/1     CreateContainerConfigError   0          4m

# 2. threat-db-seed pod'undaki Kubelet yapılandırma hatasını inceleyin
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=threat-db-seed | grep -A 8 "Events:"
# Beklenen hatalı çıktı:
# Warning  Failed  ...  kubelet  Error: secret "aegis-db-secret" not found or key "postgres-password" not found in secret "aegis-prod/aegis-db-secret"

# 3. aegis-db-secret içindeki mevcut anahtarları ve aegis-prod içindeki servisleri karşılaştırın
kubectl get secret aegis-db-secret -n aegis-prod -o jsonpath='{.data}' && echo ""
# Beklenen çıktı:
# {"database-password":"QWVnaXNTdXBlclNlY3JldDIwMjYh"}

kubectl get svc -n aegis-prod
# Beklenen çıktıda Redis servisinin adının "redis-cache" değil "aegis-redis" olduğu görülür!
```

#### 3. 🛠️ Adım Adım Çözüm (Sırasıyla Yapılacak Tüm İşlemler)
* **Adım 1:** `manifests/20-feed-jobs.yaml` dosyasını açın ve üç hatayı düzeltin:
  1. `Job/threat-db-seed` içinde `secretKeyRef.key` değerini `postgres-password` yerine `database-password` yapın.
  2. `CronJob/feed-rotator` içinde `suspend: true` değerini `suspend: false` yapın.
  3. `CronJob/feed-rotator` komutundaki iki adet `-h redis-cache` ifadesini `-h aegis-redis` olarak değiştirin.

```diff
--- a/manifests/20-feed-jobs.yaml
+++ b/manifests/20-feed-jobs.yaml
@@ -26,7 +26,7 @@ spec:
               valueFrom:
                 secretKeyRef:
                   name: aegis-db-secret
-                  key: postgres-password
+                  key: database-password
           command:
             - sh
             - -c
@@ -62,7 +62,7 @@ metadata:
     app.kubernetes.io/part-of: aegisgrid
 spec:
   schedule: "*/2 * * * *"
-  suspend: true
+  suspend: false
   concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 2
   failedJobsHistoryLimit: 2
@@ -84,4 +84,4 @@ spec:
               command:
                 - sh
                 - -c
-                - "redis-cli -h redis-cache -p 6379 SET aegis:feed:last_sync $(date -u +%Y-%m-%dT%H:%M:%SZ) && redis-cli -h redis-cache -p 6379 INCR aegis:feed:sync_count && echo 'Feed rotation synced successfully.'"
+                - "redis-cli -h aegis-redis -p 6379 SET aegis:feed:last_sync $(date -u +%Y-%m-%dT%H:%M:%SZ) && redis-cli -h aegis-redis -p 6379 INCR aegis:feed:sync_count && echo 'Feed rotation synced successfully.'"
```

* **Adım 2:** Değişmez (immutable) `Job` kaynağını yeniden oluşturmak ve `CronJob` kaynağını güncellemek için `kubectl replace --force` komutunu çalıştırın:
```bash
kubectl replace --force -f manifests/20-feed-jobs.yaml
```

* **Adım 3:** `threat-db-seed` işinin tamamlanmasını bekleyin ve doğrulama komutlarını çalıştırın:
```bash
# 1. threat-db-seed Job kaynağının başarıyla tamamlandığını doğrulayın (1/1)
kubectl wait --for=condition=complete job/threat-db-seed -n aegis-prod --timeout=45s
kubectl get job threat-db-seed -n aegis-prod
# Beklenen çıktı: COMPLETIONS: 1/1

# 2. PostgreSQL threat_signatures tablosunda 3 adet kayıt olduğunu doğrulayın
kubectl exec -n aegis-prod aegis-db-0 -- psql -U aegis_admin -d aegis_intel -tAc "SELECT count(*) FROM threat_signatures;"
# Beklenen çıktı: 3

# 3. feed-rotator CronJob kaynağının aktif olduğunu doğrulayın (SUSPEND: False)
kubectl get cronjob feed-rotator -n aegis-prod
# Beklenen çıktı: SUSPEND: False

# 4. feed-rotator üzerinden manuel bir test işi oluşturup tamamlanmasını bekleyin
kubectl create job --from=cronjob/feed-rotator manual-feed-sync -n aegis-prod && kubectl wait --for=condition=complete job/manual-feed-sync -n aegis-prod --timeout=30s
# Beklenen çıktı: job.batch/manual-feed-sync condition met
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
* **Neden `Job` Şablonları Değiştirilemez (Immutable)?** `Deployment` güncellendiğinde yeni bir `ReplicaSet` oluşturup eski pod'ları kademeli kapatır; ancak `Job` doğrudan tek bir pod şablonu üzerinden başarı/hata sayısı (`succeeded`/`failed`) tutar. Üretimde GitOps (Argo CD / Flux) kullanırken veritabanı migration Job'larında `Replace=true` veya `BeforeHookCreation` politikası kullanılır.
* **Unutulan `suspend: true` Tuzağı:** Planlı veritabanı bakımlarında SRE ekipleri CronJob'ları geçici olarak `suspend: true` yapar. Bakım sonrasında unutulan CronJob'ları yakalamak için Prometheus'ta `kube_cronjob_spec_suspend == 1` alarmı mutlaka tanımlanmalıdır.

---

### [INC-1402] Scanner Worker Init:0/1 Takılması & Startup Probe Çöküşü (`charts/scanner-worker/` & `helm-values/scanner-prod.yaml`)

#### 1. 🧠 Teşhis Zihniyeti (Bu Semptomu Gördüğünde Nasıl Düşünmelisin?)
* **`Init:0/1` Durumunu Okumak:**
  `kubectl get pods` çıktısında `STATUS: Init:0/1` gördüğünüzde, Kubernetes **ana uygulama konteynerini henüz hiç başlatmamıştır**. Init konteynerleri sırayla çalışıp `Exit Code 0` ile bitmeden ana konteyner devreye girmez. Bu aşamada `-c wait-for-db` parametresi vermeden `kubectl logs deploy/scanner-worker` çalıştırmak ana konteyner henüz `PodInitializing` durumunda olduğu için hata verir.
* **`scanner-worker` İçindeki İki Aşamalı Arıza:**
  1. **Hata 2A (InitContainer Veritabanı Port Hatası):** `kubectl logs -n aegis-prod deploy/scanner-worker -c wait-for-db` incelendiğinde `Waiting for database at aegis-db:5433...` mesajı görülür. Chart'ın varsayılan `values.yaml` dosyasında `db.port: 5432` iken, üretim değerleri dosyası `helm-values/scanner-prod.yaml` bunu `db.port: 5433` olarak ezmiştir. PostgreSQL `5432` portunu dinlediği için init konteyneri sonsuz döngüde bekler.
  2. **Hata 2B (Startup Probe Süre Bütçesi Yetersizliği):** `db.port: 5432` düzeltildiğinde init konteyneri tamamlanır ve ana `scanner` konteyneri başlar. Ancak `scanner.py` tehdit imzalarını belleğe yüklemek için **6 saniye** (`time.sleep(6)`) harcadıktan sonra `9090` portunu açmaktadır. `helm-values/scanner-prod.yaml` içinde ise `startupProbe` `periodSeconds: 2` ve `failureThreshold: 2` (`2 × 2 = 4 saniye` toplam bütçe!) olarak ayarlanmıştır. Kubelet 4. saniyede konteyneri `Startup probe failed` diyerek öldürür ve pod `CrashLoopBackOff` döngüsüne girer.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. scanner-worker pod durumunu kontrol edin
kubectl get pods -n aegis-prod -l app.kubernetes.io/name=scanner-worker
# Beklenen hatalı çıktı:
# NAME                              READY   STATUS     RESTARTS   AGE
# scanner-worker-xxxxxxxxxx-xxxxx   0/1     Init:0/1   0          5m

# 2. Bloklayan init konteynerinin loglarını inceleyin
kubectl logs -n aegis-prod deploy/scanner-worker -c wait-for-db --tail=20
# Beklenen hatalı çıktı:
# Waiting for database at aegis-db:5433...
# Waiting for database at aegis-db:5433...

# 3. Aktif Helm sürüm değerlerini inceleyin
helm get values scanner-worker -n aegis-prod
# Beklenen hatalı çıktı:
# USER-SUPPLIED VALUES:
# db:
#   host: aegis-db
#   port: 5433
# replicaCount: 1
# startupProbe:
#   failureThreshold: 2
#   periodSeconds: 2
#   timeoutSeconds: 2

# 4. Chart ConfigMap içindeki scanner.py başlangıç süresini kontrol edin
helm template scanner-worker ./charts/scanner-worker -f helm-values/scanner-prod.yaml -n aegis-prod | grep -A 6 "Initializing scanner engine"
# Beklenen çıktıda HTTP sunucusu başlamadan önce time.sleep(6) çalıştığı görülür!
```

#### 3. 🛠️ Adım Adım Çözüm (Sırasıyla Yapılacak Tüm İşlemler)
* **Adım 1:** `helm-values/scanner-prod.yaml` dosyasını açarak `db.port: 5432` ve `startupProbe.failureThreshold: 10` (20 saniye başlangıç bütçesi) olarak güncelleyin:

```diff
--- a/helm-values/scanner-prod.yaml
+++ b/helm-values/scanner-prod.yaml
@@ -2,8 +2,8 @@ replicaCount: 1
 
 db:
   host: "aegis-db"
-  port: 5433
+  port: 5432
 
 startupProbe:
   periodSeconds: 2
-  failureThreshold: 2
+  failureThreshold: 10
   timeoutSeconds: 2
```

* **Adım 2:** `scanner-worker` Helm sürümünü güncelleyin:
```bash
helm upgrade scanner-worker ./charts/scanner-worker -f helm-values/scanner-prod.yaml -n aegis-prod
```

* **Adım 3:** Rollout işleminin tamamlandığını ve `:9090/healthz` uç noktasının yanıt verdiğini doğrulayın:
```bash
# 1. scanner-worker dağıtımının başarıyla tamamlanmasını bekleyin
kubectl rollout status deploy/scanner-worker -n aegis-prod --timeout=45s
# Beklenen çıktı: deployment "scanner-worker" successfully rolled out

# 2. Küme içinden port 9090 üzerindeki sağlık uç noktasını doğrulayın
kubectl exec -n aegis-prod deploy/scanner-worker -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9090/healthz').read().decode())"
# Beklenen çıktı: {"status": "healthy", "engine": "scanner-worker", "signatures_loaded": 3}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
* **`startupProbe` Neden Kritik Öneme Sahiptir?** Büyük veri önbellekleri, JVM uygulamaları veya yapay zeka modelleri ayağa kalkarken 5–30 saniye sürebilir; ancak başladıktan sonra kilitlenirlerse hızlıca (5–10 saniyede) yeniden başlatılmaları gerekir. `startupProbe` bir kez başarılı olana kadar `livenessProbe` ve `readinessProbe`'u devre dışı bırakır. Başlangıç bütçesini (`periodSeconds × failureThreshold`) her zaman en kötü soğuk başlangıç (cold-start) süresinin 2-3 katı olarak ayarlayın.

---

### [INC-1403] Intel API Readiness Probe Portu & Upstream Servis Keşfi Hatası (`manifests/30-intel-api.yaml`)

#### 1. 🧠 Teşhis Zihniyeti (Bu Semptomu Gördüğünde Nasıl Düşünmelisin?)
* **`Running (0/1 Ready)` ve `RESTARTS: 0` Semptomu:**
  Pod'lar `Running` durumunda ve yeniden başlatma sayısı `0` iken `READY: 0/1` kalıyorsa, **`livenessProbe` başarılı oluyor ancak `readinessProbe` başarısız oluyordur**. Readiness probu başarısız olduğunda Kubelet konteyneri öldürmez; ancak pod'u `Ready=False` olarak işaretler ve `PodDisruptionBudget/intel-api-pdb` (`minAvailable: 1`) `ALLOWED DISRUPTIONS: 0` durumuna düşerek düğüm bakımlarını kilitler.
* **TCP `connection refused` ile `HTTP 503` Arasındaki Fark:**
  1. **Hata 3A (Yanlış Probe Portu -> TCP `connection refused`):** `manifests/30-intel-api.yaml` içinde uygulama `8000` portunu dinlerken (`PORT: "8000"`, `containerPort: 8000`, `livenessProbe.httpGet.port: 8000`), `readinessProbe.httpGet.port: 8080` olarak tanımlanmıştır. `8080` portunu dinleyen bir süreç olmadığı için çekirdek TCP `RST` (`connection refused`) döndürür.
  2. **Hata 3B (Yanlış Upstream Servis Adı -> `HTTP 503`):** Readiness portu `8000` yapıldığında Kubelet `/ready` uç noktasına ulaşır; ancak `/ready` kodu PostgreSQL (`aegis-db:5432`), Redis (`aegis-redis:6379`) ve `http://${SCANNER_HOST}:${SCANNER_PORT}/healthz` adreslerini kontrol eder. `ConfigMap/intel-api-config` içinde `SCANNER_HOST: "scanner-service"` yazılmıştır; oysa INC-1402'deki gerçek servis adı `"scanner-worker"`'dır. CoreDNS bu adı çözemediği için `/ready` `HTTP 503` döner.
  3. **Neden `kubectl rollout restart` Şarttır?** `SCANNER_HOST` pod'a `envFrom: configMapRef` ile ortam değişkeni olarak aktarıldığı için ConfigMap güncellendikten sonra çalışan pod'ların yeniden başlatılması gerekir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. intel-api pod ve PDB durumlarını kontrol edin
kubectl get pods,pdb -n aegis-prod -l app.kubernetes.io/name=intel-api
# Beklenen hatalı çıktı:
# NAME                             READY   STATUS    RESTARTS   AGE
# pod/intel-api-xxxxxxxxxx-xxxxx   0/1     Running   0          6m
# pod/intel-api-xxxxxxxxxx-yyyyy   0/1     Running   0          6m
#
# NAME                                        MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# poddisruptionbudget.policy/intel-api-pdb    1               N/A               0                     6m

# 2. Pod readiness probe tanımını ve hata olaylarını inceleyin
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=intel-api | grep -A 10 "Readiness:"
kubectl describe pod -n aegis-prod -l app.kubernetes.io/name=intel-api | grep -A 10 "Events:"
# Beklenen hatalı çıktı:
# Readiness: http-get http://:8080/ready delay=3s timeout=2s period=5s #success=1 #failure=3
# Warning  Unhealthy  ...  kubelet  Readiness probe failed: Get "http://10.244.x.x:8080/ready": dial tcp 10.244.x.x:8080: connect: connection refused

# 3. ConfigMap ortam değişkenlerini kümedeki gerçek Servis adlarıyla karşılaştırın
kubectl get configmap intel-api-config -n aegis-prod -o yaml | grep -E "PORT|HOST"
# Beklenen hatalı çıktı:
#   SCANNER_HOST: scanner-service   <-- Hatalı servis adı!

kubectl get svc -n aegis-prod
# Beklenen çıktıda servisin gerçek adının "scanner-worker" olduğu görülür!
```

#### 3. 🛠️ Adım Adım Çözüm (Sırasıyla Yapılacak Tüm İşlemler)
* **Adım 1:** `manifests/30-intel-api.yaml` dosyasını düzenleyin:
  1. `ConfigMap/intel-api-config` içinde `SCANNER_HOST: "scanner-service"` değerini `SCANNER_HOST: "scanner-worker"` yapın.
  2. `Deployment/intel-api` içinde `readinessProbe.httpGet.port` değerini `8080` yerine `8000` yapın.

```diff
--- a/manifests/30-intel-api.yaml
+++ b/manifests/30-intel-api.yaml
@@ -12,7 +12,7 @@ data:
   DB_PORT: "5432"
   REDIS_HOST: "aegis-redis"
   REDIS_PORT: "6379"
-  SCANNER_HOST: "scanner-service"
+  SCANNER_HOST: "scanner-worker"
   SCANNER_PORT: "9090"
   REQUIRED_GATEWAY_TOKEN: "aegis-verified"
   server.py: |
@@ -140,7 +140,7 @@ spec:
           readinessProbe:
             httpGet:
               path: /ready
-              port: 8080
+              port: 8000
             initialDelaySeconds: 3
             periodSeconds: 5
             timeoutSeconds: 2
```

* **Adım 2:** Manifestoyu uygulayın ve yeni ConfigMap ortam değişkenlerinin yüklenmesi için `deploy/intel-api` dağıtımını yeniden başlatın:
```bash
kubectl apply -f manifests/30-intel-api.yaml
kubectl rollout restart deploy/intel-api -n aegis-prod
```

* **Adım 3:** Her iki replikanın `1/1 Ready` olduğunu ve `/ready` uç noktasının HTTP 200 döndüğünü doğrulayın:
```bash
# 1. intel-api Deployment rollout işleminin tamamlanmasını bekleyin (2/2 Ready)
kubectl rollout status deploy/intel-api -n aegis-prod --timeout=45s

# 2. Pod içinden /ready uç noktasının HTTP 200 JSON yanıtı döndüğünü doğrulayın
kubectl exec -n aegis-prod deploy/intel-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/ready').read().decode())"
# Beklenen çıktı: {"status": "ready", "db": "connected", "redis": "connected", "scanner": "connected"}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
* **Yüzeysel (Shallow) Liveness vs Derin (Deep) Readiness Kontrolü:** `intel-api` servisinde `/healthz` (`livenessProbe`) yalnızca HTTP sunucusunun ayakta olduğunu kontrol ederken, `/ready` (`readinessProbe`) veritabanı, Redis ve `scanner-worker` bağlantılarını denetler. Bağımlılık kontrollerini asla `livenessProbe` içine koymayın; aksi halde alt katmandaki anlık bir ağ gecikmesi tüm API pod'larınızın aynı anda yeniden başlatılmasına (cascading restart) yol açar!

---

### [INC-1404] Intel API Servis Yönlendirme Kara Deliği & Node-Shield DaemonSet Toleration Hatası (`manifests/40-security-and-daemon.yaml`)

#### 1. 🧠 Teşhis Zihniyeti (Bu Semptomu Gördüğünde Nasıl Düşünmelisin?)
* **Neden Pod İçinde `localhost:8000/ready` Çalışırken Küme İçinde `http://intel-api:8000/ready` Reddedilir?**
  INC-1403'te her iki `intel-api` pod'unun `1/1 Ready` olduğunu ve `:8000/ready` üzerinde yanıt verdiğini kanıtladık. Buna rağmen `aegis-gateway` içinden çalıştırılan `wget -qO- -T 3 http://intel-api:8000/ready` komutu anında `wget: can't connect to remote host: Connection refused` hatası vermektedir.
  Bir pod yerel olarak sağlıklı çalışırken Kubernetes `Service` adresi üzerinden ulaşılamıyorsa, kıdemli bir SRE doğrudan **`Service` kaynağının `selector`, `port`, `targetPort` ve `Endpoints` / `EndpointSlice` alanlarını** inceler.
* **Servis ve Düğüm Güvenliği Katmanındaki İki Hatanın Analizi (`manifests/40-security-and-daemon.yaml`):**
  1. **Hata 4A (`Service/intel-api` Seçici Etiket Sapması ve `targetPort` Uyuşmazlığı):**
     - İlk olarak, `Service/intel-api` içinde `selector.app.kubernetes.io/name: intel-backend` tanımlanmıştır; oysa `intel-api` pod'larının gerçek etiketi `app.kubernetes.io/name: intel-api`'dir. Hiçbir pod eşleşmediği için `Endpoints: <none>` oluşur.
     - İkinci olarak, seçici etiket düzeltilse bile `Service/intel-api` içinde `targetPort: 8080` tanımlanmıştır; oysa `intel-api` konteynerleri `8000` portunu dinlemektedir. `targetPort: 8000` olarak düzeltilmelidir.
  2. **Hata 4B (`node-shield` DaemonSet Taint Toleration `effect` Uyuşmazlığı):** Kümede 3 düğüm vardır ve `Node-3` üzerinde `workload=database:NoSchedule` taint'i bulunmaktadır. `DaemonSet/node-shield` içinde tanımlanan toleration `effect: NoExecute` değerine sahiptir. Kubernetes zamanlayıcısında `effect: NoExecute` yalnızca `NoExecute` taint'ini tolere eder; `NoSchedule` taint'ini tolere etmez. Bu yüzden `node-shield` `Node-3` üzerine zamanlanamaz (`DESIRED: 2`).

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. aegis-gateway pod'undan intel-api servisine bağlantı hatasını gözlemleyin
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready || true
# Beklenen hatalı çıktı:
# wget: can't connect to remote host (10.96.x.x): Connection refused

# 2. Service/intel-api selector, targetPort ve Endpoints durumunu pod etiketleriyle karşılaştırın
kubectl describe svc intel-api -n aegis-prod
# Beklenen hatalı çıktı:
# Selector:          app.kubernetes.io/name=intel-backend   <-- Yanlış etiket!
# Port:              http  8000/TCP
# TargetPort:        8080/TCP                               <-- Yanlış targetPort!
# Endpoints:         <none>

kubectl get pods -n aegis-prod -l app.kubernetes.io/name=intel-api --show-labels
# Beklenen çıktıda gerçek etiketin app.kubernetes.io/name=intel-api olduğu görülür

# 3. DaemonSet durumunu ve 3 düğümdeki taint tanımlarını inceleyin
kubectl get ds node-shield -n aegis-prod
# Beklenen hatalı çıktı:
# NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
# node-shield   2         2         2       2            2           <none>          7m

kubectl get nodes -o custom-columns=NAME:.metadata.name,TIER:.metadata.labels.tier,TAINTS:.spec.taints
# Beklenen çıktıda Node-3 taint efektinin NoSchedule (workload=database:NoSchedule) olduğu görülür
```

#### 3. 🛠️ Adım Adım Çözüm (Sırasıyla Yapılacak Tüm İşlemler)
* **Adım 1:** `manifests/40-security-and-daemon.yaml` dosyasını düzenleyin:
  1. `Service/intel-api` içinde `targetPort: 8080` değerini `targetPort: 8000` ve `selector.app.kubernetes.io/name: intel-backend` değerini `app.kubernetes.io/name: intel-api` yapın.
  2. `DaemonSet/node-shield` içinde toleration `effect: NoExecute` değerini `effect: NoSchedule` yapın.

```diff
--- a/manifests/40-security-and-daemon.yaml
+++ b/manifests/40-security-and-daemon.yaml
@@ -11,10 +11,10 @@ spec:
   ports:
     - name: http
       port: 8000
-      targetPort: 8080
+      targetPort: 8000
       protocol: TCP
   selector:
-    app.kubernetes.io/name: intel-backend
+    app.kubernetes.io/name: intel-api
 ---
 apiVersion: apps/v1
 kind: DaemonSet
@@ -40,7 +40,7 @@ spec:
         - key: workload
           operator: Equal
           value: database
-          effect: NoExecute
+          effect: NoSchedule
       containers:
         - name: shield-agent
           image: docker.io/library/busybox:1.36
```

* **Adım 2:** Güncellenen manifestoyu uygulayın:
```bash
kubectl apply -f manifests/40-security-and-daemon.yaml
```

* **Adım 3:** `node-shield` DaemonSet'inin 3 düğümde (`3/3`) çalıştığını ve `aegis-gateway` -> `intel-api:8000` erişiminin açıldığını doğrulayın:
```bash
# 1. node-shield DaemonSet'inin 3 düğümün tamamında Ready olduğunu doğrulayın
kubectl rollout status ds/node-shield -n aegis-prod --timeout=45s
kubectl get ds node-shield -n aegis-prod
# Beklenen çıktı: DESIRED: 3, CURRENT: 3, READY: 3

# 2. aegis-gateway pod'unun Service/intel-api üzerinden intel-api:8000/ready adresine erişebildiğini doğrulayın
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready
# Beklenen çıktı: {"status": "ready", "db": "connected", "redis": "connected", "scanner": "connected"}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
* **İsimlendirilmiş (Named) TargetPort Kullanımı:** `Service` tanımlarında sabit sayısal `targetPort: 8000` yerine pod üzerindeki port adını (`targetPort: http`) referans vermek, uygulama ekibi konteyner portunu değiştirdiğinde servis yönlendirmesinin kopmasını önler.
* **Güvenlik Ajanları İçin Joker (Wildcard) Taint Toleration:** Küme genelindeki güvenlik ve log DaemonSet'lerinde (Falco, Cilium, Node-Problem-Detector) `tolerations: [{operator: Exists}]` tanımlamak, düğümlere hangi özel taint eklenirse eklensin ajanın her düğümde çalışmasını garanti eder.

---

### [INC-1405] Edge Gateway 504/502 Upstream Hatası, 403 Token Reddi & ConfigMap Yenileme (`helm-values/gateway-prod.yaml` & `manifests/50-ingress.yaml`)

#### 1. 🧠 Teşhis Zihniyeti (Bu Semptomu Gördüğünde Nasıl Düşünmelisin?)
* **Edge Katmanında `504 Gateway Time-out` / `502 Bad Gateway` ve `403 Forbidden` Ayrımı:**
  1. **Hata 5A (`504 Gateway Time-out` / `502 Bad Gateway` — L4 Upstream Port Hatası):** `Service/intel-api` düzeltildikten sonra `aegis-gateway` üzerinden `http://localhost:8080/api/v1/threats` çağrıldığında `504 Gateway Time-out` (veya `502 Bad Gateway`) döner. Çünkü `helm-values/gateway-prod.yaml` içinde `upstream.port: 8080` tanımlıdır; oysa `intel-api` Servisi `8000` portunu dinlemektedir. OCI VCN-Native CNI üzerinde ClusterIP'nin tanımlı olmayan bir portuna (`8080`) giden paketler `kube-proxy` DNAT kuralıyla eşleşmediği için Nginx'in `proxy_connect_timeout 3s` süresinde zaman aşımına uğrar.
  2. **Hata 5B (`403 Forbidden` — L7 Güvenlik Başlığı Reddi):** `charts/aegis-gateway/templates/configmap.yaml` içinde Nginx her isteğe `proxy_set_header X-Aegis-Token "{{ .Values.gateway.securityToken }}";` başlığını ekler. `helm-values/gateway-prod.yaml` içinde bu değer `"legacy-unverified"` olarak kalmıştır; oysa `intel-api` (`REQUIRED_GATEWAY_TOKEN`) `"aegis-verified"` beklemektedir. Token eşleşmediğinde `intel-api` `HTTP 403 Forbidden` (`untrusted proxy: invalid or missing X-Aegis-Token header`) döndürür.
  3. **Neden `helm upgrade` Sonrasında `kubectl rollout restart` Zorunludur?** `charts/aegis-gateway/templates/deployment.yaml` incelendiğinde ConfigMap'in `/etc/nginx/nginx.conf` dosyasına `subPath: nginx.conf` ile bağlandığı görülür. Kubernetes'te **`subPath` kullanılan volume mount'lar Kubelet tarafından asla otomatik güncellenmez**! Üstelik Nginx de başlangıçta okuduğu konfigürasyonu bellekte tutar. Bu nedenle `helm upgrade` sonrasında `kubectl rollout restart deploy/aegis-gateway -n aegis-prod` çalıştırmak zorunludur.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Mevcut Helm değerlerini ve gateway ConfigMap içeriğini inceleyin
helm get values aegis-gateway -n aegis-prod
# Beklenen hatalı çıktı:
# USER-SUPPLIED VALUES:
# gateway:
#   securityToken: legacy-unverified
# replicaCount: 2
# upstream:
#   host: intel-api
#   port: 8080

kubectl get configmap aegis-gateway-config -n aegis-prod -o yaml | grep -E "proxy_set_header X-Aegis-Token|proxy_pass"
# Beklenen hatalı çıktı:
#   proxy_set_header X-Aegis-Token "legacy-unverified";
#   proxy_pass http://intel-api:8080/api/v1/threats;

# 2. Küme içinden gateway yanıtını test edin ve Nginx loglarını kontrol edin
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -S -O- http://localhost:8080/api/v1/threats 2>&1 || true
# Beklenen hatalı çıktı:
#   HTTP/1.1 504 Gateway Time-out (veya 502 Bad Gateway)

kubectl logs -n aegis-prod deploy/aegis-gateway --tail=20
# Beklenen hatalı çıktıda port 8080 upstream bağlantı zaman aşımı / reddi görülür

# 3. intel-api-config içindeki beklenen güvenlik token'ını ve Ingress kaynağını inceleyin
kubectl get configmap intel-api-config -n aegis-prod -o yaml | grep REQUIRED_GATEWAY_TOKEN
# Beklenen çıktı:
#   REQUIRED_GATEWAY_TOKEN: aegis-verified

kubectl get ingress aegis-ingress -n aegis-prod -o yaml
```

#### 3. 🛠️ Adım Adım Çözüm (Sırasıyla Yapılacak Tüm İşlemler)
* **Adım 1:** `helm-values/gateway-prod.yaml` dosyasını açarak `upstream.port: 8000` ve `gateway.securityToken: "aegis-verified"` olarak güncelleyin:

```diff
--- a/helm-values/gateway-prod.yaml
+++ b/helm-values/gateway-prod.yaml
@@ -2,7 +2,7 @@ replicaCount: 2
 
 upstream:
   host: "intel-api"
-  port: 8080
+  port: 8000
 
 gateway:
-  securityToken: "legacy-unverified"
+  securityToken: "aegis-verified"
```

* **Adım 2:** `aegis-gateway` Helm sürümünü güncelleyin ve yeni ConfigMap'in Nginx pod'larına yansıması için `deploy/aegis-gateway` dağıtımını yeniden başlatın:
```bash
helm upgrade aegis-gateway ./charts/aegis-gateway -f helm-values/gateway-prod.yaml -n aegis-prod
kubectl rollout restart deploy/aegis-gateway -n aegis-prod
kubectl rollout status deploy/aegis-gateway -n aegis-prod --timeout=45s
```

* **Adım 3:** Küme içinden ve OCI LoadBalancer dış IP'si üzerinden uçtan uca tehdit istihbaratı yanıtını doğrulayın:
```bash
# 1. Küme içinden aegis-gateway üzerinden yapılan isteğin 3 tehdit imzasıyla HTTP 200 döndüğünü doğrulayın
kubectl exec -n aegis-prod deploy/aegis-gateway -- wget -qO- http://localhost:8080/api/v1/threats
# Beklenen çıktı:
# {"platform": "AegisGrid", "status": "operational", "active_signatures": ["SQLI-9001", "XSS-9002", "RCE-9003"], "scanner_engine": "online"}

# 2. OCI LoadBalancer dış IP'si (EXTERNAL-IP) üzerinden uçtan uca erişimi doğrulayın
LB_IP=$(kubectl get svc aegis-gateway -n aegis-prod -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Gateway LoadBalancer IP: ${LB_IP:-Pending}"
if [ -n "${LB_IP}" ]; then
  curl -s -H "Host: aegis.local" "http://${LB_IP}/api/v1/threats"
fi
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
* **Kubernetes `subPath` ConfigMap Tuzağı:** Bir ConfigMap tüm dizin olarak bağlandığında Kubelet `..data` sembolik bağlantısını (symlink) atomik olarak değiştirerek dosyaları ~60-90 saniyede günceller. Ancak `subPath` kullanıldığında Linux çekirdeği konteyner oluşturulurken tekil dosyanın o anki inode'unu bağlar (bind mount) ve pod yeniden oluşturulana kadar dosya içeriği asla güncellenmez!

---

## 🏁 Uçtan Uca Üretim Sağlık Kontrolü (Bottom-Up Kontrol Listesi)

Tüm biletler çözüldükten sonra **AegisGrid** platformunun %100 sağlıklı çalıştığını doğrulamak için `kubectl` istemcinizden aşağıdaki betiği çalıştırın:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="aegis-prod"
echo "=================================================================="
echo " 🏁 AEGISGRID UÇTAN UCA ÜRETİM SAĞLIK KONTROLÜ (aegis-prod)"
echo "=================================================================="

echo "--> [Katman 0] Çekirdek Veritabanı ve Önbellek Kontrolü (PostgreSQL 16 & Redis 7.2)..."
kubectl get statefulset aegis-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -qx "1"
kubectl get deploy aegis-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -qx "1"
echo "    ✅ aegis-db (1/1) & aegis-redis (1/1) Sağlıklı."

echo "--> [INC-1401] Threat DB Seed Job & Feed Rotator CronJob Kontrolü..."
kubectl get job threat-db-seed -n "${NS}" -o jsonpath='{.status.succeeded}' | grep -qx "1"
SIG_COUNT=$(kubectl exec -n "${NS}" aegis-db-0 -- psql -U aegis_admin -d aegis_intel -tAc "SELECT count(*) FROM threat_signatures;" | tr -d '[:space:]')
[ "${SIG_COUNT}" = "3" ]
kubectl get cronjob feed-rotator -n "${NS}" -o jsonpath='{.spec.suspend}' | grep -qx "false"
echo "    ✅ threat-db-seed Tamamlandı (DB'de 3 imza mevcut) & feed-rotator aktif."

echo "--> [INC-1402] Scanner Worker Deployment & Startup Probe Kontrolü..."
kubectl rollout status deploy/scanner-worker -n "${NS}" --timeout=30s >/dev/null
SCAN_RESP=$(kubectl exec -n "${NS}" deploy/scanner-worker -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:9090/healthz').read().decode())")
echo "${SCAN_RESP}" | grep -q '"status": "healthy"'
echo "    ✅ scanner-worker (1/1 Ready) :9090/healthz üzerinde yanıt veriyor."

echo "--> [INC-1403] Intel API Readiness, Upstream Keşfi & PDB Kontrolü..."
kubectl rollout status deploy/intel-api -n "${NS}" --timeout=30s >/dev/null
API_READY=$(kubectl exec -n "${NS}" deploy/intel-api -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8000/ready').read().decode())")
echo "${API_READY}" | grep -q '"status": "ready"'
echo "    ✅ intel-api (2/2 Ready) DB, Redis ve scanner-worker ile bağlantılı."

echo "--> [INC-1404] Intel API Servis Yönlendirmesi & Node-Shield DaemonSet Kontrolü..."
DESIRED_DS=$(kubectl get ds node-shield -n "${NS}" -o jsonpath='{.status.desiredNumberScheduled}')
READY_DS=$(kubectl get ds node-shield -n "${NS}" -o jsonpath='{.status.numberReady}')
[ "${DESIRED_DS}" = "3" ] && [ "${READY_DS}" = "3" ]
kubectl exec -n "${NS}" deploy/aegis-gateway -- wget -qO- -T 3 http://intel-api:8000/ready | grep -q '"status": "ready"'
echo "    ✅ node-shield 3/3 düğümde çalışıyor & Service/intel-api gateway -> intel-api:8000 trafiğini yönlendiriyor."

echo "--> [INC-1405] Edge Gateway L7 Yönlendirme & Tehdit İmzaları Yanıt Kontrolü..."
THREATS_JSON=$(kubectl exec -n "${NS}" deploy/aegis-gateway -- wget -qO- http://localhost:8080/api/v1/threats)
echo "${THREATS_JSON}" | grep -q "SQLI-9001"
echo "${THREATS_JSON}" | grep -q "XSS-9002"
echo "${THREATS_JSON}" | grep -q "RCE-9003"
echo "    ✅ aegis-gateway SQLI-9001, XSS-9002, RCE-9003 imzalarıyla HTTP 200 döndürdü."

LB_IP=$(kubectl get svc aegis-gateway -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -n "${LB_IP}" ]; then
  echo "--> [Dış LoadBalancer Kontrolü] http://${LB_IP}/api/v1/threats test ediliyor..."
  curl -sf -H "Host: aegis.local" "http://${LB_IP}/api/v1/threats" | grep -q "SQLI-9001"
  echo "    ✅ Dış LoadBalancer (${LB_IP}) doğrulandı!"
fi

echo "=================================================================="
echo " 🎉 TÜM AEGISGRID ÜRETİM SİSTEMLERİ %100 SAĞLIKLI VE DEVREDE!"
echo "=================================================================="
```
