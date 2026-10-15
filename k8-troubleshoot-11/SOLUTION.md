# 🇬🇧 English Version / Comprehensive SRE Post-Mortem & Incident Remediation Guide: Lab 11 (PulseStream)

This guide documents the root cause analyses (RCA), Linux kernel and Kubernetes control plane mechanics, diagnostic commands, step-by-step remediation procedures, and enterprise SRE production takeaways for the cascading outage across the **PulseStream (`pulsestream-prod` namespace)** real-time analytics and reporting platform.

> [!NOTE]
> PulseStream is designed with a **100% linear, bottom-up cascading dependency chain**. Each ticket is unmasked only after the previous layer has been stabilized. Follow the tickets sequentially.

---

## 📑 Incident Resolution Matrix

| Ticket | Impacted Component | Symptom | Root Cause | Fix Strategy | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1001** | `db-migrator` (Job) | `DeadlineExceeded` / `Error`, Pod 0/1 | Wrong DB host (`postgres-db`) & insufficient `activeDeadlineSeconds: 4` | Host: `pulse-db`, `activeDeadlineSeconds: 60`, `kubectl replace --force` | `kube-job-controller` & Pod Immutability | P1 - Blocker |
| **INC-1002** | `analytics-worker` (Helm) | `CrashLoopBackOff` / 0/1 Ready, `Connection refused` | Helm values hierarchy scope mismatch (`redisHost` vs `backend.redis.host`) | Nested YAML hierarchy (`backend.redis.host: pulse-redis`) & `rollout restart` | Helm Template Render Engine & Values Scoping | P1 - Blocker |
| **INC-1003** | `report-api` (Deployment) | Continuous Pod restarts (0/1), Rollout deadlocked | 2.5s probe response time vs strict `timeoutSeconds: 1` | Set `timeoutSeconds: 5` in liveness/readiness probes | Kubelet Prober (HTTP Client Timeout) & ReplicaSet Controller | P1 - Blocker |
| **INC-1004** | `report-api-hpa` (HPA v2) | `TARGETS: <unknown>/70%`, `REPLICAS: 0` | Target name typo (`reporting-service`) & missing `requests.cpu` | Target: `report-api` & add `requests.cpu: 100m` | K8s Horizontal Pod Autoscaler Controller & Metrics Server API | P1 - Blocker |
| **INC-1005** | `log-agent` (DS) & `pulse-gateway` | DaemonSet 2/3 nodes; Gateway returns `502 Bad Gateway` | 5A: Missing Node-3 database taint toleration<br/>5B: Named Port mismatch (`api-http` vs `http`) | Add toleration & change container port name to `api-http` | Kube-DaemonSet Controller & kube-proxy EndpointSlice Resolver | P1 - Blocker |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-1001] Database Migration Job Failure (Job - DeadlineExceeded & Immutability)

#### 1. 🧠 Diagnostic Mindset
- **Distinguishing Job Failure Modes:**
  Kubernetes batch workloads fail primarily through two mechanisms:
  1. `BackoffLimitExceeded`: Container exits non-zero, exhausts restart retries.
  2. `DeadlineExceeded`: Total execution duration exceeds `spec.activeDeadlineSeconds`, triggering the `kube-job-controller` to force-kill all active pods.
- **Root Cause Analysis:**
  Inspecting `manifests/20-db-migration-job.yaml` reveals two faults:
  1. Target database hostname is specified as `postgres-db`, while the real Service name in the cluster is `pulse-db`.
  2. `activeDeadlineSeconds: 4` aborts the Job before its simulated schema migration (taking 8+ seconds) can complete.
- **Pod Template Immutability:**
  The Kubernetes API server rejects in-place updates to `spec.template` of an existing Job. Modifying the file and running `kubectl apply` returns `field is immutable`. The Job must be replaced using `--force` or deleted and re-created.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check Job status:
kubectl get job db-migrator -n pulsestream-prod
# Observation: COMPLETIONS: 0/1

# 2. Check Job conditions:
kubectl describe job db-migrator -n pulsestream-prod | grep -A 8 "Conditions:"
# Observation: Reason: DeadlineExceeded

# 3. Check container logs:
kubectl logs job/db-migrator -n pulsestream-prod --tail=20
# Observation: could not translate host name "postgres-db" to address
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/20-db-migration-job.yaml`:
   - Change `activeDeadlineSeconds` from `4` to `60`.
   - Update hostname from `postgres-db` to `pulse-db`:
```diff
 spec:
-  activeDeadlineSeconds: 4
+  activeDeadlineSeconds: 60
    backoffLimit: 2
    template:
      spec:
        containers:
          - name: migrator
            command: ["sh", "-c"]
            args:
              - |
                echo "Connecting to database migration target..."
-              PGPASSWORD=$POSTGRES_PASSWORD psql -h postgres-db -U pulse_admin -d pulse_analytics -c "CREATE TABLE IF NOT EXISTS events (id INT, event_type VARCHAR(50), payload TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
+              PGPASSWORD=$POSTGRES_PASSWORD psql -h pulse-db -U pulse_admin -d pulse_analytics -c "CREATE TABLE IF NOT EXISTS events (id INT, event_type VARCHAR(50), payload TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
                echo "Running analytics indexing simulation..."
                sleep 8
                echo "Migration complete."
```

2. Replace the immutable Job:
```bash
kubectl replace --force -f manifests/20-db-migration-job.yaml
```

3. Wait for Job completion:
```bash
kubectl wait --for=condition=complete job/db-migrator -n pulsestream-prod --timeout=30s
kubectl get job db-migrator -n pulsestream-prod
# Expected: COMPLETIONS: 1/1, STATUS: Complete
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Batch Deadline Budgeting:** Set `activeDeadlineSeconds` to at least 3-5x normal execution duration to prevent aborts during temporary cluster load spikes.
- **Pre-Flight Hook Architecture:** In enterprise CD pipelines, run database migrations as Helm `pre-install,pre-upgrade` hooks with `hook-delete-policy: before-hook-creation` to ensure automatic cleanup of prior attempts.

---

### [INC-1002] Analytics Worker Redis Connection Refused (Helm Scope & Values Hierarchy)

#### 1. 🧠 Diagnostic Mindset
- **Isolating Connection Failures:**
  `analytics-worker` crashes with `CrashLoopBackOff`. Pod logs report:
  `ConnectionRefusedError: [Errno 111] Connect call failed ('127.0.0.1', 6379)`
- **Helm Template Scope Investigation:**
  Inspecting `charts/pulsestream-worker/templates/deployment.yaml` reveals:
  `value: {{ .Values.backend.redis.host | default "127.0.0.1" | quote }}`
  The template searches under the nested dictionary `backend.redis.host`.
  However, in `helm-values/analytics-worker-prod.yaml`, the key is placed at root level: `redisHost: "pulse-redis"`.
  Because the nested path does not exist, Go template evaluation silently falls back to the default `127.0.0.1`, where no Redis instance runs inside the pod container.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check pod status:
kubectl get pods -n pulsestream-prod -l app.kubernetes.io/name=analytics-worker
# Observation: CrashLoopBackOff

# 2. View container logs:
kubectl logs -n pulsestream-prod -l app.kubernetes.io/name=analytics-worker --tail=20
# Observation: ConnectionRefusedError: ('127.0.0.1', 6379)

# 3. Inspect Helm template vs values hierarchy:
grep -A 5 "REDIS_HOST" charts/pulsestream-worker/templates/deployment.yaml
cat helm-values/analytics-worker-prod.yaml
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `helm-values/analytics-worker-prod.yaml`:
   - Structure values under `backend.redis.host`:
```diff
-redisHost: "pulse-redis"
+backend:
+  redis:
+    host: "pulse-redis"
```

2. Upgrade Helm release:
```bash
helm upgrade --install analytics-worker ./charts/pulsestream-worker   -f helm-values/analytics-worker-prod.yaml   -n pulsestream-prod
```

3. Confirm pod running and connected:
```bash
kubectl rollout status deployment/analytics-worker -n pulsestream-prod --timeout=30s
kubectl get pods -n pulsestream-prod -l app.kubernetes.io/name=analytics-worker
# Expected: STATUS: Running, READY: 1/1
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Helm Values Schema Validation:** Use `values.schema.json` to enforce strict JSON schema checks during `helm lint` and `helm upgrade`, catching structural mismatches before deployment.

---

### [INC-1003] Report API Deployment Rollout Deadlocked (Probe Timeout vs Latency)

#### 1. 🧠 Diagnostic Mindset
- **Rollout Hang & Probe Starvation:**
  `report-api` deployment update hangs indefinitely (`Waiting for deployment "report-api" rollout to finish...`). New pods stay at `0/1 Ready` and periodically restart.
- **Kubelet Probe Execution Mechanics:**
  Pod events highlight:
  `Liveness probe failed: HTTP probe failed with statuscode: 500 (or connection deadline exceeded)`
  `Readiness probe failed: ...`
  The Python API performs a lightweight simulated report generation during `/healthz` that takes approximately 2.5 seconds.
  However, the probe definition specifies `timeoutSeconds: 1`.
  The Kubelet HTTP client enforces a strict 1-second socket read timeout. When exceeded, the probe is recorded as failed, triggering repeated restarts and halting the ReplicaSet rollout.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check deployment rollout status:
kubectl rollout status deployment/report-api -n pulsestream-prod
# Observation: Waiting for rollout to finish...

# 2. Inspect probe failures in pod events:
kubectl describe pod -n pulsestream-prod -l app.kubernetes.io/name=report-api | grep -A 5 "Warning  Unhealthy"
# Observation: Probe failed: client timeout exceeded
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/30-report-api.yaml`:
   - Increase `timeoutSeconds` from `1` to `5` for both liveness and readiness probes:
```diff
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
-           timeoutSeconds: 1
+           timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
-           timeoutSeconds: 1
+           timeoutSeconds: 5
            failureThreshold: 3
```

2. Apply manifest and wait for rollout:
```bash
kubectl apply -f manifests/30-report-api.yaml
kubectl rollout status deployment/report-api -n pulsestream-prod --timeout=45s
kubectl get pods -n pulsestream-prod -l app.kubernetes.io/name=report-api
# Expected: STATUS: Running, READY: 1/1
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Probe Endpoint Independence:** Health check endpoints should NEVER execute heavy computational or blocking I/O tasks. Probes should return within <200ms. If processing is required, ensure `timeoutSeconds` accommodates worst-case latency.

---

### [INC-1004] Report API HPA Stuck with Unknown Metrics (Target Name Typo & CPU Requests)

#### 1. 🧠 Diagnostic Mindset
- **HPA Evaluation Engine:**
  `kubectl get hpa` shows `TARGETS: <unknown>/70%`.
  The Kubernetes `horizontal-pod-autoscaler` controller computes desired replica counts using:
  $$\text{Desired Replicas} = \left\lceil \text{Current Replicas} \times \left( \frac{\text{Current Metric Value}}{\text{Target Metric Value}} \right) \right\rceil$$
  If either pod metrics cannot be collected or the target workload does not exist, the controller marks targets as `<unknown>`.
- **Root Cause Analysis:**
  Inspecting `manifests/40-hpa.yaml` and `manifests/30-report-api.yaml` reveals:
  1. HPA targets `scaleTargetRef.name: reporting-service`, but the Deployment is named `report-api`.
  2. The container specification lacks `resources.requests.cpu`. The HPA percentage calculation cannot divide by zero or an unspecified base request.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect HPA status:
kubectl get hpa -n pulsestream-prod
# Observation: TARGETS: <unknown>/70%

# 2. View HPA events:
kubectl describe hpa report-api-hpa -n pulsestream-prod | grep -A 5 "Events:"
# Observation: FailedGetResourceMetric or FailedComputeMetricsReplicas
```

#### 3. 🛠️ Step-by-Step Resolution
1. In `manifests/30-report-api.yaml`, ensure `requests.cpu: 100m` is declared.
2. Edit `manifests/40-hpa.yaml`:
   - Change `scaleTargetRef.name` to `report-api`:
```diff
   scaleTargetRef:
     apiVersion: apps/v1
     kind: Deployment
-    name: reporting-service
+    name: report-api
```

3. Apply manifests and verify HPA metrics resolution:
```bash
kubectl apply -f manifests/30-report-api.yaml
kubectl apply -f manifests/40-hpa.yaml
kubectl get hpa report-api-hpa -n pulsestream-prod
# Expected: TARGETS shows valid percentage (e.g., 1%/70% or 2%/70%)
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Resource Requests are Mandatory for Autoscaling:** The K8s autoscaler requires explicit resource requests on every container to establish the denominator for utilization percentages.

---

### [INC-1005] DaemonSet Missing Taint Toleration & Pulse Gateway Named Port Service 502

#### 1. 🧠 Diagnostic Mindset
- **Two Intertwined Edge Failures:**
  1. **DaemonSet Missing on Dedicated Node:** `kubectl get ds log-agent` shows `DESIRED: 3, CURRENT: 2`. The pod is missing from Node-3 because Node-3 carries the taint `workload=database:NoSchedule`, which the DaemonSet does not tolerate.
  2. **Pulse Gateway 502 Bad Gateway:** The reverse proxy gateway returns `502 Bad Gateway`. Inspecting Service definitions reveals that `pulse-gateway` routes to `port: 8080`, but the Service references `targetPort: api-http`. In `manifests/30-report-api.yaml`, the container port name was misconfigured as `http` instead of `api-http`. The EndpointSlice controller maps named ports by exact string match; unmatched named ports cause endpoints to remain unresolved.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check DaemonSet deployment across nodes:
kubectl get ds log-agent -n pulsestream-prod -o wide
# Observation: Missing pod on Node-3

# 2. Test Gateway endpoint:
GATEWAY_IP=$(kubectl get svc pulse-gateway -n pulsestream-prod -o jsonpath='{.spec.clusterIP}')
curl -v "http://${GATEWAY_IP}/api/reports"
# Observation: HTTP/1.1 502 Bad Gateway

# 3. Check Service Endpoints:
kubectl get endpoints report-api -n pulsestream-prod
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/50-daemonset.yaml`:
   - Add database taint toleration:
```diff
       tolerations:
+        - key: workload
+          operator: Equal
+          value: database
+          effect: NoSchedule
```

2. Edit `manifests/30-report-api.yaml`:
   - Set container port name to `api-http`:
```diff
             ports:
-              - name: http
+              - name: api-http
                 containerPort: 8080
```

3. Apply manifests:
```bash
kubectl apply -f manifests/50-daemonset.yaml
kubectl apply -f manifests/30-report-api.yaml
kubectl rollout restart deployment/pulse-gateway -n pulsestream-prod
```

4. Verify full gateway routing:
```bash
GATEWAY_IP=$(kubectl get svc pulse-gateway -n pulsestream-prod -o jsonpath='{.spec.clusterIP}')
curl -s "http://${GATEWAY_IP}/api/reports"
# Expected: JSON response with generated analytics report (HTTP 200)
```

#### 4. 💡 SRE Production Wisdom & Takeaways
- **Named Ports vs Numeric Ports:** Named ports offer abstraction, but typos prevent EndpointSlice population without raising syntax errors.
- **Cluster-Wide DaemonSets:** Monitoring and log aggregation DaemonSets must explicitly tolerate all known node taints (control-plane, database, GPU).

---

## 🏁 End-to-End Production Health Verification

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="pulsestream-prod"
echo "========================================================"
echo " 🏁 PULSESTREAM PRODUCTION HEALTH VERIFICATION"
echo "========================================================"

echo "=== [1/5] Database Migration Job ==="
kubectl get job db-migrator -n "${NS}" -o jsonpath='{.status.succeeded}' | grep -q "1" && echo "✅ db-migrator completed"

echo "=== [2/5] Analytics Worker (Helm) ==="
kubectl get deployment analytics-worker -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ analytics-worker 1/1 Ready"

echo "=== [3/5] Report API & Probes ==="
kubectl get deployment report-api -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ report-api 1/1 Ready"

echo "=== [4/5] HPA Metrics ==="
kubectl get hpa report-api-hpa -n "${NS}"

echo "=== [5/5] Log Agent DaemonSet & Gateway Flow ==="
kubectl get ds log-agent -n "${NS}" -o jsonpath='{.status.numberReady}' | grep -q "3" && echo "✅ log-agent running on all 3 nodes"

GATEWAY_IP=$(kubectl get svc pulse-gateway -n "${NS}" -o jsonpath='{.spec.clusterIP}')
curl -s "http://${GATEWAY_IP}/api/reports" | grep -q "report_id" && echo "✅ Gateway routing operational"

echo "========================================================"
echo " 🎉 ALL PULSESTREAM SERVICES OPERATIONAL!"
echo "========================================================"
```

---

# 🇹🇷 Türkçe Versiyon / Kapsamlı SRE Olay Müdahale Rehberi ve Post-Mortem: Lab 11 (PulseStream)

Bu belge, **PulseStream (`pulsestream-prod` namespace)** platformunda yaşanan zincirleme kesintinin detaylı kök neden analizlerini (Root Cause Analysis - RCA), Linux çekirdeği ve Kubernetes kontrol düzlemi mekanizmalarını, teşhis adımlarını, kesin çözüm komutlarını ve kurumsal SRE sektör deneyimlerini içerir.

> [!NOTE]
> PulseStream mimarisi **%100 doğrusal ve aşağıdan yukarıya (bottom-up)** zincirleme bağımlılıklarla kurgulanmıştır. Her bilet yalnızca bir önceki bilet başarıyla çözüldüğünde açığa çıkar; adımları sırayla takip ediniz.

---

## 📑 Yönetici Özeti (Incident Resolution Matrix)

| Ticket | Etkilenen Bileşen | Semptom | Kök Neden | Uygulanan Çözüm | Kontrol Düzlemi Mekanizması | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1001** | `db-migrator` (Job) | `DeadlineExceeded` / `Error`, Pod 0/1 | Yanlış DB host (`postgres-db`) & `activeDeadlineSeconds: 4` yetersizliği | Host: `pulse-db`, `activeDeadlineSeconds: 60`, `kubectl replace --force` | `kube-job-controller` & Pod Immutability | P1 - Blocker |
| **INC-1002** | `analytics-worker` (Helm) | `CrashLoopBackOff` / 0/1 Ready, `Connection refused` | Helm values hiyerarşi hatası (`redisHost` vs `backend.redis.host`) | Nested YAML ağacı (`backend.redis.host: pulse-redis`) & `rollout restart` | Helm Template Render Engine & Values Scoping | P1 - Blocker |
| **INC-1003** | `report-api` (Deployment) | Pod'lar sürekli yeniden başlıyor (0/1), Rollout kilitlendi | 2.5s probe yanıt süresine karşılık `timeoutSeconds: 1` verilmesi | `timeoutSeconds: 5` tanımlanması | Kubelet Prober (HTTP Client Timeout) & ReplicaSet Controller | P1 - Blocker |
| **INC-1004** | `report-api-hpa` (HPA v2) | `TARGETS: <unknown>/70%`, `REPLICAS: 0` | Yanlış hedef (`reporting-service`) & pod `requests.cpu` eksikliği | Hedef: `report-api` & `requests.cpu: 100m` eklenmesi | K8s Horizontal Pod Autoscaler Controller & Metrics Server API | P1 - Blocker |
| **INC-1005** | `log-agent` (DS) & `pulse-gateway` | DaemonSet 2/3 node'da; Gateway'de `502 Bad Gateway` | 5A: Node-3 taint toleration eksikliği<br/>5B: Named Port uyuşmazlığı (`api-http` vs `http`) | Toleration eklenmesi & Container port adının `api-http` yapılması | Kube-DaemonSet Controller & kube-proxy EndpointSlice Resolver | P1 - Blocker |

---

## 🔧 Ticket Bazında Derinlemesine Çözümler

---

### [INC-1001] Veritabanı Göç (Migration) İşi Başarısız Oluyor (Job - DeadlineExceeded & Immutability)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Bir Kubernetes Job'ı Neden Tamamlanamaz?**
  Kubernetes `Job` nesnesi, belirli bir görevi başarıyla bitirip (`Exit Code: 0`) sonlanması beklenen toplu iş yüklerini (batch workloads) yönetir. Bir Job başarısız olduğunda SRE şu iki mekanizmayı birbirinden ayırmalıdır:
  1. **Pod İçi Hata (`BackoffLimitExceeded`):** Konteyner süreci 0 dışında bir çıkış koduyla sonlanır, Kubelet pod'u yeniden başlatmayı dener ve `backoffLimit` aşılınca Job Controller vazgeçer.
  2. **Bütçe / Zaman Aşımı (`DeadlineExceeded`):** İş tanımlanan süre zarfında tamamlanamaz ve Kubernetes kontrol düzlemi (`kube-job-controller`) çalışan tüm pod'ları zorla `SIGKILL` ile sonlandırır.
- **Teşhis Sırası:**
  1. `kubectl describe job db-migrator -n pulsestream-prod` ile Job Controller'ın durumunu inceleyin (`DeadlineExceeded` görülecektir).
  2. `kubectl logs job/db-migrator -n pulsestream-prod` ile konteynerin konsol çıktısını okuyun (`could not translate host name "postgres-db" to address` veya bağlantı hatası görülecektir).
  3. Kod incelendiğinde iki hata yakalanır:
     - Veritabanı servisinin kümedeki gerçek adı `pulse-db` iken komutta `postgres-db` yazılmıştır.
     - `sleep 8` ve indeksleme adımları en az 8-10 saniye sürerken, manifestoda `activeDeadlineSeconds: 4` verilmiştir! Kubelet henüz iş bitmeden 4. saniyede süreci öldürmektedir.
- **Kubernetes Pod Şablonu Değiştirilemezliği (Immutability):**
  Bir Job kümede bir kez oluşturulduktan sonra Kubernetes API sunucusu `spec.template` alanında güncelleme yapılmasına izin vermez (`field is immutable` hatası). Dolayısıyla manifestoyu dosyada düzeltip doğrudan `kubectl apply` yapmak yetmez; Job ya silinip yeniden uygulanmalı ya da `--force` ile değiştirilmelidir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Job durumunu ve tamamlanma oranını kontrol edin:
kubectl get job db-migrator -n pulsestream-prod
# Çıktı: COMPLETIONS: 0/1, DURATION: 4s+, AGE: ...

# 2. Job Controller olaylarını inceleyin (DeadlineExceeded kanıtı):
kubectl describe job db-migrator -n pulsestream-prod | grep -A 8 "Conditions:"
# Gözlem:
# Type: Failed, Status: True, Reason: DeadlineExceeded, Message: Job was active longer than specified deadline

# 3. İlgili pod'un loglarını okuyun (Hedef host hatası kanıtı):
kubectl logs job/db-migrator -n pulsestream-prod --tail=20
# Gözlem: psql: error: could not translate host name "postgres-db" to address

# 4. Kümedeki gerçek veritabanı servis adını doğrulayın:
kubectl get svc -n pulsestream-prod
# Gözlem: pulse-db (Port 5432)
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/20-db-migration-job.yaml` dosyasını açın:
   - `activeDeadlineSeconds` değerini `4` yerine `60` yapın.
   - Komut bloğundaki `postgres-db` ana makine adını `pulse-db` ile değiştirin:

```diff
 spec:
-  activeDeadlineSeconds: 4
+  activeDeadlineSeconds: 60
   backoffLimit: 2
   template:
     spec:
       containers:
         - name: migrator
           command: ["sh", "-c"]
           args:
             - |
               echo "Connecting to database migration target..."
-              PGPASSWORD=$POSTGRES_PASSWORD psql -h postgres-db -U pulse_admin -d pulse_analytics -c "CREATE TABLE IF NOT EXISTS events (id INT, event_type VARCHAR(50), payload TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
+              PGPASSWORD=$POSTGRES_PASSWORD psql -h pulse-db -U pulse_admin -d pulse_analytics -c "CREATE TABLE IF NOT EXISTS events (id INT, event_type VARCHAR(50), payload TEXT, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
               echo "Running analytics indexing simulation..."
               sleep 8
               echo "Migration complete."
```

2. Job değiştirilemez (immutable) olduğu için eski Job'ı zorlayarak silip yeniden oluşturun:
```bash
kubectl replace --force -f manifests/20-db-migration-job.yaml
```
*(Alternatif olarak: `kubectl delete job db-migrator -n pulsestream-prod && kubectl apply -f manifests/20-db-migration-job.yaml`)*

3. İşin tamamlandığını doğrulayın:
```bash
kubectl wait --for=condition=complete job/db-migrator -n pulsestream-prod --timeout=30s
kubectl get job db-migrator -n pulsestream-prod
# Beklenen: COMPLETIONS: 1/1, STATUS: Complete
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **`backoffLimit` vs `activeDeadlineSeconds`:**
  `backoffLimit` (varsayılan: 6) hata alan pod'ların üstel bekleme süresiyle (exponential backoff: 10s, 20s, 40s...) kaç kez tekrar deneneceğini belirler. `activeDeadlineSeconds` ise Job'ın toplam ömrüne konulan mutlak bir zamanlayıcıdır. Toplu faturalandırma veya yedekleme işlerinde bir Job sonsuz döngüye girip küme kaynaklarını tüketmesin diye `activeDeadlineSeconds` koymak üretimde şarttır; ancak bu süre işin normal süresinin en az 3-5 katı güvenlik marjıyla verilmelidir.
- **`ttlSecondsAfterFinished`:**
  Tamamlanan Job pod'ları varsayılan olarak kümede sonsuza kadar `Completed` statüsünde kalır. Bu durum `etcd` üzerinde binlerce gereksiz pod nesnesi birikmesine yol açar. Modern Kubernetes kümelerinde `ttlSecondsAfterFinished: 300` (veya 3600) tanımlanarak tamamlanan işlerin 5 dakika sonra otomatik temizlenmesi sağlanır.

---

### [INC-1002] Helm ile Kurulan analytics-worker Yanlış Konfigürasyonla Çöküyor (Helm Values Hiyerarşi / Scope Tuzağı)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **"Values Dosyasına Yazdım Ama Pod Neden Almıyor?"**
  Helm kullanırken karşılaşılan en sinsi hatalardan biri **Values Hiyerarşisi (Scope Mismatch)** sorunudur.
  Bir Helm şablonu (template) Go template motorunu kullanır:
  ```yaml
  REDIS_HOST: {{ .Values.backend.redis.host | quote }}
  ```
  Bu ifade, Helm'in kök nesnesinden (`.Values`) başlayıp `backend` sözlüğüne, oradan `redis` sözlüğüne, oradan da `host` anahtarına inmesini söyler.
- Eğer siz ortama özel `helm-values/worker-prod.yaml` dosyasında değeri kök seviyede `redisHost: "pulse-redis"` olarak tanımlarsanız:
  - Helm YAML ayrıştırıcısı bunu bir hata olarak görmez; geçerli bir YAML anahtarı kabul eder.
  - Ancak şablon `backend.redis.host` aradığında `worker-prod.yaml` içinde bu yol tanımlı olmadığı için chart'ın kendi `values.yaml` dosyasındaki varsayılan değer olan `"127.0.0.1"` değerine geri döner!
  - Sonuç: Siz dosyada `pulse-redis` yazdığınızı zannedersiniz ama Pod içinde ConfigMap `127.0.0.1` olarak derlenir ve pod Redis'e bağlanamayıp çöker.
- **Teşhis Zihniyeti:** SRE, şüphe duyduğu an `helm template` veya `helm get values <release> --all` komutuyla Helm'in ürettiği gerçek çıktıyı terminale basmalı ve değişkenin nereye düştüğünü gözleriyle görmelidir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. analytics-worker pod durumunu kontrol edin:
kubectl get pods -l app.kubernetes.io/name=analytics-worker -n pulsestream-prod
# Gözlem: 0/1 CrashLoopBackOff veya Error

# 2. Pod loglarını okuyarak bağlantı hedefini inceleyin:
kubectl logs deploy/analytics-worker -n pulsestream-prod --tail=20
# Gözlem:
# [CRITICAL] Failed to connect to Redis at 127.0.0.1:6379: [Errno 111] Connection refused

# 3. Helm'in pod'a bağladığı ConfigMap'in içeriğini okuyun:
kubectl get cm -l app.kubernetes.io/name=analytics-worker -n pulsestream-prod -o yaml | grep REDIS_HOST
# Gözlem: REDIS_HOST: "127.0.0.1" (Values ezilememiş!)

# 4. Chart'ın beklediği şablon yapısını ve default values dosyasını inceleyin:
cat charts/analytics-worker/values.yaml
# Gözlem:
# backend:
#   redis:
#     host: "127.0.0.1"

# 5. worker-prod.yaml dosyasını helm template ile derleyip test edin:
helm template test ./charts/analytics-worker -f helm-values/worker-prod.yaml | grep REDIS_HOST
# Gözlem: REDIS_HOST hala 127.0.0.1 çıkmaktadır!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `helm-values/worker-prod.yaml` dosyasını açın. Kök seviyedeki `redisHost` ve `redisPort` alanlarını doğru YAML ağacıyla (`backend.redis`) yapılandırın:

```diff
 replicaCount: 1
 
 nodeSelector:
   tier: web
 
-redisHost: "pulse-redis"
-redisPort: 6379
+backend:
+  redis:
+    host: "pulse-redis"
+    port: 6379
```

2. Değişikliği `helm upgrade` ile kümeye uygulayın:
```bash
helm upgrade analytics-worker ./charts/analytics-worker \
  -f helm-values/worker-prod.yaml \
  -n pulsestream-prod
```

3. Kubernetes ConfigMap değişikliklerini çalışan pod'lara anında yansıtmadığı için Deployment'ı yeniden başlatın:
```bash
kubectl rollout restart deployment/analytics-worker -n pulsestream-prod
kubectl rollout status deployment/analytics-worker -n pulsestream-prod --timeout=30s
```

4. Pod'un `1/1 Running` olduğunu ve Redis bağlantısının sağlandığını doğrulayın:
```bash
kubectl get pods -l app.kubernetes.io/name=analytics-worker -n pulsestream-prod
kubectl get endpoints analytics-worker -n pulsestream-prod
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **`helm get values <release>` vs `helm get values <release> --all`:**
  - `helm get values <release>`: Yalnızca sizin `--values` veya `--set` ile dışarıdan geçtiğiniz kullanıcı değerlerini listeler (bu çıktıda `redisHost: pulse-redis` görürsünüz ve her şey doğru sanırsınız).
  - `helm get values <release> --all`: Chart'ın varsayılan değerleri ile sizin değerlerinizin nihai birleşimini (computed values) gösterir. Hiyerarşi uyumsuzluklarını yakalamak için mutlaka `--all` bayrağı kullanılmalıdır.
- **GitOps & Helmfile Entegrasyonları:**
  ArgoCD veya Helmfile ile onlarca mikroservis yönetirken her servisin values yapısı farklılık gösterebilir. CI/CD hattına `helm lint` ve `helm template` aşaması ekleyerek üretilen manifestoların doğrulanması bu tip scope hatalarını canlı ortama ulaşmadan engeller.

---

### [INC-1003] report-api Güncellemesi Askıda Kaldı (ReplicaSet Rollout Deadlock & Probe Timeout)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Kubelet Sağlık Denetimi ve Zaman Aşımı Matematiği:**
  Kubernetes Kubelet bileşeni pod'ların durumunu `livenessProbe` ve `readinessProbe` ile düzenli aralıklarla sorgular.
  Bir HTTP probu şu parametrelerle çalışır:
  - `periodSeconds`: Problar arasındaki bekleme süresi (örn: 5s).
  - `timeoutSeconds`: Kubelet'in HTTP yanıtı için bekleyeceği maksimum süre (varsayılan: 1s).
  - `failureThreshold`: Kaç başarısızlıktan sonra pod'un `Unhealthy` sayılacağı.
- **Semptom:**
  Pod'un içine `kubectl exec` ile girip `curl http://localhost:8000/healthz` yaptığınızda komut 2.5 saniye sonra **HTTP 200 OK** ile başarıyla döner! Ancak Kubelet `timeoutSeconds: 1` ayarlandığı için 1.0 saniye dolduğu anda TCP bağlantısını koparır ve şu hatayı yazar:
  `Client.Timeout exceeded while awaiting headers`
- **Rollout Kilitlenmesi (Deadlock):**
  Deployment `RollingUpdate` stratejisi gereği yeni pod `Ready` (`1/1`) olmadan eski pod'ları silemez. Yeni pod'un readiness probu sürekli zaman aşımına uğradığı için pod hiçbir zaman `Ready` olamaz; Kubelet de liveness timeout nedeniyle pod'u durmadan öldürüp baştan başlatır (`CrashLoop` / yüksek restart count). Dağıtım süreci sonsuza kadar kilitlenir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. report-api pod'larının durumunu inceleyin:
kubectl get pods -l app.kubernetes.io/name=report-api -n pulsestream-prod
# Gözlem: READY: 0/1, RESTARTS: 3+, STATUS: Running / CrashLoopBackOff

# 2. Pod üzerindeki Kubelet olaylarını (Events) filtreleyin:
POD_NAME=$(kubectl get pods -l app.kubernetes.io/name=report-api -n pulsestream-prod -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod "$POD_NAME" -n pulsestream-prod | grep -E "Warning.*Unhealthy" -A 2
# Gözlem:
# Warning  Unhealthy  Kubelet  Liveness probe failed: Get "http://...:8000/healthz": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
# Warning  Unhealthy  Kubelet  Readiness probe failed: Get "http://...:8000/ready": context deadline exceeded (Client.Timeout exceeded while awaiting headers)

# 3. 30-report-api.yaml içindeki probe tanımlarını inceleyin:
grep -A 8 "livenessProbe" manifests/30-report-api.yaml
# Gözlem: timeoutSeconds: 1
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/30-report-api.yaml` dosyasını açın. Hem `livenessProbe` hem de `readinessProbe` altındaki `timeoutSeconds` değerini `1` yerine `5` yapın:

```diff
         livenessProbe:
           httpGet:
             path: /healthz
             port: 8000
           initialDelaySeconds: 3
           periodSeconds: 5
-          timeoutSeconds: 1
+          timeoutSeconds: 5
           failureThreshold: 2
         readinessProbe:
           httpGet:
             path: /ready
             port: 8000
           initialDelaySeconds: 3
           periodSeconds: 5
-          timeoutSeconds: 1
+          timeoutSeconds: 5
           failureThreshold: 2
```

2. Değişikliği kümeye uygulayın:
```bash
kubectl apply -f manifests/30-report-api.yaml
```

3. Rollout sürecini izleyin ve her iki replikanın da hazır olduğunu doğrulayın:
```bash
kubectl rollout status deployment/report-api -n pulsestream-prod --timeout=45s
kubectl get deployment report-api -n pulsestream-prod
kubectl get rs -l app.kubernetes.io/name=report-api -n pulsestream-prod
# Beklenen: READY: 2/2, UP-TO-DATE: 2, AVAILABLE: 2
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Probe Timeout ve Çığ Etkisi (Cascading Failures):**
  Ağır yük altındaki veritabanları veya mikroservisler yanıt sürelerini 50ms'den 1.5s'ye çıkarabilir. Eğer `timeoutSeconds: 1` olarak bırakılmışsa, sistem geçici bir yük dalgası yaşadığında Kubelet sağlıklı çalışan yüzlerce pod'u aynı anda öldürmeye başlar. Ölen pod'ların trafiği kalan pod'lara biner, onlar da yavaşlar ve tüm küme dakikalar içinde çöker.
- **`startupProbe` Kullanımı:**
  Uygulamanın ilk ayağa kalkışında (cache warming, veri tabanı şema kontrolü) gecikme yaşanıyorsa `livenessProbe` süresini artırmak yerine `startupProbe` tanımlanmalıdır. `startupProbe` tamamlanana kadar liveness ve readiness probları bekletilir.

---

### [INC-1004] Otomatik Ölçekleyici (HPA) Metrik Okuyamıyor ve Hedefi Bulamıyor (HorizontalPodAutoscaler)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **HPA Neden `<unknown>/70%` Gösterir?**
  Kubernetes HPA (`HorizontalPodAutoscaler`), `kube-controller-manager` içerisindeki bir döngüdür ve her 15 saniyede bir `metrics.k8s.io` API'sine sorgu atar. HPA'nın çalışabilmesi için **kesin bir sözleşme (contract)** vardır:
  1. **Hedef Kaynağın Varlığı (`scaleTargetRef`):** HPA'nın işaret ettiği Deployment veya StatefulSet kümede birebir aynı isimle var olmalıdır.
  2. **Kaynak İsteklerinin Tanımlanması (`resources.requests`):** HPA hedefi CPU yüzdesi (`averageUtilization: 70`) olarak verildiğinde, Kube-Controller formülü şu şekilde hesaplar:
     $$\text{Kullanım Oranı} = \frac{\text{Anlık Harcanan CPU}}{\text{Pod'un Talep Ettiği CPU (requests.cpu)}} \times 100$$
     Eğer pod'un `requests.cpu` değeri tanımlanmamışsa, payda sıfır/tanımsız olacağından matematiksel olarak yüzde hesaplanamaz! HPA `FailedComputeMetricsReplicas: missing request for cpu` hatasıyla felç olur.
- **Teşhis Sırası:**
  1. `kubectl describe hpa report-api-hpa -n pulsestream-prod` çalıştırın.
  2. İlk hata: `FailedGetScale: deployments.apps "reporting-service" not found`. HPA yanlış deployment adına bakmaktadır.
  3. İsim düzeltildikten sonra ikinci hata ortaya çıkar: `missing request for cpu on container report-api`. Pod'a CPU request eklenmelidir.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. HPA durumunu listeleyin:
kubectl get hpa report-api-hpa -n pulsestream-prod
# Gözlem: TARGETS: <unknown>/70%, REPLICAS: 0

# 2. HPA Controller olaylarını ve koşullarını inceleyin:
kubectl describe hpa report-api-hpa -n pulsestream-prod
# Gözlem:
# Warning  FailedGetScale  HPA  deployments.apps "reporting-service" not found

# 3. report-api pod'unun kaynak (resource) tanımlarını denetleyin:
kubectl get deploy report-api -n pulsestream-prod -o yaml | grep -A 6 "resources:"
# Gözlem:
# resources:
#   requests:
#     memory: 64Mi   <--- requests.cpu EKSİK!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/40-report-hpa.yaml` dosyasını açın. `scaleTargetRef.name` alanını `report-api` olarak düzeltin:

```diff
   scaleTargetRef:
     apiVersion: apps/v1
     kind: Deployment
-    name: reporting-service
+    name: report-api
```

2. `manifests/30-report-api.yaml` dosyasını açın. `resources.requests` altına `cpu: 100m` ekleyin:

```diff
         resources:
           requests:
+            cpu: 100m
             memory: 64Mi
           limits:
             cpu: 250m
             memory: 128Mi
```

3. Her iki manifestoyu uygulayın:
```bash
kubectl apply -f manifests/30-report-api.yaml
kubectl apply -f manifests/40-report-hpa.yaml
```

4. HPA'nın hedefi bulduğunu ve ölçeklemenin aktifleştiğini doğrulayın:
```bash
kubectl describe hpa report-api-hpa -n pulsestream-prod
# Beklenen:
# Conditions:
#   AbleToScale    True  SucceededGetScale
#   ScalingActive  True  ValidMetricFound
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **Neden `limits.cpu` Değil de `requests.cpu`?**
  Kubernetes'te `requests` garanti edilen taban tahsistir (guaranteed allocation), `limits` ise pod'un cgroup seviyesinde kısıtlanacağı tavandır. HPA, bir pod'un kapasitesini ne oranda tükettiğini ölçerken her zaman pod'a rezerve edilen taban kaynağı (`requests`) baz alır. Bu nedenle üretim ortamlarında HPA kullanılıyorsa `requests.cpu` tanımlamak zorunludur.
- **KEDA (Kubernetes Event-driven Autoscaling):**
  Modern platformlarda CPU/Memory tabanlı HPA yerine Kafka lag, Redis kuyruk uzunluğu veya HTTP istek sayısı gibi iş mantığına dayalı metriklerle ölçekleme yapmak için KEDA kullanılır.

---

### [INC-1005] Eksik Log Ajanı (DaemonSet) ve Dış Ağ Geçidi (pulse-gateway) 502 Bad Gateway Hatası

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
Bu son bilette iki kritik platform katmanı doğrulanır:
- **Bileşen 5A: DaemonSet Taint Toleration Eksikliği:**
  DaemonSet'in varlık sebebi kümedeki **her bir fiziksel/sanal node üzerinde tam 1 adet pod çalıştırmaktır**. Kümenizde 3 adet node vardır:
  - Node-1 (`tier=web`, lekesiz/untainted)
  - Node-2 (`tier=web`, lekesiz/untainted)
  - Node-3 (`tier=database`, Taint: `workload=database:NoSchedule`)
  `kubectl get ds log-agent` çıktısında `DESIRED: 2, CURRENT: 2` görünüyorsa, DaemonSet Controller Node-3'ü dışlamış demektir! Çünkü Node-3 üzerindeki `workload=database:NoSchedule` taint'i için pod şablonunda toleration yoktur. Veritabanı node'undan log toplayabilmek için bu toleration eklenmelidir.
- **Bileşen 5B: Named Port (Hedef Port Adı) Sözleşmesi ve 502 Bad Gateway:**
  `pulse-gateway` (Nginx), gelen istekleri `http://report-api/reports` servisine yönlendirir. Ancak kullanıcılar `502 Bad Gateway` almaktadır. Nginx hata günlüğünde `111: Connection refused` görülür.
  - SRE hemen `kubectl get endpoints report-api -n pulsestream-prod` komutunu çalıştırır ve `ENDPOINTS: <none>` görür!
  - `report-api` pod'ları çalışmaktadır (`2/2 Ready`). Selector etiketleri de doğrudur.
  - O halde sorun nedir? **Named Port Eşleşmezliği!**
    - `report-api` Service tanımında: `targetPort: api-http`
    - `report-api` Pod tanımında: `containerPort: 8000, name: http`
    - Kubernetes Endpoints Controller, pod üzerindeki port adı ile servisin hedef port adını eşleştiremediğinde o pod'u endpoint listesine **eklemez**. Servise gelen paketler hiçbir pod'a gidemez ve Nginx 502 döner.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. DaemonSet'in kaç node'da çalıştığını inceleyin:
kubectl get ds log-agent -n pulsestream-prod
# Gözlem: DESIRED: 2, CURRENT: 2, READY: 2 (Kümede 3 node varken eksik!)

# 2. pulse-gateway üzerinden rapor API'sini çağırarak hatayı teyit edin:
kubectl exec -n pulsestream-prod deploy/pulse-gateway -- wget -qO- http://localhost:8080/api/reports
# Gözlem: wget: server returned error: HTTP/1.1 502 Bad Gateway

# 3. report-api servisinin uç noktalarını (Endpoints) sorgulayın:
kubectl get endpoints report-api -n pulsestream-prod
# Gözlem: ENDPOINTS: <none>  <--- Kritik Kanıt!

# 4. Servis ile Pod arasındaki port adlarını karşılaştırın:
kubectl get svc report-api -n pulsestream-prod -o jsonpath='{.spec.ports[0].targetPort}'
# Çıktı: api-http

kubectl get deploy report-api -n pulsestream-prod -o jsonpath='{.spec.template.spec.containers[0].ports[0].name}'
# Çıktı: http  <--- Eşleşmiyor!
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/50-edge-and-daemon.yaml` dosyasını açın. `log-agent` DaemonSet şablonuna Node-3 için veritabanı toleration'ını ekleyin:

```diff
   template:
     metadata:
       labels:
         app.kubernetes.io/name: log-agent
     spec:
+      tolerations:
+        - key: "workload"
+          operator: "Equal"
+          value: "database"
+          effect: "NoSchedule"
       containers:
         - name: log-agent
```

2. `manifests/30-report-api.yaml` dosyasını açın. Konteyner port adını servisin beklediği `api-http` olarak güncelleyin:

```diff
       containers:
         - name: report-api
           ports:
             - containerPort: 8000
-              name: http
+              name: api-http
```

3. Manifestoları uygulayın:
```bash
kubectl apply -f manifests/50-edge-and-daemon.yaml
kubectl apply -f manifests/30-report-api.yaml
```

4. Doğrulama:
```bash
# A. DaemonSet'in 3 node'da da çalıştığını doğrulayın:
kubectl get ds log-agent -n pulsestream-prod
# Beklenen: DESIRED: 3, CURRENT: 3, READY: 3

# B. report-api servisinin endpoint listesinin dolduğunu doğrulayın:
kubectl get endpoints report-api -n pulsestream-prod
# Beklenen: 10.0.10.x:8000, 10.0.10.y:8000

# C. pulse-gateway üzerinden rapor verisini çekin:
kubectl exec -n pulsestream-prod deploy/pulse-gateway -- wget -qO- http://localhost:8080/api/reports
```

Beklenen Nihai Başarı JSON Çıktısı:
```json
{
  "platform": "PulseStream",
  "status": "active",
  "realtime_metrics": {
    "throughput_rps": 1250,
    "p99_latency_ms": 14.2
  }
}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar (Production Karşılaştırması)
- **DaemonSet vs PodAntiAffinity:**
  Log toplayıcılar (Fluentbit, Promtail), güvenlik ajanları (Falco, Datadog) ve CNI eklentileri (Cilium, Calico) için her zaman DaemonSet kullanılır. Deployment + `podAntiAffinity` ile her node'a 1 pod koymak mümkündür; ancak kümeye yeni bir node katıldığında Deployment bunu otomatik algılayıp ölçekleyemez, DaemonSet ise yeni node ayağa kalktığı anda otomatik olarak oraya pod yerleştirir.
- **Named Port (IETF RFC 6335) Standardı:**
  Mikroservis mimarilerinde port numarası yerine `targetPort: api-http` gibi semantik port isimleri kullanmak en iyi uygulamadır (best practice). Bu sayede uygulama konteynerinin dinlediği port 8000'den 8080'e veya 9000'e çekildiğinde sadece pod tanımında `containerPort` değiştirilir; dışarıdaki onlarca Service ve Ingress manifestosuna dokunmak gerekmez.

---

## 🏁 Uçtan Uca Production Sağlık Kontrolü (Bottom-Up Checklist)

Tüm adımları başarıyla tamamladıktan sonra sistemin sıhhatini doğrulamak için aşağıdaki kontrol listesini çalıştırın:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="pulsestream-prod"
echo "=== [1/6] Katman 0: Durumsal Veri Tabanı Kontrolü ==="
kubectl get sts pulse-db -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ pulse-db 1/1 Ready"
kubectl get deploy pulse-redis -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ pulse-redis 1/1 Ready"

echo "=== [2/6] Katman 1: Şema Migrasyon Kontrolü ==="
kubectl get job db-migrator -n "${NS}" -o jsonpath='{.status.succeeded}' | grep -q "1" && echo "✅ db-migrator Job Succeeded (1/1)"
kubectl exec -n "${NS}" pulse-db-0 -- psql -U pulse_admin -d pulse_analytics -c "\dt" | grep -q "events" && echo "✅ PostgreSQL 'events' tablosu doğrulandı"

echo "=== [3/6] Katman 2: Veri Akış İşçisi Kontrolü ==="
kubectl get deploy analytics-worker -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "1" && echo "✅ analytics-worker 1/1 Ready"

echo "=== [4/6] Katman 3: Raporlama API Dağıtım Kontrolü ==="
kubectl rollout status deployment/report-api -n "${NS}" --timeout=5s
kubectl get deploy report-api -n "${NS}" -o jsonpath='{.status.readyReplicas}' | grep -q "2" && echo "✅ report-api 2/2 Replicas Ready"

echo "=== [5/6] Katman 4: Otomatik Ölçekleme (HPA) Kontrolü ==="
HPA_TARGET=$(kubectl get hpa report-api-hpa -n "${NS}" -o jsonpath='{.spec.scaleTargetRef.name}')
[ "${HPA_TARGET}" = "report-api" ] && echo "✅ HPA 'report-api' Deployment'ını hedefliyor"
kubectl describe hpa report-api-hpa -n "${NS}" | grep -q -E "(AbleToScale.*True|ScalingActive.*True)" && echo "✅ HPA metrik hesaplaması aktif"

echo "=== [6/6] Katman 5: Ağ Geçidi & DaemonSet Kontrolü ==="
kubectl get ds log-agent -n "${NS}" -o jsonpath='{.status.numberReady}' | grep -q "3" && echo "✅ log-agent DaemonSet 3 düğümün tamamında çalışıyor"
GATEWAY_RESP=$(kubectl exec -n "${NS}" deploy/pulse-gateway -- wget -qO- http://localhost:8080/api/reports)
echo "${GATEWAY_RESP}" | grep -q "PulseStream" && echo "✅ pulse-gateway 200 OK ile analitik verisini döndürdü"

echo "🎉 PULSESTREAM PLATFORMUNUN TÜM KATMANLARI SAĞLIKLI VE DEVREDE!"
```
