# 🚨 SRE Incident Lab 7: NexusLogistics Autonomous Dispatch Grid Triage

This workspace serves as the active Incident Triage War Room during the mission-critical production go-live failure of **NexusLogistics Global**, an enterprise real-time freight routing, autonomous fleet scheduling, and warehouse dispatch platform.

All manifests deployed to the cluster are **syntactically valid** and accepted without errors by the Kubernetes API server. However, storage provisioner rejections, secret reference typos, dependency hostname resolution loops, Linux cgroup memory limit starvation, in-cluster RBAC authorization denials, cloud LoadBalancer selector drift, NGINX reverse proxy upstream mismatches, and strict pod anti-affinity scheduling deadlocks have brought the autonomous dispatch grid to a complete standstill.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Senior SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)**

---

## 🗺️ Cluster Topology & Infrastructure Constraints

The incident scenario is grounded strictly in the following 3-node cluster topology:

| Node Name | Internal IP | Label | Constraint / Taint | Allocated Tier Role |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *None* | Web / API / Gateway / Worker Workloads |
| **Node-2** | `10.0.10.208` | `tier=web` | *None* | Web / API / Gateway / Worker Workloads |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Database Workloads Only (Isolated) |

* **Target Namespace:** `nexus-prod`
* **Default StorageClass:** `oci-bv` (`blockvolume.csi.oraclecloud.com`, ext4, `WaitForFirstConsumer`, ReadWriteOnce only)
* **Networking Plane:** OCI VCN-Native Pod Networking, kube-proxy, CoreDNS.

---

## 🚀 Environment Initialization (Deploying the Broken Platform)

Apply all manifests to deploy the initial broken state:

```bash
kubectl apply -f manifests/
```

Inspect the initial broken state across the namespace:

```bash
kubectl get pods,svc,pvc,endpoints -n nexus-prod -o wide
```

---

## 📋 On-Call SRE Incident Board

Triage and remediate the incident tickets sequentially:

---

### [INC-701] Event Queue Volume Binding Failed — CSI StorageClass & AccessMode Rejection
* **Priority:** `P1 - Blocker`
* **Target Object:** `PersistentVolumeClaim/queue-data-pvc` & `StatefulSet/event-queue`
* **Alert:**
  > `[CRITICAL] PVC nexus-prod/queue-data-pvc stuck in Pending. Pod event-queue-0 cannot schedule due to unbound persistent volume.`
* **Symptoms:**
  The `event-queue-0` pod cannot be scheduled. `kubectl describe pod event-queue-0 -n nexus-prod` reports `pod has unbound immediate PersistentVolumeClaims`. Checking `kubectl describe pvc queue-data-pvc -n nexus-prod` reveals the PVC requested a non-existent StorageClass (`fast-nvme-storage`) and an unsupported access mode (`ReadWriteMany`). OCI Block Volume CSI only supports `ReadWriteOnce`.
* **Standard Verification:**
  * Inspect PVC events:
    ```bash
    kubectl describe pvc queue-data-pvc -n nexus-prod
    ```
  * Verify `queue-data-pvc` transitions to `Bound` and `event-queue-0` reaches `1/1 Running`:
    ```bash
    kubectl get pvc,pods -l app.kubernetes.io/name=event-queue -n nexus-prod
    ```
  * Verify Redis ping response:
    ```bash
    kubectl exec -n nexus-prod event-queue-0 -- redis-cli -a nexus-token-alpha-99x ping
    ```

---

### [INC-702] Dispatch Worker Pod Initialization Blocked — Secret Key Reference Typo
* **Priority:** `P1 - Blocker`
* **Target Object:** `Deployment/order-worker`
* **Alert:**
  > `[CRITICAL] Deployment nexus-prod/order-worker stuck in CreateContainerConfigError. Kubelet cannot inject environment variables.`
* **Symptoms:**
  `kubectl get pods -l app.kubernetes.io/name=order-worker -n nexus-prod` shows status `CreateContainerConfigError`. Describing the pod shows: `Error: secret "nexus-secrets" does not contain key "QUEUE_AUTH_KEY"`. The secret in `10-config.yaml` was created with key `QUEUE_AUTH_TOKEN`.
* **Standard Verification:**
  * Inspect the Kubelet error event:
    ```bash
    kubectl describe pod -l app.kubernetes.io/name=order-worker -n nexus-prod | grep -A 5 "Warning  Failed"
    ```
  * Inspect keys available in the secret:
    ```bash
    kubectl get secret nexus-secrets -n nexus-prod -o jsonpath='{.data}'
    ```
  * Update `manifests/50-worker.yaml` to reference `key: QUEUE_AUTH_TOKEN` and apply:
    ```bash
    kubectl apply -f manifests/50-worker.yaml
    ```

---

### [INC-703] Dispatch Worker InitContainer Infinite Loop — Dependency Hostname Typo
* **Priority:** `P1 - Blocker`
* **Target Object:** `Deployment/order-worker`
* **Alert:**
  > `[CRITICAL] Pod order-worker stuck in Init:0/1. InitContainer wait-for-database looping indefinitely.`
* **Symptoms:**
  After resolving INC-702, the pod remains in `Init:0/1`. Streaming logs via `kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c wait-for-database` reveals:
  `[INIT] Database unreachable at dispatch-database:5432, retrying in 2s...`
  The Kubernetes Service defined in `20-database.yaml` is named `dispatch-db`, but the init script attempts to reach `dispatch-database`.
* **Standard Verification:**
  * Check init container logs:
    ```bash
    kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c wait-for-database --tail=5
    ```
  * Verify active services in the namespace:
    ```bash
    kubectl get svc -n nexus-prod
    ```
  * Fix the hostname in `manifests/50-worker.yaml` to `dispatch-db` and verify the init container completes with exit code 0:
    ```bash
    kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c wait-for-database
    ```

---

### [INC-704] Dispatch Worker Cyclic Process Termination — Cgroup Memory Limit Starvation
* **Priority:** `P1 - Blocker`
* **Target Object:** `Deployment/order-worker`
* **Alert:**
  > `[CRITICAL] Container worker in pod order-worker terminates with exit code 137 (OOMKilled) immediately after startup.`
* **Symptoms:**
  The pod completes its init container, but the primary `worker` container crashes continuously in `CrashLoopBackOff`. `kubectl describe pod -l app.kubernetes.io/name=order-worker -n nexus-prod` indicates:
  `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`.
  The container allocates a 28MB dispatch batch buffer upon startup, but `resources.limits.memory` is set to `24Mi`.
* **Standard Verification:**
  * Confirm termination reason:
    ```bash
    kubectl get pod -l app.kubernetes.io/name=order-worker -n nexus-prod -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}'
    ```
  * Increase `limits.memory` to `128Mi` (and `requests.memory` to `64Mi`) in `manifests/50-worker.yaml` and reapply.
  * Verify the pod reaches `1/1 Running`:
    ```bash
    kubectl get pods -l app.kubernetes.io/name=order-worker -n nexus-prod
    ```

---

### [INC-705] In-Cluster Peer Discovery Access Denied — Missing RBAC ServiceAccount & RoleBinding
* **Priority:** `P2 - High`
* **Target Object:** `ServiceAccount`, `Role`, `RoleBinding` for `order-worker`
* **Alert:**
  > `[SECURITY ALERT] order-worker logging HTTP 403 Forbidden when discovering internal gateway endpoints via Kubernetes API.`
* **Symptoms:**
  Inspect the running worker logs:
  ```bash
  kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker
  ```
  The logs repeatedly report:
  `[SECURITY ALERT] In-cluster sync failed: HTTP 403 Forbidden - Access Denied on /api/v1/namespaces/nexus-prod/endpoints/dispatch-gateway`
  The pod runs under the `default` ServiceAccount, which has zero RBAC permissions to read `endpoints` in `nexus-prod`.
* **Standard Verification:**
  * Verify current permission evaluation:
    ```bash
    kubectl auth can-i get endpoints --as=system:serviceaccount:nexus-prod:default -n nexus-prod
    ```
  * Create a dedicated ServiceAccount (`nexus-worker-sa`), a Role granting `get, list` on `endpoints`, a RoleBinding, and configure `serviceAccountName: nexus-worker-sa` on `order-worker`.
  * Verify authorization passes:
    ```bash
    kubectl auth can-i get endpoints --as=system:serviceaccount:nexus-prod:nexus-worker-sa -n nexus-prod
    ```
  * Verify worker logs confirm successful sync:
    ```bash
    kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker | grep "HTTP 200 OK"
    ```

---

### [INC-706] Public Dispatch Gateway Has Zero Endpoints — LoadBalancer Service Selector Drift
* **Priority:** `P1 - Blocker`
* **Target Object:** `Service/dispatch-gateway`
* **Alert:**
  > `[CRITICAL] Service nexus-prod/dispatch-gateway has 0 active endpoints. External and internal HTTP traffic cannot reach the gateway.`
* **Symptoms:**
  The `dispatch-gateway` deployment is `1/1 Running`. However, checking the service:
  ```bash
  kubectl get endpoints dispatch-gateway -n nexus-prod
  ```
  shows `<none>`. `kubectl describe svc dispatch-gateway -n nexus-prod` shows selector `app.kubernetes.io/name=dispatch-gw`, while the Deployment pods are labeled `app.kubernetes.io/name=dispatch-gateway`.
* **Standard Verification:**
  * Compare service selector with pod labels:
    ```bash
    kubectl get svc dispatch-gateway -n nexus-prod -o jsonpath='{.spec.selector}'
    kubectl get pods -l app.kubernetes.io/name=dispatch-gateway -n nexus-prod --show-labels
    ```
  * Fix the selector in `manifests/60-gateway.yaml` to `app.kubernetes.io/name=dispatch-gateway` and apply.
  * Verify active endpoints:
    ```bash
    kubectl get endpoints dispatch-gateway -n nexus-prod
    ```

---

### [INC-707] Gateway Reverse Proxy Upstream Connection Failure — NGINX Hostname Resolution Mismatch
* **Priority:** `P1 - Blocker`
* **Target Object:** `ConfigMap/gateway-config` & `Deployment/dispatch-gateway`
* **Alert:**
  > `[CRITICAL] Public requests to dispatch-gateway /api/v1/routes return HTTP 502 Bad Gateway.`
* **Symptoms:**
  Testing the gateway health endpoint succeeds:
  ```bash
  kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/healthz
  ```
  However, testing the dispatch routing endpoint:
  ```bash
  kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -S -O- http://localhost:8080/api/v1/routes
  ```
  returns `HTTP/1.1 502 Bad Gateway`. Checking the NGINX error log:
  ```bash
  kubectl logs -l app.kubernetes.io/name=dispatch-gateway -n nexus-prod
  ```
  shows: `routing-api could not be resolved (3: Host not found)`. The upstream in `gateway-config` targets `routing-api:8080`, but the active service is `routing-engine`.
* **Standard Verification:**
  * Update upstream in `manifests/10-config.yaml` to `server routing-engine:8080;`.
  * Apply and rollout restart the gateway deployment:
    ```bash
    kubectl apply -f manifests/10-config.yaml
    kubectl rollout restart deployment/dispatch-gateway -n nexus-prod
    ```
  * Verify HTTP 200 OK and valid JSON routes:
    ```bash
    kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/api/v1/routes
    ```

---

### [INC-708] Routing Engine High Availability Scheduling Deadlock — Strict PodAntiAffinity on 2-Node Web Tier
* **Priority:** `P2 - High`
* **Target Object:** `Deployment/routing-engine`
* **Alert:**
  > `[WARNING] Deployment nexus-prod/routing-engine has 2/3 ready replicas. Replica 3 permanently stuck in Pending.`
* **Symptoms:**
  `kubectl get pods -l app.kubernetes.io/name=routing-engine -n nexus-prod` shows 2 pods `Running` and 1 pod `Pending`.
  Checking `kubectl describe pod ...`:
  `0/3 nodes are available: 1 node has untolerated taint (workload=database:NoSchedule), 2 nodes didn't match pod anti-affinity rules.`
  The deployment requests 3 replicas with hard anti-affinity (`requiredDuringSchedulingIgnoredDuringExecution`), but only 2 web nodes exist in the cluster.
* **Standard Verification:**
  * Inspect the scheduler failure event:
    ```bash
    kubectl describe pod -l app.kubernetes.io/name=routing-engine -n nexus-prod | grep -A 3 "didn't match pod anti-affinity"
    ```
  * Switch anti-affinity from `requiredDuringSchedulingIgnoredDuringExecution` to `preferredDuringSchedulingIgnoredDuringExecution` (soft anti-affinity) in `manifests/40-engine.yaml`.
  * Apply and confirm all 3 replicas reach `1/1 Running`:
    ```bash
    kubectl get deployment routing-engine -n nexus-prod
    ```

---

## ✅ Global Platform Health Verification

Once all 8 tickets are resolved, verify end-to-end platform stability:

```bash
# 1. Verify all pods are 1/1 Running with 0 restarts
kubectl get pods -n nexus-prod -o wide

# 2. Verify all services have valid, active endpoints
kubectl get endpoints -n nexus-prod

# 3. Test gateway healthcheck
kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/healthz

# 4. Test end-to-end dispatch route query through the gateway
kubectl exec -n nexus-prod deploy/dispatch-gateway -- wget -qO- http://localhost:8080/api/v1/routes

# 5. Confirm worker in-cluster peer discovery succeeds via RBAC
kubectl logs -l app.kubernetes.io/name=order-worker -n nexus-prod -c worker | tail -n 5
```

---

<br>

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# 🚨 SRE Olay Müdahale Laboratuvarı 7: NexusLogistics Otonom Sevkiyat Ağı Arıza Kurtarma

Bu çalışma alanı, **NexusLogistics Global** şirketinin kurumsal gerçek zamanlı yük rotalama, otonom filo çizelgeleme ve depo sevkiyat ızgarası platformunun canlıya geçiş (go-live) sırasında yaşadığı kritik kesintinin Olay Müdahale Kriz Odasıdır (War Room).

Tüm manifest dosyaları Kubernetes API sunucusu tarafından **şemaya uygun** olarak kabul edilmiş olup sözdizim hatası barındırmaz. Ancak depolama eklentisi erişim modu reddi, gizli anahtar (secret key) yazım hatası, bağımlılık servis adı çözümleme döngüsü, Linux cgroup bellek sınırı OOM kilitlenmesi, küme içi RBAC yetki engeli, bulut LoadBalancer seçici etiket sapması, NGINX ters vekil sunucu upstream uyuşmazlığı ve katı pod anti-affinity zamanlama kilitlenmesi platformu tamamen devre dışı bırakmıştır.

> 📖 **Kıdemli SRE Kök Neden Analizleri ve Çözüm Rehberi:**  
> 👉 **[Kapsamlı SRE Çözüm Rehberini İnceleyin (SOLUTION.md)](./SOLUTION.md)**

---

### 🗺️ Küme Topolojisi ve Altyapı Kısıtları

Olay senaryosu 3 node'lu OKE küme yapısı üzerinde kurgulanmıştır:

| Düğüm Adı | IP | Etiket | Kısıt / Taint | Tahsis Edilen Rol |
| :--- | :--- | :--- | :--- | :--- |
| **Node-1** | `10.0.10.122` | `tier=web` | *Yok* | Web / API / Gateway / Worker İş Yükleri |
| **Node-2** | `10.0.10.208` | `tier=web` | *Yok* | Web / API / Gateway / Worker İş Yükleri |
| **Node-3** | `10.0.10.78` | `tier=database` | `workload=database:NoSchedule` | Yalnızca Veritabanı İş Yükleri (İzole) |

* **Hedef Namespace:** `nexus-prod`
* **Varsayılan StorageClass:** `oci-bv` (Oracle Block Volume CSI, ext4, ReadWriteOnce)

---

### 🚀 Ortamın Başlatılması (Hatalı Platformun Dağıtımı)

```bash
kubectl apply -f manifests/
```

Kümedeki genel durumu gözlemleyin:
```bash
kubectl get pods,svc,pvc,endpoints -n nexus-prod -o wide
```

---

### 📋 SRE Olay Müdahale Panosu (8 Arıza Bileti)

1. **[INC-701] Event Queue Volume Bağlanamadı (PVC Pending):** `queue-data-pvc` tanımlamasında kümede bulunmayan `fast-nvme-storage` StorageClass'ı ve blok depolamanın desteklemediği `ReadWriteMany` modu seçilmiştir. `oci-bv` ve `ReadWriteOnce` olarak düzeltilmelidir.
2. **[INC-702] Worker Pod Başlatılamıyor (CreateContainerConfigError):** `order-worker` manifesti `nexus-secrets` içerisindeki `QUEUE_AUTH_TOKEN` yerine `QUEUE_AUTH_KEY` anahtarını aramaktadır.
3. **[INC-703] Worker InitContainer Sonsuz Döngüde (Init:0/1):** Init container `dispatch-database` adlı var olmayan bir hostu beklemektedir; doğru servis adı `dispatch-db` olarak güncellenmelidir.
4. **[INC-704] Worker Bellek Aşımı Kilitlenmesi (OOMKilled 137):** Python çalışma zamanı ve 28MB veri arabelleği için verilen `24Mi` bellek sınırı yetersiz kalmaktadır; sınır `128Mi` değerine çıkarılmalıdır.
5. **[INC-705] Küme İçi Servis Keşfi 403 Forbidden (RBAC Eksikliği):** Worker varsayılan `default` ServiceAccount ile Kubernetes API'sine erişmeye çalışmaktadır. `endpoints` okuma yetkisi olan özel bir ServiceAccount, Role ve RoleBinding oluşturulmalıdır.
6. **[INC-706] Gateway LoadBalancer Servisi 0 Endpoint (Seçici Sapması):** Servisin `spec.selector` alanında `app.kubernetes.io/name: dispatch-gw` yazarken podlarda `dispatch-gateway` etiketi bulunmaktadır.
7. **[INC-707] Gateway 502 Bad Gateway Veriyor (NGINX Upstream Hatası):** NGINX yapılandırmasındaki upstream tanımı `routing-api:8080` yerine aktif servis olan `routing-engine:8080` yapılmalıdır.
8. **[INC-708] Routing Engine Zamanlama Kilitlenmesi (Pending Pod):** 2 web sunucusu bulunan kümede 3 replika için katı (`required`) anti-affinity kuralı işletilmiştir; kural `preferred` olarak esnetilmelidir.
