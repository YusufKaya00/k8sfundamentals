# 🚨 SRE Incident Lab 8: Helix Ledger — Production Go-Live Triage

This workspace serves as the active **Incident Triage War Room** during the mission-critical production go-live failure of **Helix Ledger**, an enterprise financial accounting and transactional ledger platform.

All manifests deployed to the cluster are **syntactically valid** and accepted without errors by the Kubernetes API server. Yet the platform fails to initialize: pods fail to schedule, containers repeatedly crash, services cannot discover or route to upstreams, and public web endpoints return gateway errors.

Your objective: triage and remediate the incident tickets **in sequential order**, perform root cause analysis (RCA) based on runtime symptoms, and satisfy the **Success Criteria** for each ticket.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Senior SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)** — *Attempt resolution on your own before consulting the guide!*

---

## 🗺️ Cluster Topology & Infrastructure Constraints

The incident scenario is grounded strictly in the following 3-node cluster topology:

| Node Name | Internal IP | Label | Constraint / Taint | Allocated Tier Role |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-2** | `10.0.10.208` | `tier=web` | *None* | Web / API / Gateway Workloads |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Database Workloads Only (Isolated) |

* **Target Namespace:** `helix-prod`
* **Default StorageClass:** `oci-bv` (Oracle Block Volume CSI, dynamic provisioning, ReadWriteOnce)
* **Public Ingress / Inbound:** `helix-gateway` Service → NodePort `30880`
* **Core Components:** `helix-db` (PostgreSQL 16 StatefulSet) → `helix-api` (Python API + `discovery` sidecar) → `helix-gateway` (nginx)

> [!IMPORTANT]
> **Prerequisite:** The cluster CNI must **enforce NetworkPolicies** (e.g., Calico, Cilium, or OCI VCN-Native with Calico network policy engine enabled). Without network policy enforcement, security boundary tickets and the final isolation negative test cannot be verified.
>
> ```bash
> kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|antrea|weave'
> ```

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all manifests to deploy the initial broken state:

```bash
kubectl apply -f manifests/
```

Inspect the initial broken state across the namespace:

```bash
kubectl get pods,svc,endpoints,pvc -n helix-prod -o wide
kubectl get events -n helix-prod --sort-by=.lastTimestamp
```

---

## 📋 On-Call SRE Incident Board

Tickets are inter-dependent; resolve them **sequentially**. Fixing one ticket may reveal the underlying runtime symptom of the next.

---

### [INC-801] Ledger Database Pod Stuck in Pending
* **Priority:** `P1 - Blocker`
* **Alert (Prometheus / Alertmanager):**
  > `[CRITICAL] KubePodNotScheduled: helix-prod/helix-db-0 has been in Pending state for more than 5 minutes.`
* **Symptoms:**
  * `helix-db-0` cannot be scheduled to any node; `NODE` column shows `<none>`.
  * `kubectl describe pod` events display `FailedScheduling`: messages indicate some nodes fail the pod's node selector, while the remaining node carries a taint that the pod does not tolerate.
  * The entire downstream application tier is blocked waiting for database connectivity.
* **Success Criteria & Verification:**
  ```bash
  kubectl get pod helix-db-0 -n helix-prod -o wide
  ```
  Expected: `READY 1/1`, `STATUS Running` (transitioning into CrashLoop is covered by INC-802), scheduled on **`10.0.10.78`** (`Node-3`).
  > Note: As soon as the pod binds and begins running on Node-3, this ticket is satisfied; subsequent container crashes belong to INC-802.

---

### [INC-802] Database CrashLoopBackOff — initdb Fails to Initialize
* **Priority:** `P1 - Blocker`
* **Slack (#helix-oncall):**
  > **@dba-bot:** `helix-db-0` has finally landed on Node-3, but it keeps restarting. Logs show `initdb: error: directory "/var/lib/postgresql/data" exists but is not empty`. The block volume is completely brand new, nobody touched it?! 🤔
* **Symptoms:**
  * Pod is stuck in `CrashLoopBackOff`; restart count continuously increments.
  * `kubectl logs helix-db-0 -n helix-prod --previous` indicates PostgreSQL `initdb` refuses to initialize inside a non-empty directory.
  * PVC status is `Bound`; the block volume attached and mounted cleanly.
  * `helix-db` Service has no active endpoints.
* **Success Criteria & Verification:**
  ```bash
  kubectl get pod helix-db-0 -n helix-prod
  # Expected: 1/1 Running, RESTARTS stops incrementing

  kubectl exec -n helix-prod helix-db-0 -- pg_isready -U helix_app -d helix_ledger
  # Expected: /var/run/postgresql:5432 - accepting connections

  kubectl get endpoints helix-db -n helix-prod
  # Expected: ENDPOINTS shows <pod-ip>:5432 (e.g. 10.0.10.x:5432)
  ```

---

### [INC-803] API Container Bootstraps and Exits ~10s Later — "configuration validation failed"
* **Priority:** `P1 - Blocker`
* **PagerDuty:**
  > `[TRIGGERED] helix-prod/helix-api — container "api" terminated with exit code 1 (Error). Pods: 0/2 available.`
* **Symptoms:**
  * In `helix-api` pods, container `api` starts up, logs `helix-api: bootstrapping runtime`, and terminates approximately 10 seconds later.
  * Log output:
    ```
    FATAL: configuration validation failed, unset variables: [...]
    ```
  * Pod creation does not trigger any warning events; both Secret and ConfigMap exist, and there is no `CreateContainerConfigError`.
* **Success Criteria & Verification:**
  ```bash
  kubectl logs -n helix-prod deploy/helix-api -c api | head
  ```
  Expected output:
  ```
  helix-api: configuration valid, warming ledger caches
  ```
  Additional non-leaking env check:
  ```bash
  kubectl exec -n helix-prod deploy/helix-api -c api -- sh -c 'test -n "$DB_PASSWORD" && echo SET || echo UNSET'
  # Expected: SET
  ```

---

### [INC-804] API Container Cycles in Restart Every ~20s — Startup Probe Timeout
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[WARNING] KubePodCrashLooping: helix-prod/helix-api-* container "api" restarting (>5 restarts / 10m).`
* **Symptoms:**
  * The configuration validation failure is gone; logs proceed to `configuration valid`, but `listening on :8080` is never reached.
  * Kubelet kills the container approximately 20 seconds after launch.
  * `kubectl describe pod` events show:
    ```
    Warning  Unhealthy  ...  Startup probe failed: Get "http://10.x.x.x:8080/healthz": dial tcp ...: connect: connection refused
    Normal   Killing    ...  Container api failed startup probe, will be restarted
    ```
* **Success Criteria & Verification:**
  ```bash
  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api -w
  # Expected: RESTARTS count for container 'api' ceases to increment

  kubectl logs -n helix-prod deploy/helix-api -c api
  # Expected line: helix-api: listening on :8080
  ```

---

### [INC-805] API NotReady — "database unreachable" (While DB is Running)
* **Priority:** `P1 - Blocker`
* **Slack (#helix-oncall):**
  > **@app-team:** Database is green, `pg_isready` reports OK, and endpoints are healthy. Yet API pods remain NotReady with `/ready` returning 503. Logs report network timeout. Is this an SDN / firewall issue? 🧐
* **Symptoms:**
  * Container `api` is active and running, but its readiness check fails: `kubectl describe` → `Readiness probe failed: HTTP probe failed with statuscode: 503`.
  * Logs indicate:
    ```
    readiness: database helix-db:5432 unreachable: timed out
    ```
  * DNS name resolution operates normally (failure is a socket **timeout**, not `Name or service not known`).
  * `helix-db-0` is `1/1 Running` and its endpoints are populated.
* **Success Criteria & Verification:**
  ```bash
  # Test TCP reachability from API pod to DB (no curl in container, use python)
  kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
    "import socket; socket.create_connection(('helix-db',5432),timeout=3).close(); print('DB TCP OK')"
  # Expected: DB TCP OK

  kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
    "import urllib.request as u; r=u.urlopen('http://localhost:8080/ready'); print(r.status, r.read().decode())"
  # Expected: 200 {"database": "up"}
  ```

---

### [INC-806] Discovery Sidecar Crashes — "service account credentials not found"
* **Priority:** `P2 - High`
* **PagerDuty:**
  > `[TRIGGERED] helix-prod/helix-api — container "discovery" CrashLoopBackOff. Pods report 1/2 Ready.`
* **Symptoms:**
  * Container `api` is now Ready, but the pod status remains `1/2`.
  * `kubectl logs ... -c discovery`:
    ```
    FATAL: service account credentials not found: [Errno 2] No such file or directory: '/var/run/secrets/kubernetes.io/serviceaccount/token'
    ```
  * `kubectl get pod -o yaml` confirms the pod is assigned the designated ServiceAccount (`helix-api`).
* **Success Criteria & Verification:**
  ```bash
  kubectl exec -n helix-prod deploy/helix-api -c discovery -- ls /var/run/secrets/kubernetes.io/serviceaccount/
  # Expected: ca.crt  namespace  token
  ```
  > Note: The sidecar may immediately proceed to fail with an authorization error — this is covered by INC-807.

---

### [INC-807] Discovery Sidecar Receives 403 Forbidden
* **Priority:** `P2 - High`
* **Slack (#platform-security):**
  > **@sec-audit:** API server audit logs show repeated **403 Forbidden** events from `system:serviceaccount:helix-prod:helix-api`. A RoleBinding appears to be defined, but it does not seem to take effect.
* **Symptoms:**
  * The discovery container now mounts and reads the token, but crashes with:
    ```
    FATAL: kubernetes api returned 403: {"kind":"Status",...,"message":"endpoints \"helix-db\" is forbidden: User \"system:serviceaccount:helix-prod:helix-api\" cannot get resource \"endpoints\" ...
    ```
  * Both Role and RoleBinding resources exist within the `helix-prod` namespace.
* **Success Criteria & Verification:**
  ```bash
  kubectl auth can-i get endpoints -n helix-prod \
    --as=system:serviceaccount:helix-prod:helix-api
  # Expected: yes
  ```
  > Note: If this command continues to return `no`, inspect all layers of the RBAC binding (see INC-808).

---

### [INC-808] 403 Forbidden Persists Despite Prior RBAC Binding
* **Priority:** `P2 - High`
* **Slack (#helix-oncall):**
  > **@oncall-2:** I thought we resolved INC-807 — the binding now clearly points to the correct ServiceAccount! Yet the discovery sidecar still throws the exact same 403 error. `can-i` still says `no`. 😩
* **Symptoms:**
  * RoleBinding subject and roleRef definitions appear syntactically sound.
  * Discovery sidecar continues to exit with `403 ... cannot get resource "endpoints"`.
  * Pod status remains locked at `1/2 Ready`.
* **💡 Diagnostics Tip:** To audit effective permissions granted to the ServiceAccount:
  ```bash
  kubectl auth can-i --list -n helix-prod --as=system:serviceaccount:helix-prod:helix-api
  ```
  Additionally, consult `kubectl api-resources` to cross-reference resource names and their respective API groups.
* **Success Criteria & Verification:**
  ```bash
  kubectl auth can-i get endpoints -n helix-prod \
    --as=system:serviceaccount:helix-prod:helix-api
  # Expected: yes

  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api
  # Expected: both pods 2/2 Running, RESTARTS stable

  kubectl logs -n helix-prod deploy/helix-api -c discovery --tail=3
  # Expected: discovery: helix-db backends=['10.x.x.x']
  ```

---

### [INC-809] Gateway Pods Stuck in Pending — FailedScheduling
* **Priority:** `P1 - Blocker`
* **Alert:**
  > `[CRITICAL] KubeDeploymentReplicasMismatch: helix-prod/helix-gateway has 0/2 available replicas.`
* **Symptoms:**
  * Both `helix-gateway` pods remain stuck in `Pending`.
  * Events indicate:
    ```
    Warning  FailedScheduling  ...  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector ...
    ```
  * Nodes 1 and 2 (`tier=web`) possess ample allocatable CPU and memory capacity.
* **Success Criteria & Verification:**
  ```bash
  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-gateway -o wide
  ```
  Expected: 2 pods `1/1 Running`; one on `10.0.10.122` (Node-1), the other on `10.0.10.208` (Node-2).

---

### [INC-810] Portal Root Responds but `/api/status` Returns 502 Bad Gateway
* **Priority:** `P1 - Blocker`
* **PagerDuty (Synthetic Monitoring):**
  > `[TRIGGERED] helix-ledger-public — GET http://10.0.10.122:30880/api/status returned HTTP 502 (3/3 locations).`
* **Symptoms:**
  * Ingress to `http://<node-ip>:30880/` loads the index portal successfully.
  * Ingress to `/api/status` returns `502 Bad Gateway`; Nginx access logs record upstream connection failures.
  * API pods report `2/2 Ready`, yet:
    ```bash
    kubectl get endpoints helix-api -n helix-prod
    # NAME        ENDPOINTS   AGE
    # helix-api   <none>      ...
    ```
* **Success Criteria & Verification:**
  ```bash
  kubectl get endpoints helix-api -n helix-prod
  # Expected: two IP addresses, e.g. 10.x.x.a:8080,10.x.x.b:8080

  curl -s -w '\nHTTP %{http_code}\n' http://10.0.10.122:30880/api/status
  # Expected: {"service": "helix-api", "pod": "helix-api-...", "database": "up"}
  #           HTTP 200
  ```

---

## ✅ FINAL: End-to-End Production Health Checklist

Once all tickets have been resolved, perform this multi-tier verification sequence to prove production readiness. This checklist models real-world platform verification before signing off an incident.

### 1. Database Tier Health & State
```bash
kubectl get statefulset,pod,pvc -n helix-prod -l app.kubernetes.io/name=helix-db -o wide
# Expected: StatefulSet 1/1, pod 1/1 Running on 10.0.10.78, PVC Bound (oci-bv)

kubectl exec -n helix-prod helix-db-0 -- pg_isready -U helix_app -d helix_ledger
# Expected: accepting connections

kubectl exec -n helix-prod helix-db-0 -- psql -U helix_app -d helix_ledger -c 'select 1;'
# Expected: 1 row returned
```

### 2. Service Endpoints Discovery
```bash
kubectl get endpoints -n helix-prod
# Expected: helix-db (1 IP), helix-api (2 IPs), helix-gateway (2 IPs) — none should be <none>
```

### 3. Application-to-Database Connectivity Matrix
```bash
for p in $(kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api -o name); do
  kubectl exec -n helix-prod $p -c api -- python -c \
    "import socket; socket.create_connection(('helix-db',5432),timeout=3).close(); print('$p DB OK')"
done
# Expected: "DB OK" for each pod
```

### 4. Application HTTP Endpoint Verification
```bash
kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
  "import urllib.request as u
for p in ['/healthz','/ready','/api/status']:
    r=u.urlopen('http://localhost:8080'+p); print(p, r.status, r.read().decode())"
# Expected: HTTP 200 across all three endpoints
```

### 5. Gateway In-Cluster Upstream Proxy
```bash
kubectl exec -n helix-prod deploy/helix-gateway -- wget -qO- http://localhost:8080/healthz
kubectl exec -n helix-prod deploy/helix-gateway -- wget -qO- http://helix-api:8080/api/status
# Expected: HTTP 200 responses for both local health and upstream proxy
```

### 6. NodePort External Access (From Both Web Nodes)
```bash
for ip in 10.0.10.122 10.0.10.208; do
  echo "== $ip"
  curl -s -o /dev/null -w 'index      HTTP %{http_code}\n' http://$ip:30880/
  curl -s -o /dev/null -w 'api/status HTTP %{http_code}\n' http://$ip:30880/api/status
done
# Expected: HTTP 200 for both index and api/status on every node
```
> Tip: Query `/api/status` repeatedly to observe traffic balancing between the two API pod replicas.

### 7. RBAC Least-Privilege Verification Matrix
```bash
SA=system:serviceaccount:helix-prod:helix-api
for verb in get list watch; do
  echo -n "$verb endpoints (helix-prod): "; kubectl auth can-i $verb endpoints -n helix-prod --as=$SA
done
echo -n "get secrets (helix-prod):      "; kubectl auth can-i get secrets -n helix-prod --as=$SA
echo -n "delete pods (helix-prod):      "; kubectl auth can-i delete pods -n helix-prod --as=$SA
echo -n "get endpoints (default):       "; kubectl auth can-i get endpoints -n default --as=$SA
```
| Verification Check | Expected Result |
| :--- | :--- |
| get / list / watch endpoints (`helix-prod`) | `yes` |
| get secrets (`helix-prod`) | `no` |
| delete pods (`helix-prod`) | `no` |
| get endpoints (`default`) | `no` |

### 8. NetworkPolicy Negative Isolation Test (Unprivileged Pod MUST NOT Reach DB)
```bash
# Ephemeral pod in same namespace without helix-api label
kubectl run np-probe -n helix-prod --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.36 -- nc -zv -w 3 helix-db 5432
# Expected: connection timeout / failure

# Ephemeral pod in default namespace
kubectl run np-probe -n default --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.36 -- nc -zv -w 3 helix-db.helix-prod.svc.cluster.local 5432
# Expected: connection timeout / failure
```
> [!WARNING]
> If these connections **succeed**, database isolation is compromised (or the cluster CNI does not enforce NetworkPolicies). Both positive (Step 3) and negative tests must pass.

### 9. Event & Warning Audit
```bash
kubectl get events -n helix-prod --field-selector type=Warning --sort-by=.lastTimestamp
# Expected: no new Warning events in recent minutes
```

### 10. Pod Stability & Restart Audit
```bash
kubectl get pods -n helix-prod -o custom-columns=\
POD:.metadata.name,NODE:.status.hostIP,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount
# Expected: RESTARTS counts must remain stable
```

**If all criteria are satisfied:** 🎉 Helix Ledger is fully operational. Draft your post-mortem and compare with **[SOLUTION.md](./SOLUTION.md)**.

---

## 🧹 Teardown

```bash
kubectl delete -f manifests/
# Clean up StatefulSet PVCs (not removed automatically)
kubectl delete pvc -n helix-prod -l app.kubernetes.io/name=helix-db --ignore-not-found
kubectl delete pvc data-helix-db-0 -n helix-prod --ignore-not-found
kubectl delete namespace helix-prod --ignore-not-found
```
> [!CAUTION]
> Deleting the PVC may trigger permanent storage deletion on OCI Block Volume depending on the StorageClass `reclaimPolicy`.

---

<br>

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# 🚨 SRE Incident Lab 8: Helix Ledger — Production Go-Live Triage

Bu çalışma alanı, kritik muhasebe/defter (ledger) platformu **Helix Ledger**'ın production go-live sürecinde yaşanan arızalar için kurulan **Incident War Room**'dur.

Cluster'a uygulanan tüm manifest'ler **şema açısından geçerlidir** ve Kubernetes API server tarafından hatasız kabul edilmiştir. Buna rağmen platform ayağa kalkmıyor: pod'lar schedule edilmiyor, container'lar çöküyor, servisler birbirine ulaşamıyor ve dış dünyaya açılan web sitesi hata veriyor.

Göreviniz: ticket'ları **sırayla** ele almak, semptomlardan yola çıkarak kök nedeni kendiniz bulmak ve her ticket'ın **Başarı Kriteri**'ni sağlamak.

> 📖 **Post-Mortem & Kök Neden Analizleri (RCA):**
> 👉 **[Senior SRE Post-Mortem Rehberi (SOLUTION.md)](./SOLUTION.md)** — *Önce kendiniz deneyin!*

---

## 🗺️ Cluster Topolojisi & Altyapı Kısıtları

Senaryo aşağıdaki 3 node'lu cluster topolojisine dayanır:

| Node | IP | Label | Kısıt / Taint | Tier Rolü |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *Yok* | Web / API / Gateway iş yükleri |
| **Node-2** | `10.0.10.208` | `tier=web` | *Yok* | Web / API / Gateway iş yükleri |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Yalnızca veritabanı (izole) |

* **Hedef Namespace:** `helix-prod`
* **StorageClass:** `oci-bv` (OCI Block Volume, dinamik provisioning)
* **Dış Erişim:** `helix-gateway` Service → NodePort `30880`
* **Bileşenler:** `helix-db` (PostgreSQL 16 StatefulSet) → `helix-api` (Python API + `discovery` sidecar) → `helix-gateway` (nginx)

> [!IMPORTANT]
> **Ön koşul:** Cluster'daki CNI eklentisi **NetworkPolicy'yi enforce etmelidir** (ör. Calico, Cilium veya OCI VCN-Native + Calico policy). NetworkPolicy desteklemeyen bir CNI'da bazı ticket'lar ve final negatif testi anlamsız olur.
>
> ```bash
> kubectl get pods -n kube-system -o wide | grep -Ei 'calico|cilium|antrea|weave'
> ```

---

## 🚀 Ortamın Kurulumu (Bozuk Platformun Deploy Edilmesi)

Tüm manifest'leri uygulayın:

```bash
kubectl apply -f manifests/
```

İlk durumu izleyin:

```bash
kubectl get pods,svc,endpoints,pvc -n helix-prod -o wide
kubectl get events -n helix-prod --sort-by=.lastTimestamp
```

---

## 📋 On-Call SRE Incident Board

Ticket'lar birbirine bağımlıdır; **sırayla** çözün. Bir ticket çözüldüğünde bir sonraki semptom ortaya çıkabilir.

---

### [INC-801] Ledger Veritabanı Pod'u Pending'de Takılı
* **Öncelik:** `P1 - Blocker`
* **Alarm (Prometheus / Alertmanager):**
  > `[CRITICAL] KubePodNotScheduled: helix-prod/helix-db-0 has been in Pending state for more than 5 minutes.`
* **Semptomlar:**
  * `helix-db-0` hiçbir node'a atanamıyor, `NODE` sütunu `<none>`.
  * `kubectl describe pod` event'lerinde `FailedScheduling` görülüyor; mesajda node'ların bir kısmının pod'un node selector'ı ile eşleşmediği, kalan node'un ise pod'un tolere etmediği bir taint'e sahip olduğu belirtiliyor.
  * Uygulama katmanının tamamı veritabanını beklediği için zincirleme bozuk.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl get pod helix-db-0 -n helix-prod -o wide
  ```
  Beklenen: `READY 1/1`, `STATUS Running` (CrashLoop'a düşmesi bir sonraki ticket'ın konusudur), `NODE`/IP olarak **`10.0.10.78`** (Node-3).
  > Not: Pod Node-3'e schedule edildiği anda bu ticket kapanır; pod'un ardından çökmesi INC-802 kapsamındadır.

---

### [INC-802] Veritabanı CrashLoopBackOff — initdb Başlatılamıyor
* **Öncelik:** `P1 - Blocker`
* **Slack (#helix-oncall):**
  > **@dba-bot:** `helix-db-0` artık Node-3'te ama sürekli restart ediyor. Loglarda `initdb: error: directory "/var/lib/postgresql/data" exists but is not empty` gibi bir şey var. Volume yepyeni, içine kimse bir şey yazmadı?! 🤔
* **Semptomlar:**
  * Pod `CrashLoopBackOff`, restart sayısı sürekli artıyor.
  * `kubectl logs helix-db-0 -n helix-prod --previous` çıktısında initdb'nin veri dizininin boş olmadığından şikayet ettiği görülüyor.
  * PVC `Bound`, block volume başarıyla attach/mount edilmiş.
  * `helix-db` Service'inin endpoint'i yok.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl get pod helix-db-0 -n helix-prod
  # Beklenen: 1/1 Running, RESTARTS artmıyor

  kubectl exec -n helix-prod helix-db-0 -- pg_isready -U helix_app -d helix_ledger
  # Beklenen: /var/run/postgresql:5432 - accepting connections

  kubectl get endpoints helix-db -n helix-prod
  # Beklenen: ENDPOINTS sütununda <pod-ip>:5432 (ör. 10.0.10.x:5432)
  ```

---

### [INC-803] API Container Açılıp ~10 sn Sonra Kapanıyor — "configuration validation failed"
* **Öncelik:** `P1 - Blocker`
* **PagerDuty:**
  > `[TRIGGERED] helix-prod/helix-api — container "api" terminated with exit code 1 (Error). Pods: 0/2 available.`
* **Semptomlar:**
  * `helix-api` pod'larında `api` container'ı başlıyor, `helix-api: bootstrapping runtime` logluyor ve yaklaşık 10 saniye sonra çıkıyor.
  * Log:
    ```
    FATAL: configuration validation failed, unset variables: [...]
    ```
  * Pod oluşturulurken hiçbir event hata vermiyor; Secret ve ConfigMap mevcut, `CreateContainerConfigError` yok.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl logs -n helix-prod deploy/helix-api -c api | head
  ```
  Beklenen satır:
  ```
  helix-api: configuration valid, warming ledger caches
  ```
  Ek kontrol (değer gösterilmeden yalnızca varlık):
  ```bash
  kubectl exec -n helix-prod deploy/helix-api -c api -- sh -c 'test -n "$DB_PASSWORD" && echo SET || echo UNSET'
  # Beklenen: SET
  ```

---

### [INC-804] API Container'ı Her ~20 Saniyede Bir Restart Ediyor
* **Öncelik:** `P1 - Blocker`
* **Alarm:**
  > `[WARNING] KubePodCrashLooping: helix-prod/helix-api-* container "api" restarting (>5 restarts / 10m).`
* **Semptomlar:**
  * Konfigürasyon hatası artık yok; log `configuration valid` satırına kadar ilerliyor fakat `listening on :8080` satırı hiç görünmüyor.
  * Container başladıktan yaklaşık 20 saniye sonra kubelet tarafından öldürülüyor.
  * `kubectl describe pod` event'leri:
    ```
    Warning  Unhealthy  ...  Startup probe failed: Get "http://10.x.x.x:8080/healthz": dial tcp ...: connect: connection refused
    Normal   Killing    ...  Container api failed startup probe, will be restarted
    ```
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api -w
  # Beklenen: api container'ı için RESTARTS sayısı artık artmıyor

  kubectl logs -n helix-prod deploy/helix-api -c api
  # Beklenen satır: helix-api: listening on :8080
  ```

---

### [INC-805] API Hazır Değil — "database unreachable" (DB Running Olduğu Halde)
* **Öncelik:** `P1 - Blocker`
* **Slack (#helix-oncall):**
  > **@app-team:** DB yeşil, `pg_isready` OK, endpoint'i de var. Ama API pod'ları hâlâ NotReady ve `/ready` 503 dönüyor. Loglarda timeout var. Network mü? 🧐
* **Semptomlar:**
  * `api` container'ı ayakta ve stabil, fakat readiness başarısız; `kubectl describe` → `Readiness probe failed: HTTP probe failed with statuscode: 503`.
  * Log:
    ```
    readiness: database helix-db:5432 unreachable: timed out
    ```
  * DNS çözümlemesi çalışıyor (hata `Name or service not known` değil, **timeout**).
  * `helix-db` pod'u `1/1 Running`, endpoint'i dolu.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  # API pod'undan DB'ye TCP bağlantısı (imajda curl yok, python kullanın)
  kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
    "import socket; socket.create_connection(('helix-db',5432),timeout=3).close(); print('DB TCP OK')"
  # Beklenen: DB TCP OK

  kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
    "import urllib.request as u; r=u.urlopen('http://localhost:8080/ready'); print(r.status, r.read().decode())"
  # Beklenen: 200 {"database": "up"}
  ```

---

### [INC-806] Discovery Sidecar Çöküyor — "service account credentials not found"
* **Öncelik:** `P2 - High`
* **PagerDuty:**
  > `[TRIGGERED] helix-prod/helix-api — container "discovery" CrashLoopBackOff. Pods report 1/2 Ready.`
* **Semptomlar:**
  * `api` container'ı artık Ready; ancak pod `1/2` görünüyor.
  * `kubectl logs ... -c discovery`:
    ```
    FATAL: service account credentials not found: [Errno 2] No such file or directory: '/var/run/secrets/kubernetes.io/serviceaccount/token'
    ```
  * Pod'un doğru ServiceAccount (`helix-api`) ile çalıştığı `kubectl get pod -o yaml` ile görülebiliyor.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl exec -n helix-prod deploy/helix-api -c discovery -- ls /var/run/secrets/kubernetes.io/serviceaccount/
  # Beklenen: ca.crt  namespace  token
  ```
  > Not: Sidecar bu noktada farklı bir hata ile çökmeye devam edebilir — bu bir sonraki ticket'ın konusudur.

---

### [INC-807] Discovery Sidecar 403 Forbidden Alıyor
* **Öncelik:** `P2 - High`
* **Slack (#platform-security):**
  > **@sec-audit:** API server audit loglarında `system:serviceaccount:helix-prod:helix-api` için ardışık **403** kayıtları görüyoruz. Bir RoleBinding var gibi görünüyor ama etkisi yok gibi.
* **Semptomlar:**
  * Discovery artık token'ı okuyor, fakat log:
    ```
    FATAL: kubernetes api returned 403: {"kind":"Status",...,"message":"endpoints \"helix-db\" is forbidden: User \"system:serviceaccount:helix-prod:helix-api\" cannot get resource \"endpoints\" ...
    ```
  * `helix-prod` namespace'inde ilgili Role ve RoleBinding nesneleri mevcut.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl auth can-i get endpoints -n helix-prod \
    --as=system:serviceaccount:helix-prod:helix-api
  # Beklenen: yes
  ```
  > Not: Bu komut `no` dönmeye devam ediyorsa sorun tek katmanlı olmayabilir — bkz. INC-808.

---

### [INC-808] Önceki Düzeltmeye Rağmen Hâlâ 403
* **Öncelik:** `P2 - High`
* **Slack (#helix-oncall):**
  > **@oncall-2:** INC-807'yi kapattık sanıyordum, binding artık doğru ServiceAccount'u gösteriyor. Ama sidecar hâlâ aynı 403'ü basıyor. `can-i` hâlâ `no` diyor. 😩
* **Semptomlar:**
  * RoleBinding'in subject'i ve roleRef'i görünürde doğru.
  * Discovery sidecar aynı `403 ... cannot get resource "endpoints"` mesajıyla çıkıyor.
  * Pod `1/2 Ready` durumunda kalıyor.
* **💡 İpucu (araç):** ServiceAccount'un gerçekte hangi yetkilere sahip olduğunu listelemek için:
  ```bash
  kubectl auth can-i --list -n helix-prod --as=system:serviceaccount:helix-prod:helix-api
  ```
  Ayrıca `kubectl api-resources` çıktısı, kaynakların hangi API grubuna ait olduğunu gösterir.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl auth can-i get endpoints -n helix-prod \
    --as=system:serviceaccount:helix-prod:helix-api
  # Beklenen: yes

  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api
  # Beklenen: her iki pod 2/2 Running, RESTARTS sabit

  kubectl logs -n helix-prod deploy/helix-api -c discovery --tail=3
  # Beklenen: discovery: helix-db backends=['10.x.x.x']
  ```

---

### [INC-809] Gateway Pod'ları Pending — FailedScheduling
* **Öncelik:** `P1 - Blocker`
* **Alarm:**
  > `[CRITICAL] KubeDeploymentReplicasMismatch: helix-prod/helix-gateway has 0/2 available replicas.`
* **Semptomlar:**
  * Her iki `helix-gateway` pod'u `Pending`.
  * Event:
    ```
    Warning  FailedScheduling  ...  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector ...
    ```
  * Web node'larında (Node-1/Node-2) yeterli CPU/bellek mevcut.
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-gateway -o wide
  ```
  Beklenen: 2 pod `1/1 Running`; biri `10.0.10.122` (Node-1), diğeri `10.0.10.208` (Node-2) üzerinde.

---

### [INC-810] Ana Sayfa Açılıyor ama `/api/status` 502 Bad Gateway
* **Öncelik:** `P1 - Blocker`
* **PagerDuty (Synthetic Monitoring):**
  > `[TRIGGERED] helix-ledger-public — GET http://10.0.10.122:30880/api/status returned HTTP 502 (3/3 locations).`
* **Semptomlar:**
  * `http://<node-ip>:30880/` index sayfası sorunsuz dönüyor.
  * `/api/status` → `502 Bad Gateway`; nginx loglarında upstream bağlantı hataları var.
  * API pod'ları `2/2 Ready`, ancak:
    ```bash
    kubectl get endpoints helix-api -n helix-prod
    # NAME        ENDPOINTS   AGE
    # helix-api   <none>      ...
    ```
* **Başarı Kriteri & Doğrulama:**
  ```bash
  kubectl get endpoints helix-api -n helix-prod
  # Beklenen: iki IP, ör. 10.x.x.a:8080,10.x.x.b:8080

  curl -s -w '\nHTTP %{http_code}\n' http://10.0.10.122:30880/api/status
  # Beklenen: {"service": "helix-api", "pod": "helix-api-...", "database": "up"}
  #           HTTP 200
  ```

---

## ✅ FİNAL: Uçtan Uca Sağlık Kontrol Listesi

Tüm ticket'lar kapandıktan sonra platformun **gerçekten** sağlıklı olduğunu katman katman doğrulayın. Bu liste, çalışan herhangi bir web sitesi için genel bir "go-live" kontrolüdür.

### 1. Veritabanı Katmanı
```bash
kubectl get statefulset,pod,pvc -n helix-prod -l app.kubernetes.io/name=helix-db -o wide
# Beklenen: StatefulSet 1/1, pod 1/1 Running @ 10.0.10.78, PVC Bound (oci-bv)

kubectl exec -n helix-prod helix-db-0 -- pg_isready -U helix_app -d helix_ledger
# Beklenen: accepting connections

kubectl exec -n helix-prod helix-db-0 -- psql -U helix_app -d helix_ledger -c 'select 1;'
# Beklenen: 1 satır döner
```

### 2. Service Endpoint'leri
```bash
kubectl get endpoints -n helix-prod
# Beklenen: helix-db (1 IP), helix-api (2 IP), helix-gateway (2 IP) — hiçbiri <none> değil
```

### 3. Uygulama → Veritabanı Bağlantısı
```bash
for p in $(kubectl get pods -n helix-prod -l app.kubernetes.io/name=helix-api -o name); do
  kubectl exec -n helix-prod $p -c api -- python -c \
    "import socket; socket.create_connection(('helix-db',5432),timeout=3).close(); print('$p DB OK')"
done
# Beklenen: her pod için "DB OK"
```

### 4. Uygulama Endpoint'leri
```bash
kubectl exec -n helix-prod deploy/helix-api -c api -- python -c \
  "import urllib.request as u
for p in ['/healthz','/ready','/api/status']:
    r=u.urlopen('http://localhost:8080'+p); print(p, r.status, r.read().decode())"
# Beklenen: üçü de 200
```

### 5. Gateway (cluster içi)
```bash
kubectl exec -n helix-prod deploy/helix-gateway -- wget -qO- http://localhost:8080/healthz
kubectl exec -n helix-prod deploy/helix-gateway -- wget -qO- http://helix-api:8080/api/status
# Beklenen: her ikisi de başarılı yanıt
```

### 6. NodePort — Dış Erişim (her iki web node'undan)
```bash
for ip in 10.0.10.122 10.0.10.208; do
  echo "== $ip"
  curl -s -o /dev/null -w 'index      HTTP %{http_code}\n' http://$ip:30880/
  curl -s -o /dev/null -w 'api/status HTTP %{http_code}\n' http://$ip:30880/api/status
done
# Beklenen: her node için iki satır da HTTP 200
```
> İpucu: `/api/status` isteğini birkaç kez tekrarlayın; JSON'daki `pod` alanının iki farklı API pod'u arasında değiştiğini (yük dağılımı) görmelisiniz.

### 7. RBAC Yetki Matrisi (en az yetki prensibi)
```bash
SA=system:serviceaccount:helix-prod:helix-api
for verb in get list watch; do
  echo -n "$verb endpoints (helix-prod): "; kubectl auth can-i $verb endpoints -n helix-prod --as=$SA
done
echo -n "get secrets (helix-prod):      "; kubectl auth can-i get secrets -n helix-prod --as=$SA
echo -n "delete pods (helix-prod):      "; kubectl auth can-i delete pods -n helix-prod --as=$SA
echo -n "get endpoints (default):       "; kubectl auth can-i get endpoints -n default --as=$SA
```
| Kontrol | Beklenen |
| :--- | :--- |
| get / list / watch endpoints (`helix-prod`) | `yes` |
| get secrets (`helix-prod`) | `no` |
| delete pods (`helix-prod`) | `no` |
| get endpoints (`default`) | `no` |

### 8. NetworkPolicy Negatif Testi (rastgele pod DB'ye ULAŞAMAMALI)
```bash
# Aynı namespace'te, helix-api label'ı taşımayan geçici bir pod
kubectl run np-probe -n helix-prod --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.36 -- nc -zv -w 3 helix-db 5432
# Beklenen: timeout / başarısız bağlantı

# Başka bir namespace'ten
kubectl run np-probe -n default --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.36 -- nc -zv -w 3 helix-db.helix-prod.svc.cluster.local 5432
# Beklenen: timeout / başarısız bağlantı
```
> [!WARNING]
> Bu test **başarılı bağlanıyorsa** veritabanınız gereğinden geniş erişime açıktır (ya da CNI NetworkPolicy'yi enforce etmiyordur). Pozitif test (3. adım) **ve** negatif test birlikte geçmelidir.

### 9. Event / Warning Taraması
```bash
kubectl get events -n helix-prod --field-selector type=Warning --sort-by=.lastTimestamp
# Beklenen: son birkaç dakikada yeni Warning yok (eski kayıtlar kalabilir)
```

### 10. Restart Kontrolü
```bash
kubectl get pods -n helix-prod -o custom-columns=\
POD:.metadata.name,NODE:.status.hostIP,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount
# Birkaç dakika bekleyip tekrar çalıştırın — RESTARTS değerleri artmamalı
```

**Tümü yeşil ise:** 🎉 Helix Ledger production'da. Post-mortem'inizi yazın ve **[SOLUTION.md](./SOLUTION.md)** ile karşılaştırın.

---

## 🧹 Temizlik (Teardown)

```bash
kubectl delete -f manifests/
# StatefulSet PVC'leri otomatik silinmez:
kubectl delete pvc -n helix-prod -l app.kubernetes.io/name=helix-db --ignore-not-found
kubectl delete pvc data-helix-db-0 -n helix-prod --ignore-not-found
kubectl delete namespace helix-prod --ignore-not-found
```
> [!CAUTION]
> PVC silindiğinde `oci-bv` StorageClass'ın `reclaimPolicy` değerine bağlı olarak OCI Block Volume da kalıcı olarak silinebilir.
