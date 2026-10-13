# 🛠️ SRE Incident Remediation Guide & Post-Mortem: Lab 7 (NexusLogistics)

This guide documents the root cause analyses (RCA), architectural remediation steps, and verification procedures for **Incident Lab 7 (NexusLogistics Autonomous Dispatch Grid Outage)**.

---

## 📑 Incident Executive Summary

| Ticket ID | Impacted Component | Root Cause | Fix Strategy | Severity |
| :--- | :--- | :--- | :--- | :--- |
| **[INC-701]** | `queue-data-pvc` / `event-queue` | StorageClass `fast-nvme-storage` does not exist & `ReadWriteMany` rejected by OCI Block Volume CSI. | Update StorageClass to `oci-bv` and accessMode to `ReadWriteOnce`. | `P1 - Blocker` |
| **[INC-702]** | `order-worker` (Deployment) | Env var references non-existent key `QUEUE_AUTH_KEY` in `nexus-secrets` (actual key is `QUEUE_AUTH_TOKEN`). | Update secret key reference to `QUEUE_AUTH_TOKEN`. | `P1 - Blocker` |
| **[INC-703]** | `order-worker` (InitContainer) | InitContainer polls hostname `dispatch-database:5432` (actual Service name is `dispatch-db`). | Correct hostname to `dispatch-db:5432` in initContainer command. | `P1 - Blocker` |
| **[INC-704]** | `order-worker` (Deployment) | Cgroup memory limit set to `24Mi` while Python startup and in-memory buffer allocate 28MB (`OOMKilled` Exit Code 137). | Increase memory request to `64Mi` and limit to `128Mi`. | `P1 - Blocker` |
| **[INC-705]** | `order-worker` (RBAC) | In-cluster API discovery denied with `HTTP 403 Forbidden` under default ServiceAccount. | Create `ServiceAccount`, `Role`, `RoleBinding` granting `endpoints` read access. | `P2 - High` |
| **[INC-706]** | `dispatch-gateway` (Service) | LoadBalancer Service selector has `app.kubernetes.io/name: dispatch-gw` instead of `dispatch-gateway` (`Endpoints: <none>`). | Update Service selector to `app.kubernetes.io/name: dispatch-gateway`. | `P1 - Blocker` |
| **[INC-707]** | `gateway-config` (ConfigMap) | NGINX upstream defines `server routing-api:8080;` instead of `server routing-engine:8080;` (`502 Bad Gateway`). | Correct upstream host in NGINX config to `routing-engine:8080` and reload. | `P1 - Blocker` |
| **[INC-708]** | `routing-engine` (Deployment) | Hard anti-affinity (`requiredDuringScheduling...`) on 3 replicas across a 2-node web pool leaves 3rd replica `Pending`. | Relax anti-affinity to soft (`preferredDuringScheduling...`). | `P2 - High` |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-701] Remediation: Event Queue Volume Binding Failed

#### 1. Root Cause Analysis (RCA)
`StatefulSet/event-queue` depends on `PersistentVolumeClaim/queue-data-pvc`. In `manifests/30-queue.yaml`:
```yaml
spec:
  storageClassName: "fast-nvme-storage"  # Non-existent StorageClass
  accessModes:
  - ReadWriteMany                        # Unsupported access mode
```
1. `fast-nvme-storage` does not exist on this cluster (`kubectl get sc` shows only `oci-bv` and `oci`).
2. Even if a storage provisioner were matched, block volumes (`oci-bv` CSI driver `blockvolume.csi.oraclecloud.com`) cannot be attached concurrently across multiple nodes in `ReadWriteMany` mode. Block volumes are strictly `ReadWriteOnce`.
As a result, the PVC remains stuck in `Pending` and `event-queue-0` cannot be scheduled.

#### 2. Corrected Manifest Patch
In `manifests/30-queue.yaml`:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: queue-data-pvc
  namespace: nexus-prod
  labels:
    app.kubernetes.io/name: event-queue
    app.kubernetes.io/part-of: nexus-logistics
spec:
  storageClassName: "oci-bv"
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
```

#### 3. Execution Commands
Because Kubernetes PVC `spec` is immutable once created, delete the stuck PVC and reapply:
```bash
kubectl delete pvc queue-data-pvc -n nexus-prod
kubectl apply -f manifests/30-queue.yaml
```

#### 4. Verification Commands
```bash
# Verify PVC binds and pod reaches 1/1 Running
kubectl get pvc,pods -l app.kubernetes.io/name=event-queue -n nexus-prod

# Verify Redis authentication and responsiveness
kubectl exec -n nexus-prod event-queue-0 -- redis-cli -a nexus-token-alpha-99x ping
# Expected output: PONG
```

---

### [INC-702] Remediation: Dispatch Worker Pod Stuck in CreateContainerConfigError

#### 1. Root Cause Analysis (RCA)
`order-worker` container fails to initialize and gets stuck in `CreateContainerConfigError`.
Inspecting events:
```bash
kubectl describe pod -l app.kubernetes.io/name=order-worker -n nexus-prod
```
Shows:
`Error: secret "nexus-secrets" does not contain key "QUEUE_AUTH_KEY"`
Inspecting `manifests/10-config.yaml` shows the secret defines `QUEUE_AUTH_TOKEN: "nexus-token-alpha-99x"`. `manifests/50-worker.yaml` incorrectly referenced `QUEUE_AUTH_KEY`.

#### 2. Corrected Manifest Patch
In `manifests/50-worker.yaml`:
```yaml
        - name: QUEUE_TOKEN
          valueFrom:
            secretKeyRef:
              name: nexus-secrets
              key: QUEUE_AUTH_TOKEN  # Fixed: aligned with secret definition
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/50-worker.yaml
```

#### 4. Verification Commands
```bash
# Verify the pod moves past CreateContainerConfigError into Init stage
kubectl get pods -l app.kubernetes.io/name=order-worker -n nexus-prod
# Expected status: Init:0/1
```

---

### [INC-703] Remediation: Dispatch Worker InitContainer Infinite Loop

#### 1. Root Cause Analysis (RCA)
Once the secret key is corrected, the pod is stuck in `Init:0/1`.
Checking init container logs:
```bash
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c wait-for-database --tail=5
```
Shows:
`[INIT] Database unreachable at dispatch-database:5432, retrying in 2s...`
The initContainer script tests `dispatch-database:5432`. However, the PostgreSQL service created in `20-database.yaml` is named `dispatch-db`. CoreDNS returns `NXDOMAIN` for `dispatch-database`, causing the socket connection loop to retry forever.

#### 2. Corrected Manifest Patch
In `manifests/50-worker.yaml`:
```yaml
      initContainers:
      - name: wait-for-database
        image: docker.io/library/python:3.11-alpine
        command:
        - sh
        - -c
        - |
          echo "[INIT] Checking Dispatch Database connectivity..."
          until python3 -c "import socket; s = socket.create_connection(('dispatch-db', 5432), timeout=2); s.close()"; do
            echo "[INIT] Database unreachable at dispatch-db:5432, retrying in 2s..."
            sleep 2
          done
          echo "[INIT] Database is ready and reachable!"
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/50-worker.yaml
```

#### 4. Verification Commands
```bash
# Check init container logs to confirm exit code 0
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c wait-for-database --tail=2
# Expected output: [INIT] Database is ready and reachable!
```

---

### [INC-704] Remediation: Dispatch Worker Cyclic OOMKilled Termination

#### 1. Root Cause Analysis (RCA)
With the init container passing, the primary `worker` container crashes repeatedly:
```bash
kubectl describe pod -l app.kubernetes.io/name=order-worker -n nexus-prod | grep -E "Last State|Reason|Exit Code"
```
Shows:
`Last State: Terminated, Reason: OOMKilled, Exit Code: 137`
The worker Python process initializes a 28MB in-memory dispatch buffer (`bytearray(28 * 1024 * 1024)`). However, `manifests/50-worker.yaml` specifies:
```yaml
resources:
  limits:
    memory: "24Mi"
```
When memory usage exceeds 24Mi, the Linux kernel cgroup OOM killer terminates the container immediately with SIGKILL (Exit code 128 + 9 = 137).

#### 2. Corrected Manifest Patch
In `manifests/50-worker.yaml`:
```yaml
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"   # Fixed: safe baseline
          limits:
            cpu: "200m"
            memory: "128Mi"  # Fixed: provides headroom above the 28MB buffer
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/50-worker.yaml
```

#### 4. Verification Commands
```bash
# Confirm pod transitions to Running and does not restart
kubectl get pods -l app.kubernetes.io/name=order-worker -n nexus-prod
# Verify worker startup logs
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker | grep "Batch buffer initialized"
```

---

### [INC-705] Remediation: In-Cluster Peer Discovery Access Denied (RBAC)

#### 1. Root Cause Analysis (RCA)
Inspect worker logs:
```bash
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker
```
Outputs:
`[SECURITY ALERT] In-cluster sync failed: HTTP 403 Forbidden - Access Denied on /api/v1/namespaces/nexus-prod/endpoints/dispatch-gateway`
Testing RBAC authorization:
```bash
kubectl auth can-i get endpoints --as=system:serviceaccount:nexus-prod:default -n nexus-prod
# Output: no
```
By default, the projected ServiceAccount token in Kubernetes lacks permissions to query cluster API objects. The worker requires read access (`get, list`) on `endpoints` in `nexus-prod`.

#### 2. Corrected Manifest Patch
Create `manifests/55-rbac.yaml`:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nexus-worker-sa
  namespace: nexus-prod
  labels:
    app.kubernetes.io/name: order-worker
    app.kubernetes.io/part-of: nexus-logistics
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: endpoint-reader-role
  namespace: nexus-prod
  labels:
    app.kubernetes.io/part-of: nexus-logistics
rules:
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: nexus-worker-endpoint-binding
  namespace: nexus-prod
  labels:
    app.kubernetes.io/part-of: nexus-logistics
subjects:
- kind: ServiceAccount
  name: nexus-worker-sa
  namespace: nexus-prod
roleRef:
  kind: Role
  name: endpoint-reader-role
  apiGroup: rbac.authorization.k8s.io
```

And in `manifests/50-worker.yaml`, configure `spec.template.spec.serviceAccountName`:
```yaml
    spec:
      serviceAccountName: nexus-worker-sa  # Attached dedicated ServiceAccount
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/55-rbac.yaml
kubectl apply -f manifests/50-worker.yaml
```

#### 4. Verification Commands
```bash
# Verify RBAC permission evaluation
kubectl auth can-i get endpoints --as=system:serviceaccount:nexus-prod:nexus-worker-sa -n nexus-prod
# Expected output: yes

# Verify worker logs confirm successful sync
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker | grep "HTTP 200 OK"
# Expected output: [SYNC] In-cluster peer discovery succeeded: HTTP 200 OK (Endpoints verified)
```

---

### [INC-706] Remediation: Public Dispatch Gateway Has Zero Endpoints

#### 1. Root Cause Analysis (RCA)
Check service endpoints:
```bash
kubectl get endpoints dispatch-gateway -n nexus-prod
```
Outputs:
`NAME               ENDPOINTS   AGE`  
`dispatch-gateway   <none>      ...`

Inspect the Service definition:
```bash
kubectl get svc dispatch-gateway -n nexus-prod -o jsonpath='{.spec.selector}'
```
Outputs: `{"app.kubernetes.io/name":"dispatch-gw"}`  
However, the pods created by `manifests/60-gateway.yaml` have label:
`app.kubernetes.io/name: dispatch-gateway`  
Because the selector does not match the pod labels, kube-proxy creates zero endpoint slices, rendering the LoadBalancer unreachable.

#### 2. Corrected Manifest Patch
In `manifests/60-gateway.yaml`:
```yaml
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: dispatch-gateway  # Fixed: matches pod label
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/60-gateway.yaml
```

#### 4. Verification Commands
```bash
# Verify active IP endpoints populated
kubectl get endpoints dispatch-gateway -n nexus-prod
# Expected output: IP of dispatch-gateway pod:8080
```

---

### [INC-707] Remediation: Gateway Reverse Proxy Upstream 502 Bad Gateway

#### 1. Root Cause Analysis (RCA)
Direct healthcheck on the gateway succeeds:
```bash
kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/healthz
# Output: {"status":"healthy","service":"dispatch-gateway"}
```
However, querying the routing API:
```bash
kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -S -O- http://localhost:8080/api/v1/routes
```
Returns:
`HTTP/1.1 502 Bad Gateway`  
Checking NGINX logs:
```bash
kubectl logs -l app.kubernetes.io/name=dispatch-gateway -n nexus-prod
```
Outputs:
`[error] ... routing-api could not be resolved (3: Host not found)`  
In `manifests/10-config.yaml`, the NGINX upstream is defined as:
```nginx
upstream routing_backend {
    server routing-api:8080;  # Hostname typo
}
```
The active Kubernetes service defined in `40-engine.yaml` is `routing-engine`.

#### 2. Corrected Manifest Patch
In `manifests/10-config.yaml`:
```nginx
        upstream routing_backend {
            server routing-engine:8080;  # Fixed: matches active service
        }
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/10-config.yaml
kubectl rollout restart deployment/dispatch-gateway -n nexus-prod
```

#### 4. Verification Commands
```bash
# Verify successful response through the gateway
kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/api/v1/routes
# Expected output:
# {"grid":"nexus","routes":[{"id":"NEX-101","origin":"FRA-CENTRAL","dest":"BER-DEPOT","status":"OPTIMAL"},{"id":"NEX-102","origin":"MUC-LOGISTICS","dest":"HAM-PORT","status":"DISPATCHED"}]}
```

---

### [INC-708] Remediation: Routing Engine Scheduling Deadlock

#### 1. Root Cause Analysis (RCA)
Inspect deployment status:
```bash
kubectl get deployment routing-engine -n nexus-prod
```
Shows: `2/3 ready`. One pod is permanently stuck in `Pending`.  
Checking scheduler events:
```bash
kubectl describe pod -l app.kubernetes.io/name=routing-engine -n nexus-prod | grep -A 3 "Warning  FailedScheduling"
```
Shows:
`0/3 nodes are available: 1 node has untolerated taint (workload=database:NoSchedule), 2 nodes didn't match pod anti-affinity rules.`  
The cluster has 3 nodes, but Node-3 is dedicated to database workloads. The remaining web pool has only 2 nodes (`10.0.10.122` and `10.0.10.208`). Because `manifests/40-engine.yaml` enforces:
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchExpressions:
        - key: app.kubernetes.io/name
          operator: In
          values:
          - routing-engine
      topologyKey: "kubernetes.io/hostname"
```
The scheduler cannot place replica 3 on either web node without violating the hard anti-affinity rule.

#### 2. Corrected Manifest Patch
In `manifests/40-engine.yaml`, convert hard anti-affinity to soft anti-affinity (`preferredDuringSchedulingIgnoredDuringExecution`):
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
                  values:
                  - routing-engine
              topologyKey: "kubernetes.io/hostname"
```

#### 3. Execution Commands
```bash
kubectl apply -f manifests/40-engine.yaml
```

#### 4. Verification Commands
```bash
# Verify all 3 replicas reach 1/1 Running across available nodes
kubectl get pods -l app.kubernetes.io/name=routing-engine -n nexus-prod -o wide
# Expected output: 3 pods Running across 10.0.10.122 and 10.0.10.208
```

---

## 🎯 Production Architecture Post-Mortem & Prevention

1. **StorageClass & AccessMode Validation:**
   - Avoid hardcoding proprietary StorageClass names across multi-cloud environments.
   - Implement policy validation (Kyverno / OPA) to prevent `ReadWriteMany` requests against non-NFS / non-EFS block storage classes.

2. **Secret & ConfigMap Key Validation in CI:**
   - Use `kubeconform` with custom schema checks or pre-commit git hooks that verify `valueFrom.secretKeyRef.key` exists in referenced Secret manifests before applying to cluster.

3. **Memory Limits & Cgroup v2 Budgeting:**
   - Always benchmark base runtime memory footprints (Python + libraries requires at least 40-50MB).
   - Set memory requests to baseline idle consumption and memory limits to at least 2.5x idle to absorb burst allocations without trigger-happy OOM kills.

4. **Principle of Least Privilege (PoLP) RBAC:**
   - Never rely on the default ServiceAccount for in-cluster API communication.
   - Always declare explicit `ServiceAccount`, `Role`, and `RoleBinding` objects scoped strictly to the minimal necessary verbs (`get`, `list`).

5. **Soft vs Hard Topology Constraints:**
   - On small node pools ($N \le 3$), avoid `requiredDuringScheduling` anti-affinity when replica count $R \ge N$.
   - Always prefer `preferredDuringScheduling` with high weights (`weight: 100`) to guarantee high availability without risking un-schedulable pods during node drains or scaling events.
