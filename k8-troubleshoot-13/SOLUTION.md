# 🇬🇧 English Version / Comprehensive SRE Post-Mortem & Remediation Guide: Lab 13 (NovaEdge)

This document provides deep-dive Root Cause Analyses (RCA), Linux kernel and Kubernetes control plane mechanics, diagnostic triage commands, step-by-step remediation procedures, and enterprise SRE production best practices for the cascading outage across the **NovaEdge (`novaedge-prod` namespace)** real-time IoT edge stream platform.

> [!NOTE]
> NovaEdge is engineered with a **100% linear, bottom-up cascading dependency chain**. Each incident is strictly unmasked only when the preceding layer has been stabilized. Follow the tickets sequentially.

---

## 📑 Incident Resolution Matrix

| Ticket | Impacted Component | Symptom | Root Cause | Fix Strategy | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1301** | `edge-ingress` (Helm Release) | `Connection refused` on LoadBalancer port 80 | Service `targetPort: 8090` forwards to closed port (container listens on 8080) | Update `service.targetPort: 8080` in `helm-values/edge-ingress-prod.yaml` & `helm upgrade` | `kube-proxy` (iptables / IPVS NAT) & EndpointSlice Controller | P1 - Blocker |
| **INC-1302** | `novaedge-ingress` (Ingress) | `HTTP 404 Not Found` (`api.novaedge.io/stream`) | IngressClassName mismatch (`edge-ingress-internal`) & backend port 80 instead of 8080 | Set `ingressClassName: edge-ingress` & `backend.service.port.number: 8080` | Ingress Controller Rule Evaluator & Service Port Matcher | P1 - Blocker |
| **INC-1303** | `stream-api` (Deployment) | `CrashLoopBackOff` (0/1 Ready), exit code 1 / 2 | Wrong container startup path (`/etc/app/server.py`) & `STREAM_BUFFER_SIZE: 128` validation assert failure | Update path to `/app/server.py` & buffer size to `4096` in `manifests/30-stream-api.yaml` | Kubelet Container Lifecycle & Application Validation Guardrails | P1 - Blocker |
| **INC-1304** | `edge-node-agent` (DaemonSet) | Missing from Node-3 (`2/3 pods`); crashing on Web nodes | Taint toleration typo (`value: "db"`) & runtime volume mounted `readOnly: true` | Toleration value: `"database"`, remove `readOnly: true` in `manifests/40-edge-daemonset.yaml` | `kube-scheduler` TaintToleration & Linux VFS Mount Permissions | P1 - Blocker |
| **INC-1305** | `stream-sync-worker` (Deployment) | Permanently `0/1 Ready` (`connection refused` on port 9200) | Async worker lacks HTTP server (probe protocol mismatch) & Redis channel name typo | Change probe to `exec: cat /tmp/sync-healthy` & channel to `novaedge-telemetry` | Kubelet Prober (HTTP vs Exec) & Pub/Sub Topic Routing | P2 - High |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-1301] Edge Ingress Gateway Port Misrouting (Helm Release)

#### 1. 🧠 Diagnostic Mindset
- **Distinguishing LoadBalancer Infrastructure from Service Port Forwarding:**
  When external clients cannot establish a TCP connection to a LoadBalancer IP on port 80 (`Connection refused`), SREs separate cloud load balancer provisioning from in-cluster service forwarding.
- **Kube-Proxy and EndpointSlice Mechanics:**
  A Kubernetes Service of `type: LoadBalancer` creates host iptables / IPVS forwarding rules that route incoming packets arriving on `spec.ports[].port` (80) to the pod container port specified in `spec.ports[].targetPort`.
  Inspecting `charts/edge-ingress/templates/deployment.yaml` shows the NGINX container listens on port `8080`.
  However, in `helm-values/edge-ingress-prod.yaml`, `service.targetPort` is configured as `8090`.
  The EndpointSlice controller maps the Service endpoints to `<pod_ip>:8090`. Because no process listens on socket 8090 inside the pod network namespace, the Linux kernel immediately resets incoming TCP handshakes with `RST` (`Connection refused`).

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect Edge Ingress Service and Pod status:
kubectl get svc,pods -n novaedge-prod -l app.kubernetes.io/name=edge-ingress -o wide
# Observation: Pod is 1/1 Running, but Service targetPort is 8090.

# 2. Inspect Service Endpoints:
kubectl get endpoints edge-ingress -n novaedge-prod
# Observation: <POD_IP>:8090  <--- Misrouted targetPort!

# 3. Test connection directly to container port 8080 vs Service port 80:
POD_NAME=$(kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=edge-ingress -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n novaedge-prod "${POD_NAME}" -- nc -zv 127.0.0.1 8080
# Observation: 127.0.0.1:8080 open
kubectl exec -n novaedge-prod "${POD_NAME}" -- nc -zv 127.0.0.1 8090
# Observation: nc: connect to 127.0.0.1 port 8090 (tcp) failed: Connection refused
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `helm-values/edge-ingress-prod.yaml`:
   - Change `service.targetPort` from `8090` to `8080`:
```diff
 service:
   type: LoadBalancer
   port: 80
-  targetPort: 8090
+  targetPort: 8080
   nodePort: 30088
   externalTrafficPolicy: Cluster
```

2. Upgrade the Helm release:
```bash
helm upgrade edge-ingress ./charts/edge-ingress \
  -f helm-values/edge-ingress-prod.yaml \
  -n novaedge-prod
```

3. Verify Service Endpoints updated and respond:
```bash
kubectl get endpoints edge-ingress -n novaedge-prod
# Expected: <POD_IP>:8080

LB_IP=$(kubectl get svc edge-ingress -n novaedge-prod -o jsonpath='{.spec.clusterIP}')
curl -s "http://${LB_IP}/healthz"
# Expected: {"status":"ok","controller":"edge-ingress","ingress_class":"edge-ingress"}
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Port vs TargetPort Decoupling:** In Kubernetes, `port` is the external-facing port that clients connect to; `targetPort` is the internal container port. Always verify that `targetPort` matches the container's `containerPort` or named port.
- **Automated Helm Contract Tests:** Implement `helm test` suites that verify `curl http://{{ .Release.Name }}:{{ .Values.service.port }}/healthz` succeeds inside the cluster prior to routing live production traffic.

---

### [INC-1302] Ingress Resource Ignored & Backend Port Mismatch (HTTP 404 / 503)

#### 1. 🧠 Diagnostic Mindset
- **Ingress Controller Class Scoping:**
  In multi-ingress Kubernetes clusters, each Ingress Controller filters Ingress resources using `spec.ingressClassName`.
  In `charts/edge-ingress/templates/ingressclass.yaml`, the controller registers the IngressClass `edge-ingress`.
  However, in `manifests/20-ingress.yaml`, the Ingress resource declares:
  `ingressClassName: edge-ingress-internal`
  Because `edge-ingress-internal` does not match the controller's class, the Ingress controller completely ignores the routing rule, returning default backend `404 Not Found`.
- **Backend Service Port Indirection:**
  Furthermore, the Ingress backend references `service.port.number: 80`, but `stream-api` Service only exposes port `8080`. Even if the class matched, the controller would fail to find endpoints for port 80 (`503 Service Unavailable`).

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Send test request through Ingress:
INGRESS_IP=$(kubectl get svc edge-ingress -n novaedge-prod -o jsonpath='{.spec.clusterIP}')
curl -v -H "Host: api.novaedge.io" "http://${INGRESS_IP}/stream"
# Observation: HTTP/1.1 404 Not Found (no ingress route matched)

# 2. Check cluster IngressClasses:
kubectl get ingressclass
# Observation: NAME: edge-ingress

# 3. Inspect Ingress resource:
kubectl get ingress novaedge-ingress -n novaedge-prod -o yaml
# Observation: ingressClassName: edge-ingress-internal, backend port: 80
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/20-ingress.yaml`:
   - Set `ingressClassName` to `edge-ingress`.
   - Update backend service port `number` to `8080`:
```diff
 spec:
-  ingressClassName: edge-ingress-internal
+  ingressClassName: edge-ingress
   rules:
     - host: api.novaedge.io
       http:
         paths:
           - path: /stream
             pathType: Prefix
             backend:
               service:
                 name: stream-api
                 port:
-                  number: 80
+                  number: 8080
```

2. Apply the updated manifest:
```bash
kubectl apply -f manifests/20-ingress.yaml
```

3. Confirm Ingress Controller adopted the resource:
```bash
kubectl describe ingress novaedge-ingress -n novaedge-prod
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Deprecation of `kubernetes.io/ingress.class` Annotation:** Kubernetes v1.19+ deprecated the ingress class annotation in favor of `spec.ingressClassName`. Always ensure the IngressClass object exists in the cluster before deploying Ingress rules.
- **Port Mapping Verification:** Ingress backend service ports must reference either an explicit numeric port exposed in `service.spec.ports[].port` or a valid named port.

---

### [INC-1303] Stream API Startup Crash & Environment Validation (CrashLoopBackOff)

#### 1. 🧠 Diagnostic Mindset
- **Two Sequential Startup Blockers:**
  When `stream-api` is deployed, pods enter `CrashLoopBackOff` with two sequential errors:
  1. **File Not Found (`[Errno 2]`):** The container command executes:
     `command: ["python3", "/etc/app/server.py"]`
     However, the ConfigMap volume is mounted at `/app`. The file `/etc/app/server.py` does not exist, causing Python to exit immediately with code 2.
  2. **Application Validation Guardrail:** Once the path is fixed to `/app/server.py`, the container starts but exits with code 1. The application checks:
     `if buffer_size < 1024: sys.exit(1)`
     In `manifests/30-stream-api.yaml`, `STREAM_BUFFER_SIZE: "128"` is passed via ConfigMap, violating the minimum 1024-byte ring buffer requirement.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect pod status and exit code:
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-api
# Observation: STATUS: CrashLoopBackOff, RESTARTS increasing.

# 2. View termination logs:
kubectl logs -n novaedge-prod -l app.kubernetes.io/name=stream-api --tail=20
# Observation: python3: can't open file '/etc/app/server.py': [Errno 2] No such file or directory

# 3. Inspect volume mounts in manifest:
grep -A 8 "volumeMounts" manifests/30-stream-api.yaml
# Observation: mountPath: /app (not /etc/app)
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/30-stream-api.yaml`:
   - In ConfigMap: Increase `STREAM_BUFFER_SIZE` to `4096`.
   - In Deployment: Change container command to `["python3", "/app/server.py"]`:
```diff
 data:
   PORT: "8080"
-  STREAM_BUFFER_SIZE: "128"
+  STREAM_BUFFER_SIZE: "4096"
   REDIS_HOST: "novaedge-redis"
...
         containers:
           - name: api
             image: python:3.12-alpine
-            command: ["python3", "/etc/app/server.py"]
+            command: ["python3", "/app/server.py"]
```

2. Apply manifest and wait for rollout:
```bash
kubectl apply -f manifests/30-stream-api.yaml
kubectl rollout status deployment/stream-api -n novaedge-prod --timeout=30s
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-api
# Expected: 2/2 pods Running, READY: 1/1
```

3. Test internal HTTP health endpoint:
```bash
kubectl exec -n novaedge-prod deploy/stream-api -- python3 -c '
import urllib.request, json
res = json.loads(urllib.request.urlopen("http://localhost:8080/healthz").read().decode())
assert res["status"] == "ok"
print("Health check passed:", res)
'
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Fail-Fast Application Validation:** Hard runtime assertions on critical tuning parameters (buffer sizes, timeout bounds, worker counts) prevent silent data corruption or performance degradation.
- **ConfigMap Mount Paths:** Mount ConfigMaps to clean, dedicated subdirectories (`/app` or `/config`) rather than overwriting standard Linux directory trees (`/etc`).

---

### [INC-1304] Edge Node DaemonSet Node Taint & Volume Permissions

#### 1. 🧠 Diagnostic Mindset
- **Dual Infrastructure Scheduling & Permissions Failure:**
  `edge-node-agent` is a cluster-wide DaemonSet designed to run on all 3 nodes in our cluster:
  - Node-1 (`tier=web`, untainted)
  - Node-2 (`tier=web`, untainted)
  - Node-3 (`tier=database`, tainted: `workload=database:NoSchedule`)
  Two distinct issues prevent normal operation:
  1. **Taint Toleration Typo:** `spec.template.spec.tolerations` specifies `value: "db"`. The taint on Node-3 is `workload=database:NoSchedule`. Because the string `"db"` does not match `"database"`, Kube-Scheduler refuses to schedule the DaemonSet on Node-3.
  2. **Read-Only Volume Mount (`[Errno 30]`):** On Node-1 and Node-2, pods are scheduled but crash with:
     `OSError: [Errno 30] Read-only file system: '/var/run/node-agent/agent.lock'`
     `manifests/40-edge-daemonset.yaml` mounts `/var/run/node-agent` with `readOnly: true`, preventing the agent process from acquiring its runtime lock file.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check DaemonSet status:
kubectl get ds edge-node-agent -n novaedge-prod
# Observation: DESIRED: 3, CURRENT: 2, READY: 0

# 2. Inspect crashing pods:
kubectl logs -n novaedge-prod -l app.kubernetes.io/name=edge-node-agent --tail=20
# Observation: OSError: [Errno 30] Read-only file system: '/var/run/node-agent/agent.lock'

# 3. Check node taints:
kubectl get nodes -L tier -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/40-edge-daemonset.yaml`:
   - Update toleration value from `"db"` to `"database"`.
   - Remove `readOnly: true` (or set `readOnly: false`) from the `runtime-state` volume mount:
```diff
       tolerations:
         - key: workload
           operator: Equal
-          value: "db"
+          value: "database"
           effect: NoSchedule
...
           volumeMounts:
             - name: script
               mountPath: /opt/agent
             - name: runtime-state
               mountPath: /var/run/node-agent
-              readOnly: true
```

2. Apply manifest:
```bash
kubectl apply -f manifests/40-edge-daemonset.yaml
```

3. Confirm DaemonSet is running across all 3 nodes:
```bash
kubectl rollout status ds/edge-node-agent -n novaedge-prod --timeout=30s
kubectl get ds edge-node-agent -n novaedge-prod
# Expected: DESIRED: 3, CURRENT: 3, READY: 3
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **DaemonSet Taint Coverage:** Telemetry agents, security scanners, and log collectors must explicitly tolerate all known node taints (database, GPU, storage) to ensure full cluster observability.
- **Runtime Mount Isolation:** Use `emptyDir` or `/tmp` for non-persistent locks and metrics rather than writing directly to root container filesystems.

---

### [INC-1305] Stream Sync Worker Probe Protocol & Queue Channel

#### 1. 🧠 Diagnostic Mindset
- **Background Worker Health Check Patterns:**
  `stream-sync-worker` is an asynchronous queue processing worker. It does not open or listen on an HTTP server port.
  However, `manifests/50-sync-worker.yaml` defines:
  `readinessProbe: httpGet: { path: /ready, port: 9200 }`
  Because port 9200 is closed, Kubelet's HTTP probe client repeatedly fails with `connection refused`. The pods remain permanently in `0/1 Ready`.
  The worker periodically writes a heartbeat to `/tmp/sync-healthy`. An `exec` probe testing `/tmp/sync-healthy` is the proper pattern.
- **Pub/Sub Channel Name Mismatch:**
  In `manifests/50-sync-worker.yaml`, ConfigMap sets `REDIS_CHANNEL: "telemetry-stream"`, while the stream API publishes to `novaedge-telemetry`. The worker subscribes to the wrong channel, resulting in zero telemetry synchronization.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect worker readiness failure:
kubectl describe pod -n novaedge-prod -l app.kubernetes.io/name=stream-sync-worker | grep -A 5 "Readiness:"
# Observation: Readiness probe failed: dial tcp ...:9200: connect: connection refused

# 2. Check worker python code:
cat manifests/50-sync-worker.yaml | grep -A 20 "worker.py:"
# Observation: Writes heartbeat to /tmp/sync-healthy; no HTTP server!
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/50-sync-worker.yaml`:
   - Set `REDIS_CHANNEL: "novaedge-telemetry"` in ConfigMap.
   - Replace `httpGet` readiness probe with `exec: command: ["cat", "/tmp/sync-healthy"]`:
```diff
 data:
   REDIS_HOST: "novaedge-redis"
   REDIS_PORT: "6379"
-  REDIS_CHANNEL: "telemetry-stream"
+  REDIS_CHANNEL: "novaedge-telemetry"
   DB_HOST: "novaedge-db"
...
           readinessProbe:
-            httpGet:
-              path: /ready
-              port: 9200
+            exec:
+              command:
+                - cat
+                - /tmp/sync-healthy
             initialDelaySeconds: 5
             periodSeconds: 5
```

2. Apply manifest and wait for rollout:
```bash
kubectl apply -f manifests/50-sync-worker.yaml
kubectl rollout status deployment/stream-sync-worker -n novaedge-prod --timeout=30s
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-sync-worker
# Expected: 2/2 pods Running (1/1 Ready)
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Probe Choice for Non-HTTP Workloads:** For event processors, message queue consumers, and cron jobs, use `exec` probes on local heartbeat files or TCP socket probes instead of fictitious HTTP endpoints.
- **Topic & Channel Governance:** Centralize Pub/Sub topic and channel names into shared configuration templates or schema registries to prevent silent message loss.

---

## 🏁 End-to-End Production Health Verification

Run this script to certify complete platform recovery:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="novaedge-prod"
echo "========================================================"
echo " 🏁 NOVAEDGE END-TO-END PRODUCTION HEALTH VERIFICATION"
echo "========================================================"

echo "=== [1/5] Core Infrastructure (Postgres & Redis) ==="
kubectl get statefulset novaedge-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ PostgreSQL 16 1/1 Ready on Node-3"
kubectl get deployment novaedge-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Redis 7.2 1/1 Ready"

echo "=== [2/5] Ingress Controller & LoadBalancer ==="
kubectl get deployment edge-ingress -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Ingress Controller 1/1 Ready"

echo "=== [3/5] Stream API Ingestion ==="
kubectl get deployment stream-api -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "2" && echo "✅ stream-api 2/2 Ready"

echo "=== [4/5] Cluster-Wide Edge DaemonSet ==="
kubectl get ds edge-node-agent -n "${NS}" -o jsonpath='{.status.numberReady}' | grep -q "3" && echo "✅ edge-node-agent 3/3 Ready across all nodes"

echo "=== [5/5] Background Sync Worker & End-to-End Routing ==="
kubectl get deployment stream-sync-worker -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "2" && echo "✅ stream-sync-worker 2/2 Ready"

INGRESS_IP=$(kubectl get svc edge-ingress -n "${NS}" -o jsonpath='{.spec.clusterIP}')
RESP=$(curl -s -H "Host: api.novaedge.io" "http://${INGRESS_IP}/stream")
echo "${RESP}" | grep -q "stream_" && echo "✅ Ingress L7 stream routing operational!"
echo "========================================================"
echo " 🎉 ALL NOVAEDGE PLATFORM SERVICES ARE 100% HEALTHY!"
echo "========================================================"
```

---

<br>

---

# 🇹🇷 Türkçe Versiyon / Kapsamlı SRE Olay Müdahale Rehberi ve Post-Mortem: Lab 13 (NovaEdge)

Bu belge, **NovaEdge (`novaedge-prod` namespace)** gerçek zamanlı IoT edge akış platformunda yaşanan zincirleme kesintinin detaylı kök neden analizlerini (Root Cause Analysis - RCA), Linux çekirdeği ve Kubernetes kontrol düzlemi mekanizmalarını, adli teşhis adımlarını, kesin çözüm komutlarını ve kurumsal SRE pratiklerini içerir.

> [!NOTE]
> NovaEdge mimarisi **%100 doğrusal ve aşağıdan yukarıya (bottom-up)** zincirleme bağımlılıklarla kurgulanmıştır. Her bilet yalnızca bir önceki bilet başarıyla çözüldüğünde açığa çıkar; adımları sırayla takip ediniz.

---

## 📑 Yönetici Özeti (Incident Resolution Matrix)

| Ticket | Etkilenen Bileşen | Semptom | Kök Neden | Uygulanan Çözüm | Kontrol Düzlemi Mekanizması | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1301** | `edge-ingress` (Helm Release) | LoadBalancer port 80'de `Connection refused` | Service `targetPort: 8090` kapalı bir porta yönlendiriyor (konteyner 8080 dinliyor) | `helm-values/edge-ingress-prod.yaml` içinde `targetPort: 8080` yapılması & `helm upgrade` | `kube-proxy` (iptables / IPVS NAT) & EndpointSlice Controller | P1 - Blocker |
| **INC-1302** | `novaedge-ingress` (Ingress) | `HTTP 404 Not Found` (`api.novaedge.io/stream`) | IngressClassName uyuşmazlığı (`edge-ingress-internal`) & backend servis portu 80 hatası | `ingressClassName: edge-ingress` & `backend.service.port.number: 8080` yapılması | Ingress Controller Rule Matcher & Service Port Çözümleyicisi | P1 - Blocker |
| **INC-1303** | `stream-api` (Deployment) | `CrashLoopBackOff` (0/1 Ready), çıkış kodu 1 / 2 | Yanlış konteyner komut yolu (`/etc/app/server.py`) & `STREAM_BUFFER_SIZE: 128` doğrulama assert engeli | Komut yolunun `/app/server.py`, tampon boyutunun `4096` yapılması | Kubelet Konteyner Yaşam Döngüsü & Uygulama Doğrulama Koruması | P1 - Blocker |
| **INC-1304** | `edge-node-agent` (DaemonSet) | Node-3'te eksik (`2/3 pod`); Web node'larında çöküyor | Taint toleration yazım hatası (`value: "db"`) & çalışma hacminin `readOnly: true` bağlanması | Toleration değeri: `"database"`, `readOnly: true` kaldırılması | `kube-scheduler` TaintToleration & Linux VFS Mount İzinleri | P1 - Blocker |
| **INC-1305** | `stream-sync-worker` (Deployment) | Sürekli `0/1 Ready` (port 9200 `connection refused`) | Arka plan işleyicide HTTP sunucu olmaması (HTTP probe hatası) & yanlış Redis kanalı | Probun `exec: cat /tmp/sync-healthy` & kanalın `novaedge-telemetry` yapılması | Kubelet Prober (HTTP vs Exec) & Pub/Sub Kanal Yönlendirmesi | P2 - High |

---

## 🔧 Ticket Bazında Derinlemesine Çözümler

---

### [INC-1301] Edge Ingress Gateway Port Yönlendirme Hatası (Helm Release)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **LoadBalancer Altyapısı ile Servis Port Eşlemesini Ayırmak:**
  Dış istemciler LoadBalancer IP'sine port 80 üzerinden TCP bağlantısı kuramadığında (`Connection refused`), SRE mühendisi ilk olarak bulut yük dengeleyicisinin IP tahsisi ile küme içi Kubernetes Service port eşlemesini birbirinden ayırır.
- **Kube-Proxy ve EndpointSlice Davranışı:**
  Kubernetes'te `type: LoadBalancer` olan bir Service, node iptables / IPVS kuralları aracılığıyla `spec.ports[].port` (80) adresine gelen paketleri `spec.ports[].targetPort` ile tanımlanan konteyner portuna yönlendirir.
  `charts/edge-ingress/templates/deployment.yaml` dosyası incelendiğinde NGINX konteynerinin `8080` portunu dinlediği görülür.
  Ancak `helm-values/edge-ingress-prod.yaml` içinde `service.targetPort: 8090` tanımlanmıştır.
  EndpointSlice denetleyicisi servisin endpoint adresini `<pod_ip>:8090` olarak kaydeder. Pod ağ ad alanında 8090 portunu dinleyen hiçbir süreç olmadığı için Linux çekirdeği gelen TCP el sıkışma paketini derhal `RST` bayrağı ile reddeder (`Connection refused`).

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Edge Ingress Service ve Pod durumunu kontrol edin:
kubectl get svc,pods -n novaedge-prod -l app.kubernetes.io/name=edge-ingress -o wide
# Gözlem: Pod 1/1 Running, ancak Service targetPort 8090 olarak ayarlı.

# 2. Servis Endpoint portunu inceleyin:
kubectl get endpoints edge-ingress -n novaedge-prod
# Gözlem: <POD_IP>:8090  <--- Hatalı targetPort!

# 3. Pod içindeki gerçek açık portu test edin:
POD_NAME=$(kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=edge-ingress -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n novaedge-prod "${POD_NAME}" -- nc -zv 127.0.0.1 8080
# Gözlem: 127.0.0.1:8080 open
```

#### 3. 🛠️ Adım Adım Çözüm
1. `helm-values/edge-ingress-prod.yaml` dosyasını açın:
   - `service.targetPort` değerini `8090` yerine `8080` yapın:
```diff
 service:
   type: LoadBalancer
   port: 80
-  targetPort: 8090
+  targetPort: 8080
   nodePort: 30088
   externalTrafficPolicy: Cluster
```

2. Helm sürümünü güncelleyin:
```bash
helm upgrade edge-ingress ./charts/edge-ingress \
  -f helm-values/edge-ingress-prod.yaml \
  -n novaedge-prod
```

3. Endpoint'in güncellendiğini ve sağlık kontrolünün yanıt verdiğini doğrulayın:
```bash
kubectl get endpoints edge-ingress -n novaedge-prod
# Beklenen: <POD_IP>:8080

LB_IP=$(kubectl get svc edge-ingress -n novaedge-prod -o jsonpath='{.spec.clusterIP}')
curl -s "http://${LB_IP}/healthz"
# Beklenen: {"status":"ok","controller":"edge-ingress","ingress_class":"edge-ingress"}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Port vs TargetPort Farkı:** `port` istemcilerin dışarıdan eriştiği port; `targetPort` ise konteyner sürecinin içeride dinlediği soket portudur. Port uyuşmazlıkları servis endpoint'lerinin sessizce kör kalmasına yol açar.

---

### [INC-1302] Ingress Kaynağı Tanınmıyor & Backend Port Uyuşmazlığı (HTTP 404 / 503)

#### 1. 🧠 Diagnostic Mindset
- **Ingress Controller Class Kapsamı:**
  Çoklu ingress bulunan kümelerde Ingress denetleyicisi `spec.ingressClassName` ile eşleşen kuralları işler.
  Kümede kayıtlı IngressClass adı `edge-ingress` iken `manifests/20-ingress.yaml` içinde `edge-ingress-internal` yazılmıştır. Kontrolcü bu kaynağı tamamen yok sayar ve istemciye default backend `404 Not Found` döner.
- **Backend Servis Port Çelişkisi:**
  Ayrıca Ingress kuralı backend olarak `service.port.number: 80` belirtmiştir; ancak `stream-api` Servisi yalnızca `8080` portunu sunmaktadır. Kural yüklense bile servis portu bulunamayacağı için `503 Service Unavailable` oluşacaktır.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Ingress üzerinden istek gönderin:
INGRESS_IP=$(kubectl get svc edge-ingress -n novaedge-prod -o jsonpath='{.spec.clusterIP}')
curl -v -H "Host: api.novaedge.io" "http://${INGRESS_IP}/stream"
# Gözlem: HTTP 404 Not Found

# 2. Kümedeki IngressClass adını listeleyin:
kubectl get ingressclass
# Gözlem: edge-ingress

# 3. Ingress manifestini inceleyin:
kubectl get ingress novaedge-ingress -n novaedge-prod -o yaml
# Gözlem: ingressClassName: edge-ingress-internal, backend port: 80
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/20-ingress.yaml` dosyasını açın:
   - `ingressClassName` değerini `edge-ingress` yapın.
   - `service.port.number` değerini `8080` olarak düzeltin:
```diff
 spec:
-  ingressClassName: edge-ingress-internal
+  ingressClassName: edge-ingress
   rules:
     - host: api.novaedge.io
       http:
         paths:
           - path: /stream
             pathType: Prefix
             backend:
               service:
                 name: stream-api
                 port:
-                  number: 80
+                  number: 8080
```

2. Manifesti uygulayın:
```bash
kubectl apply -f manifests/20-ingress.yaml
```

---

### [INC-1303] Stream API Başlatma Çöküşü & Ortam Değişken Doğrulaması (CrashLoopBackOff)

#### 1. 🧠 Diagnostic Mindset
- **İki Kademeli Başlatma Engeli:**
  1. **Dosya Bulunamadı (`[Errno 2]`):** Konteyner `command: ["python3", "/etc/app/server.py"]` ile başlatılmaktadır. Oysa ConfigMap hacmi `/app` dizinine bağlanmıştır. Dosya bulunamadığı için süreç anında `exit code 2` ile kapanır.
  2. **Uygulama Doğrulama Koruması:** Yol `/app/server.py` yapıldığında kod çalışır ancak bu kez `STREAM_BUFFER_SIZE < 1024` kontrolüne takılır. Manifestoda `STREAM_BUFFER_SIZE: "128"` tanımlandığı için süreç `exit code 1` vererek kapanır.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Pod durumunu ve loglarını inceleyin:
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-api
kubectl logs -n novaedge-prod -l app.kubernetes.io/name=stream-api --tail=20
# Gözlem: can't open file '/etc/app/server.py': [Errno 2] No such file or directory
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/30-stream-api.yaml` dosyasını açın:
   - ConfigMap içinde `STREAM_BUFFER_SIZE` değerini `4096` yapın.
   - Deployment içinde komut yolunu `["python3", "/app/server.py"]` yapın:
```diff
 data:
   PORT: "8080"
-  STREAM_BUFFER_SIZE: "128"
+  STREAM_BUFFER_SIZE: "4096"
   REDIS_HOST: "novaedge-redis"
...
         containers:
           - name: api
             image: python:3.12-alpine
-            command: ["python3", "/etc/app/server.py"]
+            command: ["python3", "/app/server.py"]
```

2. Manifesti uygulayın ve doğrula:
```bash
kubectl apply -f manifests/30-stream-api.yaml
kubectl rollout status deployment/stream-api -n novaedge-prod --timeout=30s
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-api
# Beklenen: 2/2 pod Running (1/1 Ready)
```

---

### [INC-1304] Edge Node DaemonSet Taint Hatası & Volume Yazma Engeli

#### 1. 🧠 Diagnostic Mindset
- **Zamanlama ve Dosya Sistemi Çifte Arızası:**
  1. **Taint Toleration Hatası:** Node-3 üzerinde `workload=database:NoSchedule` taint'i vardır. DaemonSet toleration bloğunda `value: "db"` yazılmıştır. Değer eşleşmediği için scheduler Node-3'e pod atamaz (`DESIRED: 3, CURRENT: 2`).
  2. **Salt Okunur Hacim Mount Engeli (`[Errno 30]`):** Node-1 ve Node-2'deki pod'lar `/var/run/node-agent` dizinini `readOnly: true` olarak bağlamıştır. Agent süreci `agent.lock` dosyasını oluşturmaya çalıştığı anda çekirdek işlemi `EROFS (Read-only file system)` ile reddeder.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. DaemonSet durumunu kontrol edin:
kubectl get ds edge-node-agent -n novaedge-prod
# Gözlem: DESIRED: 3, CURRENT: 2, READY: 0

# 2. Çöken pod loglarını okuyun:
kubectl logs -n novaedge-prod -l app.kubernetes.io/name=edge-node-agent --tail=20
# Gözlem: OSError: [Errno 30] Read-only file system: '/var/run/node-agent/agent.lock'
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/40-edge-daemonset.yaml` dosyasını açın:
   - Toleration değerini `"db"` yerine `"database"` yapın.
   - `runtime-state` mount'undaki `readOnly: true` satırını kaldırın:
```diff
       tolerations:
         - key: workload
           operator: Equal
-          value: "db"
+          value: "database"
           effect: NoSchedule
...
           volumeMounts:
             - name: script
               mountPath: /opt/agent
             - name: runtime-state
               mountPath: /var/run/node-agent
-              readOnly: true
```

2. Manifesti uygulayın:
```bash
kubectl apply -f manifests/40-edge-daemonset.yaml
kubectl rollout status ds/edge-node-agent -n novaedge-prod --timeout=30s
kubectl get ds edge-node-agent -n novaedge-prod
# Beklenen: DESIRED: 3, CURRENT: 3, READY: 3
```

---

### [INC-1305] Stream Sync Worker Prob Protokolü & Kuyruk Kanalı Hatası

#### 1. 🧠 Diagnostic Mindset
- **HTTP Olmayan Arka Plan Sürecinde HTTP Prob Hatası:**
  `stream-sync-worker` bir HTTP sunucusu çalıştırmaz; arka planda Redis ve PostgreSQL arasında asenkron veri taşır. Manifestoda tanımlanan `httpGet: port: 9200` probu port kapalı olduğu için daima `connection refused` verir ve pod'u `0/1 Ready` durumunda hapseder.
- **Redis Kanal Uyuşmazlığı:**
  Worker `telemetry-stream` kanalını dinlerken, API `novaedge-telemetry` kanalına yazmaktadır. Bu durum verilerin senkronize edilmesini engeller.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Pod readiness prob hatasını inceleyin:
kubectl describe pod -n novaedge-prod -l app.kubernetes.io/name=stream-sync-worker | grep -A 5 "Readiness:"
# Gözlem: Readiness probe failed: dial tcp ...:9200: connect: connection refused
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/50-sync-worker.yaml` dosyasını açın:
   - ConfigMap içindeki kanalı `novaedge-telemetry` yapın.
   - `httpGet` probunu `/tmp/sync-healthy` dosyasını denetleyen `exec` probu ile değiştirin:
```diff
 data:
   REDIS_HOST: "novaedge-redis"
   REDIS_PORT: "6379"
-  REDIS_CHANNEL: "telemetry-stream"
+  REDIS_CHANNEL: "novaedge-telemetry"
   DB_HOST: "novaedge-db"
...
           readinessProbe:
-            httpGet:
-              path: /ready
-              port: 9200
+            exec:
+              command:
+                - cat
+                - /tmp/sync-healthy
             initialDelaySeconds: 5
             periodSeconds: 5
```

2. Manifesti uygulayın ve doğrula:
```bash
kubectl apply -f manifests/50-sync-worker.yaml
kubectl rollout status deployment/stream-sync-worker -n novaedge-prod --timeout=30s
kubectl get pods -n novaedge-prod -l app.kubernetes.io/name=stream-sync-worker
# Beklenen: 2/2 pod Running (1/1 Ready)
```

---

## 🏁 Uçtan Uca Sağlık Doğrulama Betiği

Tüm biletler tamamlandıktan sonra platform sağlığını doğrulamak için şu betiği çalıştırın:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="novaedge-prod"
echo "========================================================"
echo " 🏁 NOVAEDGE UÇTAN UCA SAĞLIK DOĞRULAMA"
echo "========================================================"

echo "=== [1/5] Çekirdek Veritabanı ve Önbellek (Postgres & Redis) ==="
kubectl get statefulset novaedge-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ PostgreSQL 16 Node-3 üzerinde 1/1 Hazır"
kubectl get deployment novaedge-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Redis 7.2 1/1 Hazır"

echo "=== [2/5] Ingress Controller & LoadBalancer ==="
kubectl get deployment edge-ingress -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ Ingress Controller 1/1 Hazır"

echo "=== [3/5] Stream API Katmanı ==="
kubectl get deployment stream-api -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "2" && echo "✅ stream-api 2/2 Hazır"

echo "=== [4/5] Küme Geneli Edge DaemonSet ==="
kubectl get ds edge-node-agent -n "${NS}" -o jsonpath='{.status.numberReady}' | grep -q "3" && echo "✅ edge-node-agent tüm 3 düğümde 3/3 Hazır"

echo "=== [5/5] Arka Plan Eşitleyici & Uçtan Uca Yönlendirme ==="
kubectl get deployment stream-sync-worker -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "2" && echo "✅ stream-sync-worker 2/2 Hazır"

INGRESS_IP=$(kubectl get svc edge-ingress -n "${NS}" -o jsonpath='{.spec.clusterIP}')
RESP=$(curl -s -H "Host: api.novaedge.io" "http://${INGRESS_IP}/stream")
echo "${RESP}" | grep -q "stream_" && echo "✅ Ingress L7 akış yönlendirmesi başarıyla HTTP 200 OK yanıtı verdi!"
echo "========================================================"
echo " 🎉 TÜM NOVAEDGE PLATFORM KATMANLARI %100 SAĞLIKLI VE DEVREDE!"
echo "========================================================"
```
