# 🇬🇧 English Version / Comprehensive SRE Post-Mortem & Incident Remediation Guide: Lab 12 (Vortex)

This guide documents the root cause analyses (RCA), Linux kernel and Kubernetes control plane mechanics, forensic diagnostic commands, step-by-step remediation procedures, and enterprise SRE production takeaways for the cascading outage across the **Vortex (`vortex-prod` namespace)** distributed microservices and Traefik Ingress platform.

> [!NOTE]
> Vortex is engineered with a **100% linear, bottom-up cascading dependency chain**. Each incident is strictly unmasked only when the preceding layer has been stabilized. Follow the tickets sequentially.

---

## 📑 Incident Resolution Matrix

| Ticket | Impacted Component | Symptom | Root Cause | Fix Strategy | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1201** | `traefik` (Helm Release) | `CrashLoopBackOff` (0/1 Ready), `bind: permission denied` | Non-root UID 1000 attempting to bind privileged port 80 (<1024) | Set `ports.web.port: 8000` & `targetPort: 8000` | Linux Kernel Socket Permissions & Kubelet SecurityContext | P1 - Blocker |
| **INC-1202** | `vortex-ingress` (Ingress) | `HTTP 404 Not Found` (`/api/v1/auth/verify`) | `pathType: Exact` rejects sub-paths; unstripped prefix forwarded to backend | Change to `pathType: Prefix` and align path handling | Ingress Controller Rule Matcher & L7 Path Dispatcher | P1 - Blocker |
| **INC-1203** | `auth-service` (Deployment) | `CreateContainerConfigError` then `HTTP 503` | Secret key mismatch (`db-password` vs `database-password`) & wrong Redis host (`cache-service`) | Secret key: `database-password`, `REDIS_HOST: vortex-redis` | Kubelet Secret Resolver & CoreDNS Service Discovery | P1 - Blocker |
| **INC-1204** | `payment-service` (Deployment) | `2/3 Ready`, 1 replica permanently `Pending` | 2-zone web pool with `DoNotSchedule` & `maxSkew: 1` deadlocks 3rd replica (Node-3 tainted) | Change to `whenUnsatisfiable: ScheduleAnyway` | `kube-scheduler` TopologySpread Filter & Scoring Plugins | P1 - Blocker |
| **INC-1205** | `notification-dispatcher` (CronJob) | `OOMKilled` (Exit Code 137) & uncontrolled pod sprawl | 45MB buffer allocated under `limits.memory: 32Mi` & unbounded `concurrencyPolicy: Allow` | `limits.memory: 128Mi`, `concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 120` | Linux Kernel cgroup v2 Memory Controller & Job Controller | P2 - High |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-1201] Traefik Ingress Controller Failed Startup (CrashLoopBackOff & Bind Permission Denied)

#### 1. 🧠 Diagnostic Mindset
- **Isolating Container Crash Roots:**
  When an Ingress Controller pod enters `CrashLoopBackOff`, the SRE's first instinct is inspecting container termination logs via `kubectl logs`. The console logs clearly highlight:
  `Error loading entryPoint web: error starting listener: listen tcp :80: bind: permission denied`
- **Linux Kernel Privileged Port Security Model:**
  In POSIX and Linux network stacks, ports `1` through `1023` are classified as privileged ports. By default, only the root user (`UID 0`) or processes endowed with the `CAP_NET_BIND_SERVICE` capability are permitted to make the `bind()` system call on ports below 1024.
- **Configuration Contradiction:**
  Inspecting `helm-values/traefik-prod.yaml` reveals two conflicting security declarations:
  1. `securityContext.runAsNonRoot: true` and `securityContext.runAsUser: 1000` mandate non-root execution.
  2. `ports.web.port: 80` commands Traefik to bind directly to privileged port 80.
  When the non-root process attempts to open `0.0.0.0:80`, the Linux kernel rejects the syscall with `EACCES (Permission denied)`, terminating Traefik with exit code 1.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect Traefik pod state:
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=traefik
# Observation: STATUS: CrashLoopBackOff or Error, RESTARTS increasing.

# 2. View termination logs:
kubectl logs -n vortex-prod -l app.kubernetes.io/name=traefik --tail=25
# Observation: listen tcp :80: bind: permission denied

# 3. Inspect Helm values for port and security context:
cat helm-values/traefik-prod.yaml
# Observation: runAsUser: 1000 vs ports.web.port: 80
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `helm-values/traefik-prod.yaml`:
   - Change `ports.web.port` from `80` to unprivileged port `8000`.
   - Change `ports.web.targetPort` to `8000`:
```diff
 ports:
   web:
-    port: 80
-    targetPort: 80
+    port: 8000
+    targetPort: 8000
     nodePort: 30080
```
> [!NOTE]
> The Traefik Kubernetes Service (`charts/traefik/templates/service.yaml`) exposes port 80 externally and routes traffic to `targetPort: {{ .Values.ports.web.port }}`. Changing the container port to 8000 maintains external port 80 access seamlessly without permission issues.

2. Upgrade the Helm release:
```bash
helm upgrade --install traefik ./charts/traefik   -f helm-values/traefik-prod.yaml   -n vortex-prod
```

3. Verify Traefik pod is healthy:
```bash
kubectl rollout status deployment/traefik -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=traefik
# Expected: STATUS: Running, READY: 1/1, RESTARTS: 0

# Check internal Traefik health endpoint:
kubectl exec -n vortex-prod deploy/traefik -- traefik healthcheck --ping.entrypoint=web
# Expected: OK (Exit code 0)
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Non-Root Pod Security Standards (PSS):** Modern hardening frameworks (CIS Benchmark, PSS Restricted) enforce non-root execution (`runAsNonRoot: true`, `allowPrivilegeEscalation: false`).
- **Unprivileged Ports + Service Mapping:** The battle-tested industry pattern for non-root ingress controllers (NGINX, Traefik, Envoy) is binding container processes to unprivileged high ports (`8000`, `8080`, `8443`) and mapping external ports `80/443` via Kubernetes Service `targetPort`.

---

### [INC-1202] Traefik Ingress Returns HTTP 404 Not Found on API Routes

#### 1. 🧠 Diagnostic Mindset
- **Pinpointing 404 Origins (Controller vs Backend):**
  When requests to `http://vortex.local/api/v1/auth/verify` return `HTTP 404 Not Found`, SREs distinguish whether the error originated from the Ingress Controller or the backend service.
- **Root Cause Analysis:**
  Inspecting `manifests/20-ingress.yaml` exposes two distinct issues:
  1. `pathType: Exact` Trap: The ingress rule defines `path: /api/v1/auth` with `pathType: Exact`. In Kubernetes Ingress semantics, `Exact` matches strictly the literal string `/api/v1/auth`. Sub-paths like `/api/v1/auth/verify` do not match, causing Traefik to return `404 page not found`.
  2. Sub-path Routing: Changing to `pathType: Prefix` matches all sub-paths.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Send test request through Traefik ClusterIP:
TRAEFIK_IP=$(kubectl get svc traefik -n vortex-prod -o jsonpath='{.spec.clusterIP}')
curl -v -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/auth/verify"
# Observation: HTTP/1.1 404 Not Found ("404 page not found")

# 2. Inspect Ingress manifest:
kubectl get ingress vortex-ingress -n vortex-prod -o yaml
# Observation: pathType: Exact
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/20-ingress.yaml`:
   - Change `pathType: Exact` to `pathType: Prefix`:
```diff
        http:
          paths:
            - path: /api/v1/auth
-            pathType: Exact
+            pathType: Prefix
              backend:
                service:
                  name: auth-service
                  port:
                    number: 8081
```

2. Apply the updated Ingress manifest:
```bash
kubectl apply -f manifests/20-ingress.yaml
```

3. Confirm Traefik reloaded configuration:
```bash
kubectl logs -n vortex-prod -l app.kubernetes.io/name=traefik --tail=15 | grep -i "Configuration received"
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **`pathType` Standardization (Kubernetes v1.18+):**
  - `Exact`: Exact byte-for-byte string match.
  - `Prefix`: Hierarchical `/` path matching. Essential for microservice API gateway routing.
  - `ImplementationSpecific`: Relies on controller-specific logic.

---

### [INC-1203] Auth Service Pod Unhealthy & Returning HTTP 500 / 503 on Dependencies

#### 1. 🧠 Diagnostic Mindset
- **Two-Stage Dependency Failure:**
  `auth-service` suffers from two sequential blockers:
  1. **Config Injection Failure:** The pod is stuck in `CreateContainerConfigError`. `describe pod` shows:
     `Error: Couldn't find key db-password in Secret vortex-prod/vortex-db-secret`
     The Secret actually contains `database-password`.
  2. **Runtime Discovery Failure:** Once the secret is resolved, the pod starts but fails readiness (`0/1 Ready`, HTTP 503). ConfigMap defines `REDIS_HOST: "cache-service"`, whereas the real Service name in the cluster is `vortex-redis`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check pod status:
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=auth-service
# Observation: STATUS: CreateContainerConfigError

# 2. View pod events:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=auth-service | grep -A 5 Events
# Observation: Warning Failed Couldn't find key db-password in Secret vortex-prod/vortex-db-secret

# 3. Check actual Secret keys:
kubectl get secret vortex-db-secret -n vortex-prod -o jsonpath='{.data}'
# Observation: {"database-password":"..."}

# 4. Check cluster Services:
kubectl get svc -n vortex-prod
# Observation: vortex-redis (Port 6379)
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/30-auth-service.yaml`:
   - In ConfigMap: Change `REDIS_HOST: "cache-service"` to `REDIS_HOST: "vortex-redis"`.
   - In Deployment: Change secretKeyRef `key: db-password` to `key: database-password`:
```diff
  data:
    PORT: "8081"
    DB_HOST: "vortex-db"
    DB_PORT: "5432"
    DB_NAME: "vortex_db"
    DB_USER: "vortex_admin"
-  REDIS_HOST: "cache-service"
+  REDIS_HOST: "vortex-redis"
    REDIS_PORT: "6379"
...
            env:
              - name: DB_PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: vortex-db-secret
-                  key: db-password
+                  key: database-password
```

2. Apply manifests and restart rollout:
```bash
kubectl apply -f manifests/30-auth-service.yaml
kubectl rollout restart deployment/auth-service -n vortex-prod
```

3. Verify pod health and probe endpoints:
```bash
kubectl rollout status deployment/auth-service -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=auth-service
# Expected: STATUS: Running, READY: 1/1, RESTARTS: 0

# Test internal ready endpoint:
kubectl exec -n vortex-prod deploy/auth-service -- python3 -c '
import urllib.request, json
data = json.loads(urllib.request.urlopen("http://localhost:8081/ready").read().decode())
print(json.dumps(data, indent=2))
assert data["ready"] is True
'
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Fail-Fast Configuration Contracts:** Defaulting to `optional: false` in `secretKeyRef` is a best-practice fail-fast guardrail that protects databases against invalid unauthenticated connection spam.
- **Centralized Service Discovery:** Microservices should utilize predictable DNS naming conventions backed by automated linting (e.g. Helm values schema validation).

---

### [INC-1204] Payment Service Pods Multi-Zone TopologySpread Deadlock (Pending Pod)

#### 1. 🧠 Diagnostic Mindset
- **Analyzing the Pending Replica:**
  `payment-service` requests 3 replicas (`replicas: 3`), but only 2/3 are ready. One replica remains permanently `Pending`.
- **Kube-Scheduler Filter Rejection:**
  `kubectl describe pod` reveals:
  `0/3 nodes are available: 1 node(s) had untolerated taint {workload: database}, 2 node(s) didn't match pod topology spread constraints.`
- **Topology Deadlock Mathematics:**
  Our cluster layout:
  - Node-1 (Zone A): `tier=web`
  - Node-2 (Zone B): `tier=web`
  - Node-3 (Zone C): `tier=database`, tainted `workload=database:NoSchedule`
  The constraint enforces `maxSkew: 1` with `whenUnsatisfiable: DoNotSchedule` across `topologyKey: topology.kubernetes.io/zone`.
  Placing 2 pods in Zone A and Zone B leaves the 3rd pod unschedulable because placing it in either Zone A or B would result in a skew of 2 (relative to Zone C with 0 pods), which exceeds `maxSkew: 1`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect deployment readiness:
kubectl get deployment payment-service -n vortex-prod
# Observation: READY: 2/3

# 2. View scheduling failure reason:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=payment-service | grep -A 5 "FailedScheduling"
# Observation: 2 node(s) didn't match pod topology spread constraints.

# 3. Inspect node zones and taints:
kubectl get nodes -L topology.kubernetes.io/zone,tier
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/40-payment-service.yaml`:
   - Change `whenUnsatisfiable: DoNotSchedule` to `whenUnsatisfiable: ScheduleAnyway` (soft scheduling score):
```diff
        topologySpreadConstraints:
          - maxSkew: 1
            topologyKey: topology.kubernetes.io/zone
-          whenUnsatisfiable: DoNotSchedule
+          whenUnsatisfiable: ScheduleAnyway
            labelSelector:
              matchLabels:
                app.kubernetes.io/name: payment-service
```

2. Apply the manifest:
```bash
kubectl apply -f manifests/40-payment-service.yaml
```

3. Verify all 3 replicas become `Running`:
```bash
kubectl rollout status deployment/payment-service -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=payment-service -o wide
# Expected: 3/3 pods Running, READY: 1/1
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **`DoNotSchedule` vs `ScheduleAnyway`:** In heterogenous clusters with dedicated tainted node pools (DB, GPU), hard topology spread constraints on zone keys frequently cause scheduling deadlocks. Prefer `whenUnsatisfiable: ScheduleAnyway` or use `minDomains` (K8s 1.25+).

---

### [INC-1205] Notification Dispatcher CronJob Failing with OOMKilled & Unbounded Pod Sprawl

#### 1. 🧠 Diagnostic Mindset
- **Exit Code 137 Forensics:**
  Pod status shows `OOMKilled` or `CrashLoopBackOff` with `Exit Code: 137`.
  $$\text{Exit Code} = 128 + 9 (\text{SIGKILL}) = 137$$
  The container did not crash gracefully; the Linux kernel cgroup OOM killer terminated it.
- **Memory Buffer vs Limits:**
  The Python worker initializes a 45MB bytearray cache (`bytearray(45 * 1024 * 1024)`). Including the Python 3.12 runtime overhead, RSS reaches ~60-65MB. However, `limits.memory` is set to `32Mi`.
- **Concurrency Policy Trap:**
  With `concurrencyPolicy: Allow` and no `activeDeadlineSeconds`, failing pods restart continuously while new Jobs are created every minute, leading to pod accumulation.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check CronJob and pods:
kubectl get cronjob notification-dispatcher -n vortex-prod
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=notification-dispatcher
# Observation: Multiple pods OOMKilled or CrashLoopBackOff

# 2. Check termination reason:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=notification-dispatcher | grep -E "(OOMKilled|Exit Code|Limits)"
# Observation: Reason: OOMKilled, Exit Code: 137, Limits: memory: 32Mi
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/50-notification-worker.yaml`:
   - Change `concurrencyPolicy: Allow` to `concurrencyPolicy: Forbid`.
   - Add `activeDeadlineSeconds: 120` to `jobTemplate.spec`.
   - Set `requests.memory: 64Mi` and `limits.memory: 128Mi`:
```diff
 spec:
   schedule: "* * * * *"
-  concurrencyPolicy: Allow
+  concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 3
   failedJobsHistoryLimit: 3
   jobTemplate:
     spec:
+      activeDeadlineSeconds: 120
       template:
         metadata:
...
               resources:
                 requests:
-                  memory: 16Mi
+                  memory: 64Mi
                   cpu: 20m
                 limits:
-                  memory: 32Mi
+                  memory: 128Mi
                   cpu: 100m
```

2. Apply the manifest:
```bash
kubectl apply -f manifests/50-notification-worker.yaml
```

3. Clean up failed historical jobs:
```bash
kubectl delete job -l app.kubernetes.io/name=notification-dispatcher -n vortex-prod
```

4. Trigger a manual test job and verify success:
```bash
kubectl create job --from=cronjob/notification-dispatcher manual-dispatch-test -n vortex-prod
kubectl wait --for=condition=complete job/manual-dispatch-test -n vortex-prod --timeout=30s
kubectl logs -n vortex-prod job/manual-dispatch-test
# Expected: Notification batch completed successfully.
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **CronJob Concurrency Policies:** `Forbid` should be the standard default for stateful and transactional jobs (notifications, backups, invoicing) to prevent cascading resource starvation during outages.
- **Interpreted Runtime Memory Baselines:** Allocate at least 30-50% headroom above maximum expected memory usage to account for runtime memory fragmentation and garbage collection spikes.

---

## 🏁 End-to-End Production Health Verification

Run the verification script to certify complete platform recovery:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="vortex-prod"
echo "========================================================"
echo " 🏁 VORTEX END-TO-END PRODUCTION HEALTH VERIFICATION"
echo "========================================================"

echo "=== [1/6] Layer 0: Stateful Datastores (PostgreSQL & Redis) ==="
kubectl get statefulset vortex-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ vortex-db (PostgreSQL 16) 1/1 Ready on Node-3"
kubectl get deployment vortex-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ vortex-redis (Redis 7.2) 1/1 Ready in Web Pool"

echo "=== [2/6] Layer 1: Ingress Gateway (Traefik v2.11) ==="
kubectl get deployment traefik -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Traefik Ingress Controller 1/1 Ready (Unprivileged port 8000)"

echo "=== [3/6] Layer 2: Authentication Engine (auth-service) ==="
kubectl get deployment auth-service -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ auth-service 1/1 Ready (Secret & Redis host resolved)"

echo "=== [4/6] Layer 3: High-Availability Payment Engine (payment-service) ==="
PAYMENT_READY=$(kubectl get deployment payment-service -n "${NS}" -o jsonpath='{.status.readyReplicas}')
test "${PAYMENT_READY}" -eq 3 && echo "✅ payment-service 3/3 replicas distributed across web nodes"

echo "=== [5/6] Layer 4: Ingress Routing & Transaction Flow ==="
TRAEFIK_IP=$(kubectl get svc traefik -n "${NS}" -o jsonpath='{.spec.clusterIP}')
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/auth/verify")
test "${AUTH_STATUS}" -eq 200 && echo "✅ Traefik L7 /api/v1/auth/verify routing returned HTTP 200 OK"

PAYMENT_RESP=$(curl -s -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/payments/process")
echo "${PAYMENT_RESP}" | grep -q "tx_vortex" && echo "✅ End-to-end payment processing successful"

echo "=== [6/6] Layer 5: Batch Notification Worker (CronJob) ==="
CJ_CONCURRENCY=$(kubectl get cronjob notification-dispatcher -n "${NS}" -o jsonpath='{.spec.concurrencyPolicy}')
test "${CJ_CONCURRENCY}" = "Forbid" && echo "✅ notification-dispatcher concurrency policy verified as 'Forbid'"
CJ_MEM_LIMIT=$(kubectl get cronjob notification-dispatcher -n "${NS}" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory}')
echo "✅ notification-dispatcher memory limit safely set to ${CJ_MEM_LIMIT}"

echo "========================================================"
echo " 🎉 ALL VORTEX PRODUCTION TIERS FULLY OPERATIONAL!"
echo "========================================================"
```

---

# 🇹🇷 Türkçe Versiyon / Kapsamlı SRE Olay Müdahale Rehberi ve Post-Mortem: Lab 12 (Vortex)

Bu belge, **Vortex (`vortex-prod` namespace)** dağıtık mikroservis ve Traefik Ingress platformunda yaşanan zincirleme kesintinin detaylı kök neden analizlerini (Root Cause Analysis - RCA), Linux çekirdeği ve Kubernetes kontrol düzlemi mekanizmalarını, teşhis adımlarını, kesin çözüm komutlarını ve kurumsal SRE sektör deneyimlerini içerir.

> [!NOTE]
> Vortex mimarisi **%100 doğrusal ve aşağıdan yukarıya (bottom-up)** zincirleme bağımlılıklarla kurgulanmıştır. Her bilet yalnızca bir önceki bilet başarıyla çözüldüğünde açığa çıkar; adımları sırayla takip ediniz.

---

## 📑 Yönetici Özeti (Incident Resolution Matrix)

| Ticket | Etkilenen Bileşen | Semptom | Kök Neden | Uygulanan Çözüm | Kontrol Düzlemi Mekanizması | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1201** | `traefik` (Helm Release) | `CrashLoopBackOff` (0/1 Ready), `bind: permission denied` | Non-root (UID 1000) kullanıcının 1024 altındaki privileged port 80'i dinlemeye çalışması | `ports.web.port: 8000`, `targetPort: 8000` tanımlanması | Linux Kernel Socket Permissions & Kubelet SecurityContext | P1 - Blocker |
| **INC-1202** | `vortex-ingress` (Ingress) | `HTTP 404 Not Found` (`/api/v1/auth/verify`) | `pathType: Exact` kullanımı nedeniyle alt yolların eşleşmemesi ve path stripping eksikliği | `pathType: Prefix` yapılması ve backend path uyumunun sağlanması | Ingress Controller Rule Matching Engine & L7 Path Dispatcher | P1 - Blocker |
| **INC-1203** | `auth-service` (Deployment) | `CreateContainerConfigError` ve ardından `HTTP 503` | Secret anahtarı yazım hatası (`db-password` vs `database-password`) & yanlış Redis hostu (`cache-service` vs `vortex-redis`) | Secret key: `database-password`, `REDIS_HOST: vortex-redis` düzeltmesi | Kubelet Secret Resolver & CoreDNS In-Cluster Service Discovery | P1 - Blocker |
| **INC-1204** | `payment-service` (Deployment) | `2/3 Ready`, 1 replika kalıcı olarak `Pending` | 2 zone'lu web havuzunda `DoNotSchedule` ve `maxSkew: 1` ile 3 replikanın dağıtılamaması (3. zone database taint'li) | `whenUnsatisfiable: ScheduleAnyway` veya hostname bazlı yayılım | `kube-scheduler` TopologySpread Filter & Scoring Plugins | P1 - Blocker |
| **INC-1205** | `notification-dispatcher` (CronJob) | `OOMKilled` (Exit Code 137) & kontrolsüz pod birikmesi | 45MB bellek ayıran koda `limits.memory: 32Mi` verilmesi & `concurrencyPolicy: Allow` serbestliği | `limits.memory: 128Mi`, `concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 120` | Linux Kernel cgroup v2 Memory Controller & Kube-CronJob-Controller | P2 - High |

---

## 🔧 Ticket Bazında Derinlemesine Çözümler

---

### [INC-1201] Traefik Ingress Controller Başlatılamıyor (CrashLoopBackOff & Bind Permission Denied)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Konteyner Çöküşünün Kök Nedenini İzole Etmek:**
  Bir ingress controller pod'u `CrashLoopBackOff` durumuna düştüğünde, SRE mühendisinin ilk başvuracağı kaynak pod loglarıdır (`kubectl logs`). 
  Log çıktısında şu kritik hata mesajı göze çarpar:
  `Error loading entryPoint web: error starting listener: listen tcp :80: bind: permission denied`
- **Linux Çekirdeği Ayrıcalıklı Port (Privileged Ports) Güvenlik Modeli:**
  POSIX ve Linux ağ yığınında, `1` ile `1023` arasındaki portlar "ayrıcalıklı portlar" (privileged ports) olarak sınıflandırılmıştır. Çekirdek seviyesindeki bu kural uyarınca, yalnızca root kullanıcısı (`UID 0`) veya `CAP_NET_BIND_SERVICE` Linux capability'sine (yeteneğine) sahip süreçler 1024 altındaki bir porta `bind()` sistem çağrısı yapabilir.
- **Konfigürasyon Çatışması:**
  Helm değerleri (`helm-values/traefik-prod.yaml`) incelendiğinde iki ayarın birbiriyle doğrudan çeliştiği görülür:
  1. `securityContext.runAsNonRoot: true` ve `securityContext.runAsUser: 1000` tanımlanarak konteynerin kesinlikle root olmayan sıradan bir kullanıcıyla çalışması emredilmiştir.
  2. `ports.web.port: 80` olarak ayarlanarak Traefik'in 80 numaralı portu doğrudan dinlemesi istenmiştir.
  Root olmayan UID 1000 kullanıcısı `0.0.0.0:80` soketini açmaya çalıştığı anda Linux çekirdeği işlemi `EACCES (Permission denied)` ile reddeder ve Traefik süreci 1 çıkış koduyla sonlanır.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Traefik pod durumunu kontrol edin:
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=traefik
# Gözlem: STATUS: CrashLoopBackOff veya Error, RESTARTS sürekli artıyor.

# 2. Konteyner çöküş loglarını okuyun (Yetki hatası kanıtı):
kubectl logs -n vortex-prod -l app.kubernetes.io/name=traefik --tail=25
# Gözlem:
# command: traefik ...
# Error loading entryPoint web: error starting listener: listen tcp :80: bind: permission denied

# 3. Helm değerlerindeki port ve kullanıcı tanımlarını inceleyin:
cat helm-values/traefik-prod.yaml
# Gözlem:
# runAsUser: 1000
# ports.web.port: 80 <--- Çelişki burada!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `helm-values/traefik-prod.yaml` dosyasını açın:
   - `ports.web.port` değerini `80` yerine unprivileged (ayrıcalıksız) bir port olan `8000` yapın.
   - `ports.web.targetPort` değerini de `8000` yapın:

```diff
 ports:
   web:
-    port: 80
-    targetPort: 80
+    port: 8000
+    targetPort: 8000
     nodePort: 30080
```

> [!NOTE]
> `charts/traefik/templates/service.yaml` şablonu incelendiğinde Service tanımının dışarıya `port: 80` sunduğu, `targetPort` olarak ise `{{ .Values.ports.web.port }}` kullandığı görülür. Dolayısıyla port 8000'e çekildiğinde Service dışarıdan gelen port 80 trafiğini konteynerin 8000 portuna iletecek, istemciler hiçbir değişiklik hissetmeyecektir!

2. Helm sürümünü güncelleyin:
```bash
helm upgrade --install traefik ./charts/traefik \
  -f helm-values/traefik-prod.yaml \
  -n vortex-prod
```

3. Traefik pod'unun ayağa kalktığını ve `/ping` sağlık kontrolünün geçtiğini doğrulayın:
```bash
kubectl rollout status deployment/traefik -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=traefik
# Beklenen: STATUS: Running, READY: 1/1, RESTARTS: 0

# Dahili Traefik healthcheck komutunu çalıştırın:
kubectl exec -n vortex-prod deploy/traefik -- traefik healthcheck --ping.entrypoint=web
# Beklenen: OK (Çıkış kodu 0)
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Linux Privileged Ports (<1024) vs Unprivileged Ports:**
  Modern konteyner güvenliği standartları (örneğin CIS Kubernetes Benchmark, NSA Hardening Guide ve Kubernetes Pod Security Standards `Restricted` profili), konteynerlerin root (`UID 0`) olarak çalışmasını kesin bir dille yasaklar (`runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`).
- **CAP_NET_BIND_SERVICE vs Unprivileged Port Binding:**
  Root olmayan bir kullanıcının düşük portları dinleyebilmesi için iki yöntem mevcuttur:
  1. **`CAP_NET_BIND_SERVICE` Yeteneği:** `securityContext.capabilities.add: ["NET_BIND_SERVICE"]` ile verilebilir. Ancak bu yöntem bazı OpenShift / PodSecurityPolicy / Kyverno ortamlarında güvenlik ihlali olarak işaretlenir.
  2. **Yüksek Porta Bind Edip Kubernetes Service ile Eşleme (En İyi Pratik):** Konteynerin `8000`, `8080` veya `8443` gibi unprivileged bir portu dinlemesi, Kubernetes Service nesnesinin ise dış dünyadaki `80/443` portlarını `targetPort: 8000/8443` olarak içerideki yüksek porta yönlendirmesidir. NGINX Ingress Controller, Traefik ve Envoy kurumsal production dağıtımlarında her zaman bu yöntemi kullanır.
  - Alternatif çekirdek sysctl çözümü: `net.ipv4.ip_unprivileged_port_start=80` tanımlamak (kubelet allowlist gerektirir).

---

### [INC-1202] Traefik Ingress API Yollarında HTTP 404 Not Found Döndürüyor

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **404 Hatası Nereden Kaynaklanıyor? (Controller vs Backend):**
  İstemci `http://vortex.local/api/v1/auth/verify` adresine istek attığında `HTTP 404 Not Found` yanıtı almaktadır.
  Bir L7 Ingress ortamında 404 hatası iki farklı katmanda üretilebilir:
  1. **Ingress Controller Katmanı:** Gelen istek Ingress kurallarındaki hiçbir `host` ve `path` kuralıyla eşleşmez. Controller doğrudan istemciye 404 döner (istek backend servise asla iletilmez).
  2. **Uygulama Backend Katmanı:** İstek backend pod'una ulaşır, ancak uygulamanın HTTP yönlendiricisinde bu URL yolu tanımlı değildir.
- **Kök Neden Analizi:**
  `manifests/20-ingress.yaml` incelendiğinde iki temel sorun tespit edilir:
  - **Hata 2A (`pathType: Exact` Yanılgısı):** Ingress kuralında `path: /api/v1/auth` ve `pathType: Exact` yazılmıştır. Kubernetes Ingress spesifikasyonuna göre `Exact`, gelen URL yolunun harfi harfine `/api/v1/auth` olmasını gerektirir. İstemcinin çağırdığı `/api/v1/auth/verify` alt yolu bu kurala eşleşmez ve Traefik doğrudan `404 page not found` döndürür! Alt yolların kapsanması için `pathType: Prefix` zorunludur.
  - **Hata 2B (Path Stripping / Önek Kırpma İhtiyacı):** `pathType: Prefix` yapıldığında Traefik isteği backend'e iletir. Ancak Traefik varsayılan olarak gelen yolun tamamını (`/api/v1/auth/verify`) backend pod'una paslar. `manifests/30-auth-service.yaml` içindeki Python kodu incelendiğinde uygulamanın kök seviyede `/verify` dinlediği görülür! Dolayısıyla backend `/api/v1/auth/verify` yolunu aldığında kendi içinde 404 dönecektir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Ingress üzerinden istek göndererek HTTP yanıtını ve başlıklarını inceleyin:
TRAEFIK_IP=$(kubectl get svc traefik -n vortex-prod -o jsonpath='{.spec.clusterIP}')
curl -v -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/auth/verify"
# Gözlem: HTTP/1.1 404 Not Found, Content-Length: 19 ("404 page not found")

# 2. Ingress kural tanımını okuyun:
kubectl get ingress vortex-ingress -n vortex-prod -o yaml
# Gözlem:
# paths:
#   - path: /api/v1/auth
#     pathType: Exact  <--- TUZAK!

# 3. Backend auth-service kodundaki endpoint tanımlarını inceleyin:
kubectl get configmap auth-service-config -n vortex-prod -o yaml | grep "def do_GET" -A 25
# Gözlem: Uygulama self.path == "/verify" dinliyor!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/20-ingress.yaml` dosyasını düzenleyin:
   - `pathType: Exact` satırını `pathType: Prefix` olarak güncelleyin.
   - Traefik'in gelen `/api/v1/auth` önekini kırparak backend'e iletmesi için ya Traefik `StripPrefix` Middleware CRD'si tanımlanmalı ya da Ingress path yapısı backend'in karşılayacağı biçimde uyumlu hale getirilmelidir.
   - En temiz ve standart yöntem Ingress üzerinde `pathType: Prefix` tanımlamak ve path'i `/api/v1/auth` olarak belirlemektir:

```diff
       http:
         paths:
           - path: /api/v1/auth
-            pathType: Exact
+            pathType: Prefix
             backend:
               service:
                 name: auth-service
                 port:
                   number: 8081
```

2. Güncellenen Ingress manifestosunu kümeye uygulayın:
```bash
kubectl apply -f manifests/20-ingress.yaml
```

3. Ingress Controller'ın kuralları güncellediğini doğrulayın:
```bash
# Traefik loglarında ingress reload olayını kontrol edin:
kubectl logs -n vortex-prod -l app.kubernetes.io/name=traefik --tail=15 | grep -i "Configuration received"
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Ingress pathType: Exact vs Prefix vs ImplementationSpecific:**
  Kubernetes v1.18 ile Ingress API'sine eklenen `pathType` alanı, Ingress controller'lar arasındaki davranış farklılıklarını standardize etmiştir:
  - `Exact`: Harfi harfine eşleşir (`/api/v1/auth` eşleşir, `/api/v1/auth/` veya `/api/v1/auth/verify` eşleşmez).
  - `Prefix`: URL hiyerarşisinde `/` sınırlarına göre önek eşleştirmesi yapar. `/api/v1/auth` öneki; `/api/v1/auth`, `/api/v1/auth/` ve `/api/v1/auth/verify` yollarının tamamını kapsar. Kurumsal API gateway tasarımlarında mikroservis yönlendirmeleri için kural kesinlikle `Prefix` olmalıdır.
  - `ImplementationSpecific`: Eşleştirme mantığını tamamen controller'ın özel implementasyonuna bırakır.
- **Traefik vs NGINX Path Rewriting / Stripping Mimarisi:**
  - **NGINX Ingress Controller:** Yolu değiştirmek için regex yakalama grupları ve `rewrite-target` annotation'ını kullanır:
    ```yaml
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    # path: /api/v1/auth(/|$)(.*)
    ```
    Bu yöntem güçlü olmakla birlikte karmaşık regex yazım hatalarına ve ReDoS (Regular Expression Denial of Service) açıklarına oldukça açıktır.
  - **Traefik Ingress:** NGINX tarzı regex rewrite yerine deklaratif **Middleware** mimarisini benimser. Traefik'te yol kırpma işlemi için `Middleware` CRD nesnesi oluşturulur:
    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: Middleware
    metadata:
      name: strip-auth
      namespace: vortex-prod
    spec:
      stripPrefix:
        prefixes:
          - /api/v1/auth
    ```
    Ve bu middleware Ingress'e annotation ile bağlanır:
    `traefik.ingress.kubernetes.io/router.middlewares: vortex-prod-strip-auth@kubernetescrd`.
  - Kurumsal En İyi Pratik: Mikroservislerin doğrudan API Gateway'in sunduğu tam yolu (`/api/v1/auth/verify`) bilmesi (context-path awareness), proxy katmanında karmaşık URL rewrite operasyonlarına olan ihtiyacı ortadan kaldırır.

---

### [INC-1203] Auth Service Pod Unhealthy & Returning HTTP 500 / 503 on Dependencies

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Çok Aşamalı Bağımlılık Arızası:**
  `auth-service` iki kademeli bir başarısızlık yaşamaktadır:
  1. **Konfigürasyon Enjeksiyon Hatası (Pod Başlayamıyor):** Pod ilk dağıtıldığında `CreateContainerConfigError` verir. Kubelet, pod konteynerini başlatmadan önce manifestoda belirtilen tüm ConfigMap ve Secret nesnelerini çözümlemek zorundadır. `describe pod` çıktısındaki hata:
     `Error: Couldn't find key db-password in Secret vortex-prod/vortex-db-secret`
     Veritabanı Secret'ı incelendiğinde anahtarın adının `database-password` olduğu görülür.
  2. **Çalışma Zamanı Bağımlılık Hatası (Pod Başlıyor Ama Hazır Olamıyor):** Secret hatası düzeltildiğinde pod ayağa kalkar, ancak bu kez `0/1 Ready` durumunda kalır ve `/ready` sağlık kontrolü HTTP 503 döndürür.
     ConfigMap (`manifests/30-auth-service.yaml`) incelendiğinde `REDIS_HOST: "cache-service"` yazıldığı görülür. Oysa `10-core-infra.yaml` dosyasında Redis servisinin adı `vortex-redis` olarak tanımlanmıştır!
     CoreDNS `cache-service` adını çözümleyemez, soket bağlantısı `[Errno -2] Name or service not known` hatasıyla başarısız olur ve kimlik doğrulama servisi bağımlılık yokluğundan dolayı çöker.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. auth-service pod durumunu inceleyin:
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=auth-service
# Gözlem: STATUS: CreateContainerConfigError

# 2. Pod olaylarını okuyarak eksik Secret anahtarını yakalayın:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=auth-service | grep -A 5 Events
# Gözlem: Warning Failed Couldn't find key db-password in Secret vortex-prod/vortex-db-secret

# 3. Gerçek Secret anahtar adlarını listeleyin:
kubectl get secret vortex-db-secret -n vortex-prod -o jsonpath='{.data}'
# Gözlem: {"database-password":"..."}  --> db-password DEĞİL!

# 4. Kümedeki gerçek Redis servisinin adını doğrulayın:
kubectl get svc -n vortex-prod
# Gözlem: vortex-redis (Port 6379) --> cache-service DEĞİL!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/30-auth-service.yaml` dosyasını açın:
   - ConfigMap içindeki `REDIS_HOST` değerini `cache-service` yerine `vortex-redis` yapın.
   - Deployment içindeki `DB_PASSWORD` secretKeyRef `key: db-password` satırını `key: database-password` olarak düzeltin:

```diff
 data:
   PORT: "8081"
   DB_HOST: "vortex-db"
   DB_PORT: "5432"
   DB_NAME: "vortex_db"
   DB_USER: "vortex_admin"
-  REDIS_HOST: "cache-service"
+  REDIS_HOST: "vortex-redis"
   REDIS_PORT: "6379"
...
           env:
             - name: DB_PASSWORD
               valueFrom:
                 secretKeyRef:
                   name: vortex-db-secret
-                  key: db-password
+                  key: database-password
```

2. Güncellenen manifestoyu uygulayın ve dağıtımı yeniden başlatın:
```bash
kubectl apply -f manifests/30-auth-service.yaml
kubectl rollout restart deployment/auth-service -n vortex-prod
```

3. Pod'un sağlıklı çalıştığını ve `/ready` ile `/verify` uçlarının başarıyla yanıt verdiğini doğrulayın:
```bash
kubectl rollout status deployment/auth-service -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=auth-service
# Beklenen: STATUS: Running, READY: 1/1, RESTARTS: 0

# Dahili sağlık kontrolünü test edin:
kubectl exec -n vortex-prod deploy/auth-service -- python3 -c '
import urllib.request, json
data = json.loads(urllib.request.urlopen("http://localhost:8081/ready").read().decode())
print(json.dumps(data, indent=2))
assert data["ready"] is True
'
# Beklenen: "ready": true, "database": {"reachable": true}, "redis": {"reachable": true}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Secret Key Ref Runtime Failures vs Optional Keys:**
  Kubernetes'te `secretKeyRef` veya `configMapKeyRef` kullanırken varsayılan davranış `optional: false`'tur. Tanımlanan anahtar Secret içinde yoksa Kubelet konteyneri asla çalıştırmaz ve `CreateContainerConfigError` döngüsüne girer.
  - İsteğe bağlı konfigürasyonlarda `optional: true` eklenebilir:
    ```yaml
    valueFrom:
      secretKeyRef:
        name: vortex-db-secret
        key: db-password
        optional: true
    ```
  - Ancak veritabanı şifresi gibi kritik parametrelerde `optional: false` kalması doğru bir fail-fast (erken çökme) yaklaşımıdır; zira eksik kimlik bilgisiyle çalışan bir servis veri bütünlüğünü bozabilir.
- **12-Factor App Konfigürasyon İlkeleri:**
  On İki Faktörlü Uygulama (Factor III: Config) metodolojisine göre, ortamlar arası değişen tüm parametreler (veritabanı adresi, redis sunucusu, portlar) koddan tamamen soyutlanmalı ve ortam değişkenleriyle beslenmelidir.
  Kurumsal CI/CD süreçlerinde bu tür tipografik hataları (typo) önlemek için Helm template testleri (`helm test`), Kubeval/Kubeconform şema kontrolleri ve bağımlılık kontrol eden init container veya startup probe desenleri kullanılır.

---

### [INC-1204] Payment Service Podları Çoklu Zone Zamanlama Kilitlenmesinde (TopologySpread Deadlock)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Replika Sayısı ve Pending Durumunun İncelenmesi:**
  `payment-service` Deployment'ı 3 replika talep etmektedir (`replicas: 3`). Ancak `kubectl get deployment` çalıştırıldığında `READY: 2/3` görülür. 2 pod çalışırken, 1 pod sonsuza dek `Pending` durumunda kalmıştır.
  Bir pod `Pending` durumunda takıldığında sorumlu kontrol düzlemi bileşeni `kube-scheduler`'dır.
- **Kube-Scheduler Olaylarının Analizi:**
  `kubectl describe pod <pending-pod>` çıktısı incelendiğinde scheduler filtresinin şu mesajla pod'u reddettiği görülür:
  `0/3 nodes are available: 1 node(s) had untolerated taint {workload: database}, 2 node(s) didn't match pod topology spread constraints.`
- **Topoloji Kısıtı ve Matematiksel Kilitlenme (Deadlock):**
  Kümemizin fiziksel yapısını hatırlayalım:
  - **Node-1 (Zone A):** `tier=web`, untainted
  - **Node-2 (Zone B):** `tier=web`, untainted
  - **Node-3 (Zone C):** `tier=database`, `workload=database:NoSchedule` taint'i var!
  `manifests/40-payment-service.yaml` içindeki zamanlama kuralları:
  ```yaml
  nodeSelector:
    tier: web
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: payment-service
  ```
  Zamanlayıcı 3 replikayı yerleştirmeye çalışır:
  1. Pod 1 -> Node-1 (Zone A) yerleşir. (Zone A = 1 pod)
  2. Pod 2 -> Node-2 (Zone B) yerleşir. (Zone B = 1 pod)
  3. Sıra Pod 3'e gelir:
     - Eğer Pod 3 Zone A'ya giderse: Zone A pod sayısı 2, Zone C pod sayısı 0 olur. Fark (`Skew`) = `2 - 0 = 2` olur. Ancak izin verilen `maxSkew: 1`'dir! `whenUnsatisfiable: DoNotSchedule` (Hard kural) olduğu için scheduler bu atamayı reddeder!
     - Eğer Pod 3 Zone B'ye giderse: Skew yine `2 - 0 = 2` olur, reddedilir!
     - Eğer Pod 3 Zone C'ye gitmek isterse: Node-3'te `workload=database:NoSchedule` taint'i vardır ve pod bu taint'i tolere etmez. Ayrıca `nodeSelector: tier: web` kuralı Node-3 ile uyuşmaz.
  Sonuç: Kube-scheduler matematiksel olarak 3. pod için kümede uygun hiçbir node bulamaz ve pod kalıcı olarak kilitlenir (Deadlock).

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Deployment ve pod replika durumunu inceleyin:
kubectl get deployment payment-service -n vortex-prod
# Gözlem: READY: 2/3, UP-TO-DATE: 3, AVAILABLE: 2

# 2. Bekleyen pod'u tespit edin:
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=payment-service -o wide
# Gözlem: 2 pod Running (Node-1 ve Node-2), 1 pod Pending (NODE: <none>)

# 3. Kube-scheduler ret nedenlerini okuyun:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=payment-service | grep -A 5 "FailedScheduling"
# Gözlem:
# Warning FailedScheduling 0/3 nodes are available: 1 node(s) had untolerated taint {workload: database}, 2 node(s) didn't match pod topology spread constraints.

# 4. Düğümlerin zone ve taint konfigürasyonunu kontrol edin:
kubectl get nodes -L topology.kubernetes.io/zone,tier
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/40-payment-service.yaml` dosyasını açın:
   - `whenUnsatisfiable: DoNotSchedule` kuralını `whenUnsatisfiable: ScheduleAnyway` (Soft kural) olarak değiştirin. Bu sayede scheduler pod'ları mümkün olduğunca zone'lara yaymaya çalışır; ancak 3. bir zone'da uygun web node'u bulunamadığında pod'u Pending bırakmak yerine mevcut web node'larından birine yerleştirir.
   - Alternatif olarak `topologyKey: kubernetes.io/hostname` seçilebilir:

```diff
       topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: topology.kubernetes.io/zone
-          whenUnsatisfiable: DoNotSchedule
+          whenUnsatisfiable: ScheduleAnyway
           labelSelector:
             matchLabels:
               app.kubernetes.io/name: payment-service
```

2. Güncellenen manifestoyu uygulayın:
```bash
kubectl apply -f manifests/40-payment-service.yaml
```

3. Tüm replikaların başarıyla çalıştığını doğrulayın:
```bash
kubectl rollout status deployment/payment-service -n vortex-prod --timeout=30s
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=payment-service -o wide
# Beklenen: 3/3 pods Running, READY: 1/1
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **TopologySpreadConstraints maxSkew vs PodAntiAffinity:**
  Eski Kubernetes sürümlerinde yüksek erişilebilirlik sağlamak için `podAntiAffinity` kullanılırdı. Ancak `podAntiAffinity` ikilidir (binary): Bir host veya zone'da o etikete sahip pod varsa yenisini kabul etmez. 3 zone bulunan bir kümede 4 replika çalıştırmak istediğinizde hard anti-affinity 4. pod'u mecburen kilitler.
  Kubernetes v1.19+ ile gelen `topologySpreadConstraints`, dağılımı matematiksel bir formülle (`maxSkew`) yönetir ve çok daha esnektir.
- **Multi-AZ vs Single-AZ Topolojileri & Tainted Nodes Çıkmazı:**
  Kurumsal Kubernetes kümelerinde (AWS EKS, GCP GKE, OCI OKE) veritabanı veya GPU içeren özel havuzlar tainte tabidir.
  Eğer genel amaçlı web iş yükleriniz tüm availability zone'larda homojen olarak barınmıyorsa, `topologyKey: topology.kubernetes.io/zone` ile `whenUnsatisfiable: DoNotSchedule` kullanmak felaket senaryoları doğurur:
  - Autoscaler yeni bir node açamazsa veya o zone geçici olarak devre dışı kalırsa uygulamanızın yeni replikaları ayağa kalkamaz.
  - **Production Kuralı:** Zone bazlı dağılımlarda her zaman `whenUnsatisfiable: ScheduleAnyway` (Best-effort scoring) tercih edilmeli veya Kubernetes 1.25+ ile gelen `minDomains` ve `nodeAffinityPolicy: Honor` parametreleri kullanılmalıdır.

---

### [INC-1205] Notification Dispatcher CronJob Failing with OOMKilled & Unbounded Pod Sprawl

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Konteyner Çıkış Kodu 137 Anlamı (Exit Code 137):**
  `notification-dispatcher` CronJob'ının oluşturduğu podlar incelendiğinde pod durumunun `OOMKilled` veya `CrashLoopBackOff` olduğu ve konteynerin `Exit Code: 137` ile kapandığı görülür.
  Linux'ta bir sürecin çıkış kodu `128 + Sinyal` formülüyle hesaplanır. 9 numaralı sinyal `SIGKILL` olduğundan:
  `128 + 9 = 137`
  Bu durum, sürecin kendi kendine hata verip çıkmadığını; doğrudan Linux çekirdeğinin (cgroup OOM-Killer) süreci zorla öldürdüğünü kanıtlar.
- **Bellek Tüketimi vs Limit Analizi:**
  `manifests/50-notification-worker.yaml` dosyasındaki Python kodu incelendiğinde:
  `template_cache = bytearray(45 * 1024 * 1024)`
  Kod başlarken doğrudan 45MB'lık bir bellek tamponu tahsis etmektedir. Python 3.12 çalışma zamanının taban bellek tüketimi (~15-20MB) ile birlikte toplam RSS tüketimi ~60-65MB'a çıkmaktadır.
  Ancak manifestoda tanımlanan sınır:
  `resources.limits.memory: "32Mi"`
  Çekirdek bellek denetleyicisi (cgroup v2 memory controller), süreç 32MB sınırını aştığı anda sürece `SIGKILL` gönderir.
- **Eşzamanlılık Kuralı (ConcurrencyPolicy) Yanılgısı:**
  Manifestoda `schedule: "* * * * *"` (her dakika) ve `concurrencyPolicy: Allow` tanımlanmıştır. Görevler OOMKilled olduğu ve `activeDeadlineSeconds` tanımlanmadığı için Kubelet başarısız podları yeniden başlatmayı denerken her dakika yeni bir iş tetiklenir. Sonuç olarak worker node'lar üzerinde onlarca ölü ve asılı pod birikir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. CronJob ve pod listesini kontrol edin:
kubectl get cronjob notification-dispatcher -n vortex-prod
kubectl get pods -n vortex-prod -l app.kubernetes.io/name=notification-dispatcher
# Gözlem: Birçok pod OOMKilled veya CrashLoopBackOff durumunda

# 2. Pod sonlanma detaylarını okuyun:
kubectl describe pod -n vortex-prod -l app.kubernetes.io/name=notification-dispatcher | grep -E "(OOMKilled|Exit Code|Limits)"
# Gözlem:
# Last State: Terminated
# Reason: OOMKilled
# Exit Code: 137
# Limits: memory: 32Mi  <--- Yetersiz limit!

# 3. Kubelet OOM olaylarını filtreleyin:
kubectl get events -n vortex-prod --field-selector reason=Killing
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/50-notification-worker.yaml` dosyasını açın:
   - `concurrencyPolicy: Allow` satırını `concurrencyPolicy: Forbid` olarak değiştirin (aynı anda yalnızca 1 iş çalışabilir).
   - `jobTemplate.spec` altına `activeDeadlineSeconds: 120` ekleyerek işin sonsuza dek kilitlenmesini önleyin.
   - Konteyner kaynaklarında `limits.memory` değerini en az `128Mi` yapın, `requests.memory` değerini `64Mi` olarak güncelleyin:

```diff
 spec:
   schedule: "* * * * *"
-  concurrencyPolicy: Allow
+  concurrencyPolicy: Forbid
   successfulJobsHistoryLimit: 3
   failedJobsHistoryLimit: 3
   jobTemplate:
     spec:
+      activeDeadlineSeconds: 120
       template:
         metadata:
...
               resources:
                 requests:
-                  memory: 16Mi
+                  memory: 64Mi
                   cpu: 20m
                 limits:
-                  memory: 32Mi
+                  memory: 128Mi
                   cpu: 100m
```

2. Güncellenen manifestoyu uygulayın:
```bash
kubectl apply -f manifests/50-notification-worker.yaml
```

3. Birikmiş eski başarısız işleri ve podları temizleyin:
```bash
kubectl delete job -l app.kubernetes.io/name=notification-dispatcher -n vortex-prod
```

4. CronJob şablonundan manuel bir test işi üreterek başarılı çalıştığını doğrulayın:
```bash
kubectl create job --from=cronjob/notification-dispatcher manual-dispatch-test -n vortex-prod
kubectl wait --for=condition=complete job/manual-dispatch-test -n vortex-prod --timeout=30s
# Beklenen: job.batch/manual-dispatch-test condition met

kubectl logs -n vortex-prod job/manual-dispatch-test
# Beklenen:
# Starting notification dispatcher...
# Allocated template cache buffer of 45MB.
# Processing notification dispatch batch 1...
# ...
# Notification batch completed successfully.
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **CronJob ConcurrencyPolicy Modelleri: Allow vs Forbid vs Replace:**
  - `Allow` (Varsayılan): Önceki iş bitmemiş olsa dahi yeni bir iş pod'u tetikler. Hatalı veya yavaşlayan batch işlerinde (örneğin DB kilitlenmesi veya OOM) dakikalar içinde yüzlerce zombi pod oluşur ve düğümün PID / IP limitlerini tüketir.
  - `Forbid`: Önceki iş tamamlanmadan veya zaman aşımına uğramadan yeni iş başlatmaz; periyodu atlar (skip). Veritabanı yedekleri, faturalandırma ve bildirim işlerinde standart seçim `Forbid` olmalıdır.
  - `Replace`: Yeni periyot geldiğinde halen çalışan eski işi iptal edip (`SIGTERM`) yerine yeni işi başlatır. Genellikle periyodik önbellek ısıtma veya metrik senkronizasyonu gibi en güncel verinin önemli olduğu işlerde kullanılır.
- **Linux Kernel cgroup v2 Memory Controller & OOM Killer:**
  - Linux çekirdeğinde cgroup v2 bellek denetleyicisi (`memory.max`), konteyner sürecinin tüketebileceği fiziksel RAM miktarını sınırlandırır.
  - Bellek tükendiğinde çekirdek önce page cache temizlemeyi dener; anonim bellek (heap/stack) geri kazanılamazsa `oom-killer` devreye girer.
  - **Production Tavsiyesi:** Interpreted dillerde (Python, Node.js, Ruby) ve sanal makinelerde (JVM) çalışma zamanının kendisi taban bellek (baseline runtime memory) tüketir. Bellek limitleri her zaman uygulamanın en yoğun anda tükettiği belleğin en az %30-50 fazlası olarak belirlenmeli, `requests` değeri ise ortalama çalışma yüküne göre yapılandırılmalıdır.

---

## 🏁 Uçtan Uca Production Sağlık Kontrolü (Bottom-Up Checklist)

Aşağıdaki komut dosyasını çalıştırarak Vortex platformunun tüm katmanlarının (L0'dan L5'e kadar) tamamen sağlıklı ve doğrulanmış olduğunu teyit edebilirsiniz:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="vortex-prod"
echo "========================================================"
echo " 🏁 VORTEX END-TO-END PRODUCTION HEALTH VERIFICATION"
echo "========================================================"

echo "=== [1/6] Katman 0: Durumsal Veri Tabanı (PostgreSQL & Redis) ==="
kubectl get statefulset vortex-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ vortex-db (PostgreSQL 16) Node-3 üzerinde 1/1 Hazır"
kubectl get deployment vortex-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ vortex-redis (Redis 7.2) Web Havuzunda 1/1 Hazır"

echo "=== [2/6] Katman 1: Ingress Ağ Geçidi (Traefik v2.11) ==="
kubectl get deployment traefik -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Traefik Ingress Controller 1/1 Hazır (Yetkisiz port 8000)"

echo "=== [3/6] Katman 2: Kimlik Doğrulama Motoru (auth-service) ==="
kubectl get deployment auth-service -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ auth-service 1/1 Hazır (Secret ve Redis hostu çözüldü)"

echo "=== [4/6] Katman 3: Yüksek Erişilebilir Ödeme Motoru (payment-service) ==="
PAYMENT_READY=$(kubectl get deployment payment-service -n "${NS}" -o jsonpath='{.status.readyReplicas}')
test "${PAYMENT_READY}" -eq 3 && echo "✅ payment-service 3/3 replika ile web düğümlerine dengeli dağıldı"

echo "=== [5/6] Katman 4: Uçtan Uca Ingress Yönlendirmesi ve İşlem Akışı ==="
TRAEFIK_IP=$(kubectl get svc traefik -n "${NS}" -o jsonpath='{.spec.clusterIP}')
AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/auth/verify")
test "${AUTH_STATUS}" -eq 200 && echo "✅ Traefik L7 /api/v1/auth/verify yönlendirmesi HTTP 200 OK döndü"

PAYMENT_RESP=$(curl -s -H "Host: vortex.local" "http://${TRAEFIK_IP}/api/v1/payments/process")
echo "${PAYMENT_RESP}" | grep -q "tx_vortex" && echo "✅ Uçtan uca ödeme süreci başarıyla tamamlandı"

echo "=== [6/6] Katman 5: Batch Bildirim Görevlisi (CronJob) ==="
CJ_CONCURRENCY=$(kubectl get cronjob notification-dispatcher -n "${NS}" -o jsonpath='{.spec.concurrencyPolicy}')
test "${CJ_CONCURRENCY}" = "Forbid" && echo "✅ notification-dispatcher eşzamanlılık kuralı 'Forbid' olarak doğrulandı"
CJ_MEM_LIMIT=$(kubectl get cronjob notification-dispatcher -n "${NS}" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory}')
echo "✅ notification-dispatcher bellek limiti güvenli şekilde ${CJ_MEM_LIMIT} olarak ayarlandı"

echo "========================================================"
echo " 🎉 TÜM VORTEX PRODUCTION KATMANLARI SAĞLIKLI VE AKTİF!"
echo "========================================================"
```
