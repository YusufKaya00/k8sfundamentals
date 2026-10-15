# 🇬🇧 English Version / Comprehensive SRE Post-Mortem & Incident Remediation Guide: Lab 10 (Chronos)

This document provides detailed Root Cause Analyses (RCA), Linux kernel and Kubernetes control plane mechanics, diagnostic triage commands, linear step-by-step remediation procedures, and enterprise SRE production best practices for the cascading outage in **Lab 10 (Chronos — `chronos-prod` namespace)**.

> [!NOTE]
> Lab 10 is built on a strictly linear, bottom-up dependency model. Upstream gateways and routing layers cannot be validated until downstream worker sockets and API deployments are stabilized. Follow the tickets sequentially.

---

## 📑 Incident Resolution Matrix

| Ticket | Component | Root Cause | Fix Strategy | Control Plane & Kernel Mechanics | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1001** | `inventory-worker` | Cgroup memory limit starvation (`40Mi`), triggering Linux OOM killer (`Exit Code 137`) | Memory limit: `40Mi` -> `192Mi` (request: `64Mi`) | Linux Kernel `oom-killer` & Kubelet cgroup manager | P1 - Blocker |
| **INC-1002** | `order-api` | Hard PodAntiAffinity across a 2-node web pool deadlocks 3rd replica (`Pending`) | `requiredDuringScheduling...` -> `preferredDuringScheduling...` | `kube-scheduler` (PodAntiAffinity Filter vs Score Plugin) | P1 - Blocker |
| **INC-1003** | `order-api` | `extraEnv` variable overrides ConfigMap value with invalid host, returning `503` | Remove conflicting `extraEnv` or point to `inventory-worker` | Kubelet Pod Lifecycle & Environment Precedence Engine | P1 - Blocker |
| **INC-1004** | `edge-lb` | 4A: `externalTrafficPolicy: Local` asymmetry<br/>4B: Service `targetPort: 8081` mismatch (`502` / timeout) | Policy: `Cluster`<br/>targetPort: `8080` | `kube-proxy` (iptables / IPVS NAT) & Endpoints Controller | P1 - Blocker |
| **INC-1005** | `edge-lb` | 5A: `X-Chronos-Gateway` header disabled (`403 Forbidden`)<br/>5B: ConfigMap changes require pod rollout restart | `gatewayHeader: "verified"` + `kubectl rollout restart deploy/edge-lb` | Application L7 Security Interceptor & Deployment Controller | P1 - Blocker |

---

## 🔧 Step-by-Step Incident Remediation

---

### [INC-1001] inventory-worker OOMKilled (Exit Code 137)

#### 1. 🧠 Diagnostic Mindset
- **Linux Kernel Cgroup Memory Limits & OOM Killer:**
  When `resources.limits.memory` is set, Kubelet configures a hard ceiling in the container's cgroup (`cgroup v2: memory.max`). When the process exceeds this ceiling, page allocation fails, and the Linux kernel's `oom_kill_process()` delivers `SIGKILL` (Signal 9) to the container.
- **Exit Code 137 Formula:**
  $$\text{Exit Code} = 128 + \text{Signal Number} = 128 + 9 = 137$$
  The container logs contain no Python stack trace because the kernel abruptly killed the process. Inspecting `kubectl describe pod` reveals `Reason: OOMKilled` and `Exit Code: 137`. The application allocates an 80MB bytearray at startup; the `40Mi` limit is severely starved.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Inspect pod status and restart count:
kubectl get pods -l app.kubernetes.io/name=inventory-worker -n chronos-prod -o wide
# Observation: CrashLoopBackOff, RESTARTS increasing.

# 2. Check termination state and memory limit:
kubectl describe pod -l app.kubernetes.io/name=inventory-worker -n chronos-prod | grep -E "Last State|Reason|Exit Code|Limits" -A 2
# Observation: Reason: OOMKilled, Exit Code: 137, Limits: memory: 40Mi

# 3. Confirm kernel OOM event:
kubectl get events -n chronos-prod --field-selector reason=OOMKilled
```

#### 3. 🛠️ Step-by-Step Resolution
1. Edit `manifests/20-inventory-worker.yaml`:
   - Increase memory request to `64Mi` and limit to `192Mi`:
```diff
           resources:
             requests:
               cpu: 50m
-             memory: 32Mi
+             memory: 64Mi
             limits:
               cpu: 200m
-             memory: 40Mi
+             memory: 192Mi
```

2. Apply manifest and verify recovery:
```bash
kubectl apply -f manifests/20-inventory-worker.yaml
kubectl rollout status deployment/inventory-worker -n chronos-prod --timeout=45s
kubectl get pods -l app.kubernetes.io/name=inventory-worker -n chronos-prod
# Expected: STATUS: Running, READY: 1/1
```

---

### [INC-1002] order-api Hard PodAntiAffinity Scheduling Deadlock (Pending Pod)

#### 1. 🧠 Diagnostic Mindset
- **Kube-Scheduler AntiAffinity Filtering:**
  `order-api` requests 3 replicas across 2 untainted web nodes. With `requiredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname`, Kube-Scheduler places 1 pod on Node-1 and 1 pod on Node-2. When attempting to place the 3rd pod, all candidate nodes are filtered out, leaving the pod indefinitely `Pending`.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check pod scheduling:
kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod -o wide
# Observation: 2 Running, 1 Pending

# 2. Check scheduler failure event:
kubectl describe pod -l app.kubernetes.io/name=order-api -n chronos-prod | grep -A 5 "FailedScheduling"
# Observation: 0/3 nodes are available: 2 node(s) had pod anti-affinity rules, 1 node(s) had untolerated taint.
```

#### 3. 🛠️ Step-by-Step Resolution
1. In `helm-values/order-api-prod.yaml`, relax anti-affinity from hard to soft:
```diff
 affinity:
   podAntiAffinity:
-    requiredDuringSchedulingIgnoredDuringExecution:
-      - labelSelector:
-          matchLabels:
-            app.kubernetes.io/name: order-api
-        topologyKey: "kubernetes.io/hostname"
+    preferredDuringSchedulingIgnoredDuringExecution:
+      - weight: 100
+        podAffinityTerm:
+          labelSelector:
+            matchLabels:
+              app.kubernetes.io/name: order-api
+          topologyKey: "kubernetes.io/hostname"
```

2. Upgrade Helm release:
```bash
helm upgrade order-api ./charts/order-api -f helm-values/order-api-prod.yaml -n chronos-prod
kubectl rollout status deployment/order-api -n chronos-prod
# Expected: All 3 replicas Running
```

---

### [INC-1003] order-api Upstream Dependency Routing Failure (HTTP 503)

#### 1. 🧠 Diagnostic Mindset
- **Environment Variable Precedence Trap:**
  In Kubernetes Pod specifications, environment variables declared in `env` (or Helm `extraEnv`) take precedence over variables imported via `envFrom: configMapRef`.
  A conflicting `INVENTORY_HOST: "invalid-worker"` in `extraEnv` overrides the valid ConfigMap hostname, causing backend calls to fail with HTTP 503.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Test ready endpoint:
kubectl exec -n chronos-prod deploy/order-api -c order-api -- curl -s http://127.0.0.1:8080/ready
# Observation: HTTP 503 ("inventory unreachable")

# 2. Check injected env var:
kubectl exec -n chronos-prod deploy/order-api -c order-api -- env | grep INVENTORY_HOST
# Observation: INVENTORY_HOST=invalid-worker
```

#### 3. 🛠️ Step-by-Step Resolution
1. In `helm-values/order-api-prod.yaml`, correct `extraEnv`:
```diff
 extraEnv:
-  - name: INVENTORY_HOST
-    value: "invalid-worker"
+  - name: INVENTORY_HOST
+    value: "inventory-worker"
```

2. Upgrade Helm release and verify:
```bash
helm upgrade order-api ./charts/order-api -f helm-values/order-api-prod.yaml -n chronos-prod
kubectl rollout status deployment/order-api -n chronos-prod
```

---

### [INC-1004] edge-lb Traffic Blackholing & TargetPort Mismatch

#### 1. 🧠 Diagnostic Mindset
- **Dual Network Misconfigurations:**
  1. `externalTrafficPolicy: Local` causes traffic hitting nodes without backend pods to be dropped.
  2. Service `targetPort: 8081` routes to an unused port, while `order-api` listens on port 8080.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Check Service configuration:
kubectl get svc order-api -n chronos-prod -o yaml | grep -E "targetPort|externalTrafficPolicy"
# Observation: targetPort: 8081, externalTrafficPolicy: Local
```

#### 3. 🛠️ Step-by-Step Resolution
1. In `charts/order-api/templates/service.yaml` or values:
   - Change `externalTrafficPolicy` to `Cluster`.
   - Update `targetPort` to `8080`:
```diff
   externalTrafficPolicy: Cluster
   ports:
     - port: 80
-      targetPort: 8081
+      targetPort: 8080
```

2. Upgrade Helm release:
```bash
helm upgrade order-api ./charts/order-api -f helm-values/order-api-prod.yaml -n chronos-prod
```

---

### [INC-1005] edge-lb Security Header & Silent ConfigMap Reload Failure

#### 1. 🧠 Diagnostic Mindset
- **L7 Header Interceptor & ConfigMap In-Memory Caching:**
  `edge-lb` NGINX reverse proxy enforces security header `X-Chronos-Gateway: verified`. In `edge-lb` values, the header is configured as `disabled`, resulting in `HTTP 403 Forbidden`. Furthermore, ConfigMaps mounted as files are cached by NGINX workers until a process reload or pod rollout restart is triggered.

#### 2. 🔍 Triage Commands (Gathering Evidence)
```bash
# 1. Test request through edge-lb:
curl -v http://<EDGE_LB_IP>/api/orders
# Observation: HTTP/1.1 403 Forbidden

# 2. Check NGINX configuration:
kubectl exec -n chronos-prod deploy/edge-lb -- cat /etc/nginx/nginx.conf | grep X-Chronos-Gateway
```

#### 3. 🛠️ Step-by-Step Resolution
1. In `helm-values/edge-lb-prod.yaml`, set `gatewayHeader: "verified"`.
2. Upgrade Helm release and restart deployment:
```bash
helm upgrade edge-lb ./charts/edge-lb -f helm-values/edge-lb-prod.yaml -n chronos-prod
kubectl rollout restart deployment/edge-lb -n chronos-prod
kubectl rollout status deployment/edge-lb -n chronos-prod
```

3. Confirm HTTP 200 OK:
```bash
curl -s http://<EDGE_LB_IP>/api/orders
# Expected: HTTP 200 OK with order payload
```

---

## 🏁 End-to-End Production Health Verification

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="chronos-prod"
echo "=== Validating Chronos End-to-End Platform Health ==="
kubectl get pods -n "${NS}"
LB_IP=$(kubectl get svc edge-lb -n "${NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -z "$LB_IP" ] && LB_IP=$(kubectl get svc edge-lb -n "${NS}" -o jsonpath='{.spec.clusterIP}')
curl -s "http://${LB_IP}/api/orders" | grep -q "order_id" && echo "✅ Chronos Gateway & Microservices Fully Healthy!"
```

---

# 🇹🇷 Türkçe Versiyon / Kapsamlı SRE Olay Müdahale Rehberi ve Post-Mortem: Lab 10 (Chronos)

Bu belge **Lab 10 (Chronos — `chronos-prod` namespace)** platform kesintisinin ayrıntılı kök neden analizlerini (Root Cause Analysis - RCA), Linux çekirdeği ve Kubernetes kontrol düzlemi seviyesindeki mekanizmalarını, teşhis komutlarını, doğrusal çözüm adımlarını ve kıdemli SRE pratiklerini içerir.

> [!NOTE]
> Lab 10 manifest ve Helm değer dosyaları (`charts/`, `helm-values/`, `manifests/`) bilerek hatalı yapılandırılmıştır. Sorunları aşağıdaki sırayla çözünüz. Doğrusal (bottom-up) mimaride alt katmandaki bir soket veya pod ayağa kalkmadan bir üst katmandaki sağlık kontrolleri ve servis yönlendirmeleri doğrulanamaz.

---

## 📑 Yönetici Özeti (Incident Matrix)

| Ticket | Bileşen | Kök Neden | Düzeltme | Kontrol Düzlemi & Çekirdek Bileşeni | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-1001** | `inventory-worker` | Yetersiz bellek limiti (`40Mi`), Linux cgroup OOM killer tetiklenmesi (`Exit Code 137`) | Memory limit: `40Mi` -> `192Mi` (request: `64Mi`) | Linux Kernel `oom-killer` & Kubelet cgroup manager | P1 - Blocker |
| **INC-1002** | `order-api` | 2 adet web node'u olan kümede 3 replica için Hard PodAntiAffinity tanımlanması (`Pending`) | `requiredDuringScheduling...` -> `preferredDuringScheduling...` | `kube-scheduler` (PodAntiAffinity Filter vs Score Plugin) | P1 - Blocker |
| **INC-1003** | `order-api` | `env` / `extraEnv` içindeki geçersiz `INVENTORY_HOST` tanımının `envFrom` ConfigMap değerini ezmesi (`503`) | Conflicting `extraEnv` kaldırılması veya `inventory-worker` yapılması | Kubelet Pod Lifecycle & Environment Precedence Engine | P1 - Blocker |
| **INC-1004** | `edge-lb` | 4A: `externalTrafficPolicy: Local` asimetrisi<br/>4B: Service `targetPort: 8081` uyuşmazlığı (`502` / timeout) | Policy: `Cluster`<br/>targetPort: `8080` | `kube-proxy` (iptables / IPVS NAT) & Endpoints Controller | P1 - Blocker |
| **INC-1005** | `edge-lb` | 5A: `X-Chronos-Gateway` başlığının "disabled" kalması (`403 Forbidden`)<br/>5B: Helm ConfigMap güncellemesinin pod'a yansımaması | `gatewayHeader: "verified"` + `kubectl rollout restart deploy/edge-lb` | Application L7 Security Interceptor & Deployment Controller | P1 - Blocker |

---

## 🔧 Ticket Bazında Çözümler

---

### [INC-1001 / INC-901] inventory-worker OOMKilled (Exit Code 137)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Linux Çekirdeği Cgroup Bellek Yönetimi ve OOM Katili:**
  Kubernetes'te bir konteynere `resources.limits.memory` atandığında, Kubelet ilgili cgroup düğümünde (`cgroup v1: memory.limit_in_bytes`, `cgroup v2: memory.max`) sert bir tavan belirler. Konteyner içerisindeki süreç (Go runtime, Python interpreter, JVM veya bellek içi veri yapısı) tahsis ettiği fiziksel belleği (Resident Set Size - RSS) artırdığında ve bu tavan aşıldığında sayfa tahsisi (page allocation) başarısız olur.
- Çekirdek seviyesindeki `oom_kill_process()` fonksiyonu tetiklenir. Çekirdek, cgroup sınırını aşan sürece yakalanamayan, yok sayılamayan veya ertelenemeyen `SIGKILL` (Sinyal 9) gönderir.
- **Exit Code 137 Matematiği:**
  Standart POSIX kabuklarında bir süreç sinyal alarak öldüğünde çıkış kodu $128 + \text{Sinyal Numarası}$ olarak hesaplanır. `SIGKILL` sinyali 9 olduğundan:
  $$128 + 9 = 137$$
  Kubernetes kontrol düzlemi `Exit Code: 137` ve `Reason: OOMKilled` bayrağı ile bu durumu doğrular.
- **Teşhis Zihniyeti:** SRE, "uygulamada kod hatası var" demeden önce loglara bakar. Konteyner loglarında hiçbir Python hata izi (stack trace) yoktur çünkü süreç kendi kendine çökmemiş, Linux Çekirdeği tarafından öldürülmüştür. `describe pod` çıktısındaki `Exit Code: 137` ve `Reason: OOMKilled` doğrudan bellek sınırına işaret eder. Python kodu başlangıçta 80MB boyutunda bir `bytearray` tahsis etmektedir; `40Mi` sınırı bunu karşılayamaz.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Pod'un durumunu ve yeniden başlatma (restart) sayısını inceleyin:
kubectl get pods -l app.kubernetes.io/name=inventory-worker -n chronos-prod -o wide
# Beklenen Çıktı:
# NAME                                READY   STATUS             RESTARTS      AGE
# inventory-worker-777899b99f-xxxxx   0/1     CrashLoopBackOff   4 (28s ago)   2m15s

# 2. Pod detayından konteynerin son durumunu (Last State) ve çıkış kodunu filtreleyin:
kubectl describe pod -l app.kubernetes.io/name=inventory-worker -n chronos-prod | grep -E "Last State|Reason|Exit Code|Limits" -A 2
# Beklenen Çıktı:
#     Last State:     Terminated
#       Reason:       OOMKilled
#       Exit Code:    137
#       Started:      Wed, 14 Oct 2026 15:00:10 +0300
#       Finished:     Wed, 14 Oct 2026 15:00:14 +0300
#     Limits:
#       cpu:     200m
#       memory:  40Mi

# 3. Çekirdek OOM olayını Kubernetes Event'leri üzerinden doğrulayın:
kubectl get events -n chronos-prod --field-selector reason=OOMKilled
# Beklenen Çıktı:
# Warning   OOMKilled   pod/inventory-worker-...   Memory cgroup out of memory: Killed process ...
```

#### 3. 🛠️ Adım Adım Çözüm
`inventory-worker` iş yükünün bellek sınırını `192Mi` seviyesine çıkarın ve `64Mi` istek (request) tanımlayın:

`manifests/20-inventory-worker.yaml` dosyasını düzenleyin:

```diff
          resources:
            requests:
              cpu: 50m
-             memory: 32Mi
+             memory: 64Mi
            limits:
              cpu: 200m
-             memory: 40Mi
+             memory: 192Mi
```

Değişikliği kümeye uygulayın ve doğrusal akış kontrolünü yapın:

```bash
# 1. Manifesti uygulayın
kubectl apply -f manifests/20-inventory-worker.yaml

# 2. Crash döngüsündeki pod'un yeni limitlerle Running durumuna geçmesini bekleyin
kubectl rollout status deployment/inventory-worker -n chronos-prod --timeout=45s

# 3. Pod'un 1/1 Ready ve 0 restart ile çalıştığını doğrulayın
kubectl get pods -l app.kubernetes.io/name=inventory-worker -n chronos-prod
# Beklenen: STATUS Running, READY 1/1

# 4. Katman 0 Doğrulaması: Worker'ın 9000 portunu dinlediğini test edin
kubectl exec -n chronos-prod deploy/inventory-worker -- nc -zv 127.0.0.1 9000
# Beklenen: 127.0.0.1 (9000) open

# 5. Service Endpoint'inin pod IP'sini aldığını doğrulayın
kubectl get endpoints inventory-worker -n chronos-prod
# Beklenen: <POD_IP>:9000
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar
- **Exit Code 137 vs 143 Farkı:**
  - `Exit Code 137` ($128 + 9$): `SIGKILL`. Sürece yakalama fırsatı verilmeden öldürüldü (OOMKilled veya `kubectl delete --force` veya `livenessProbe` başarısızlığında Kubelet öldürmesi).
  - `Exit Code 143` ($128 + 15$): `SIGTERM`. Sürece düzgün kapanma (graceful shutdown) sinyali gönderildi ve süreç normal kapandı.
- **Node Eviction vs Container OOM:** Eğer node'un kendi fiziksel belleği tükenirse, Kubelet `Eviction` başlatır ve pod'ları `Failed / Evicted` yapar. Ancak burada node belleği boştadır; sadece konteynerin kendisine çizilen cgroup sınırına çarpılmıştır.
- **Production Best Practice:** Kritik altyapı bileşenlerinde bellek limitleri rastgele atanmamalıdır. Vertical Pod Autoscaler (VPA) `Off` (Recommendation) modunda çalıştırılarak üretim yükü altındaki gerçek tepe (peak) bellek miktarı ölçülmeli ve limitler P99 değerinin en az %25-30 üzerine konumlandırılmalıdır.

---

### [INC-1002 / INC-902] order-api Hard PodAntiAffinity Kilitlenmesi (3 Replica / 2 Web Node)

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Kubernetes Scheduler PodAntiAffinity Filtreleme Mantığı:**
  Pod Anti-Affinity, pod'ların belirli etiketlere sahip diğer pod'larla aynı topoloji alanında (örneğin aynı fiziksel sunucu `kubernetes.io/hostname` veya aynı kullanılabilirlik alanı `topology.kubernetes.io/zone`) birlikte barındırılmasını engeller.
  İki temel türü vardır:
  1. **Hard (Zorunlu) Kural:** `requiredDuringSchedulingIgnoredDuringExecution`. Kube-Scheduler'ın filtreleme (PreFilter & Filter) aşamasında değerlendirilir. Eğer kuralı karşılayan boş bir topoloji düğümü yoksa scheduler pod'u kesinlikle hiçbir node'a atayamaz ve pod sonsuza kadar `Pending` kalır.
  2. **Soft (Tercih Edilen) Kural:** `preferredDuringSchedulingIgnoredDuringExecution`. Kube-Scheduler'ın puanlama (Score) aşamasında ağırlıklı puan verir. Mümkünse pod'ları ayrı node'lara dağıtır, ancak yeterli node yoksa mevcut node'lara yerleştirmeye izin verir.
- **Güvercin Yuvası İlkesi (Pigeonhole Principle):**
  Küme topolojisinde yalnızca 2 adet web düğümü (`Node-1` ve `Node-2`) bulunmaktadır. `Node-3` ise `workload=database:NoSchedule` taint'ine sahiptir.
  `order-api` Deployment'ı `replicas: 3` olarak istenmiş ve `topologyKey: kubernetes.io/hostname` üzerinde **hard** anti-affinity konulmuştur. 3 pod'u 2 node'a her node'da en fazla 1 pod olacak şekilde dağıtmak matematiksel olarak imkansızdır. İlk 2 pod Node-1 ve Node-2'ye yerleşir, 3. pod ise scheduler tarafından reddedilir.
- **Teşhis Zihniyeti:** SRE, kuralı tamamen silip yüksek erişilebilirlik (HA) hedefini çöpe atmak yerine; kuralı **hard** zorunluluktan **soft** önceliğe (`preferred`) çevirmelidir. Böylece normal şartlarda dağılım korunur, ancak kapasite kısıtında sistem kilitlenmez.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Deployment ve Pod durumlarını listeleyin:
kubectl get deployment order-api -n chronos-prod
# Beklenen: READY: 0/3, UP-TO-DATE: 3, AVAILABLE: 0

kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod -o wide
# Beklenen:
# order-api-xxx-1   Running   Node-1
# order-api-xxx-2   Running   Node-2
# order-api-xxx-3   Pending   <none>

# 2. Bekleyen (Pending) pod üzerindeki Scheduler hata olayını inceleyin:
PENDING_POD=$(kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod "$PENDING_POD" -n chronos-prod | grep -A 6 "Events:"
# Beklenen Çıktı:
# Warning  FailedScheduling  default-scheduler  0/3 nodes available: 1 node(s) had untolerated taint {workload: database}, 2 node(s) didn't match pod anti-affinity rules.

# 3. Helm değerleri dosyasını denetleyin:
cat helm-values/order-api-prod.yaml
```

#### 3. 🛠️ Adım Adım Çözüm
`helm-values/order-api-prod.yaml` dosyasındaki `affinity` bloğunu `required` yerine `preferred` yapısına dönüştürün:

```diff
   affinity:
     podAntiAffinity:
-      requiredDuringSchedulingIgnoredDuringExecution:
-        - labelSelector:
-            matchExpressions:
-              - key: app.kubernetes.io/name
-                operator: In
-                values:
-                  - order-api
-          topologyKey: "kubernetes.io/hostname"
+      preferredDuringSchedulingIgnoredDuringExecution:
+        - weight: 100
+          podAffinityTerm:
+            labelSelector:
+              matchExpressions:
+                - key: app.kubernetes.io/name
+                  operator: In
+                  values:
+                    - order-api
+            topologyKey: "kubernetes.io/hostname"
```

Helm güncellemesini gerçekleştirin ve tüm pod'ların atandığını doğrulayın:

```bash
# 1. Helm upgrade komutunu çalıştırın
helm upgrade order-api ./charts/order-api -f helm-values/order-api-prod.yaml -n chronos-prod

# 2. Deployment rollout sürecini izleyin
kubectl rollout status deployment/order-api -n chronos-prod --timeout=45s

# 3. 3 pod'un tamamının çizelgelendiğini doğrulayın
kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod -o wide
# Beklenen: 3 pod'un tümü Running durumunda (Node-1 ve Node-2 üzerinde paylaştırılmış)
```

> [!NOTE]
> Pod'lar çalışır (`Running`) duruma gelse de `READY` sütununda `0/1` olarak kalacaktır. Bu durum beklenen doğrusal akıştır ve bir sonraki bilet olan **INC-1003**'ün teşhis ortamını oluşturur.

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar
- **Hard Anti-Affinity & HPA Tuzağı:** Üretimde `hostname` seviyesinde `required` anti-affinity kullanmak, Yatay Pod Ölçekleyici (HPA) devreye girdiğinde felakete yol açar. HPA replica sayısını artırdığında, kümedeki node sayısı kadar pod açılabilir; sonraki tüm pod'lar `Pending` kalır ve eğer Cluster Autoscaler varsa her bir pod için gereksiz yeni sunucu provision edilerek bulut faturası patlar.
- **Ne Zaman Required Kullanılmalı?** `topologyKey: topology.kubernetes.io/zone` için `required` kullanılabilir (Multi-AZ yedekliliği). Ancak sunucu (`hostname`) bazında `required` yalnızca etcd, ZooKeeper, Consul veya Ceph Mon gibi tek sunucuda çift instance çalışmasının veri tutarlılığını veya quorum garantisini bozduğu durumlarla sınırlandırılmalıdır.

---

### [INC-1003 / INC-903] order-api Readiness Probe 503 & Ortam Değişkeni Öncelik Çakışması

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **Kubernetes `env` vs `envFrom` Öncelik Sıralaması:**
  Kubernetes Pod API spesifikasyonunda konteyner ortam değişkenleri iki farklı kaynaktan beslenebilir:
  1. `envFrom`: Bir ConfigMap veya Secret'taki tüm anahtar-değer çiftlerini toplu olarak içeri aktarır.
  2. `env`: Tekil olarak tanımlanan değişkenler (doğrudan değer veya `valueFrom`).
  **Kubernetes Çekirdek Kuralı:** Konteyner oluşturulurken önce `envFrom` blokları sırayla işlenir. Ardından `env` listesi işlenir. Eğer `env` listesinde tanımlanan bir değişkenin adı `envFrom` ile gelen bir değişkenle aynıysa, **`env` içindeki tanım `envFrom` içindeki tanımı ezer (overwrite/shadowing)**.
- **Kök Neden:**
  Helm şablonunda `order-api-config` ConfigMap'i `INVENTORY_HOST: "inventory-worker"` değerini doğru şekilde taşımaktadır. Ancak `helm-values/order-api-prod.yaml` dosyasında unutulan bir test parametresi (`extraEnv`) nedeniyle:
  ```yaml
  extraEnv:
    - name: INVENTORY_HOST
      value: "legacy-inventory-svc"
  ```
  tanımı doğrudan pod'un `env` bloğuna basılmıştır. Bu sebeple pod içindeki süreç `inventory-worker` yerine var olmayan `legacy-inventory-svc` adresine bağlanmaya çalışmaktadır.
- **Doğrusal Bağımlılık Zinciri:**
  `order-api` `/ready` sağlık probu, arkadaki `INVENTORY_HOST:9000` soketini kontrol eder:
  1. Eğer **INC-1001** çözülmemiş olsaydı, adres doğru olsa bile worker çöktüğü için prob yine 503 dönecekti.
  2. INC-1001 çözüldü ve worker ayakta; ancak yanlış host ezmesi nedeniyle istek Kubernetes DNS'i tarafından çözülemiyor (`NXDOMAIN` / `no such host`).
  Prob başarısız olduğu için Kubernetes `Endpoints Controller` pod IP'lerini servise bağlamaz ve trafik kara deliğe düşer.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Pod'ların 0/1 Ready kaldığını ve describe çıktısındaki 503 hatasını gözlemleyin:
kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod
# Beklenen: STATUS Running, READY 0/1

kubectl describe pod -l app.kubernetes.io/name=order-api -n chronos-prod | grep -A 4 "Readiness probe failed"
# Beklenen Çıktı:
# Warning  Unhealthy  ... kubelet  Readiness probe failed: HTTP probe failed with statuscode: 503

# 2. Pod içine girerek /ready endpoint'ini manuel çağırın:
kubectl exec -n chronos-prod deploy/order-api -c order-api -- wget -qO- http://localhost:8000/ready || true
# Beklenen Çıktı:
# {"status": "unavailable", "database": "connected", "inventory": "disconnected"}

# 3. Pod içindeki aktif çevre değişkenini ConfigMap ile karşılaştırın:
kubectl exec -n chronos-prod deploy/order-api -c order-api -- env | grep INVENTORY_HOST
# Çıktı: INVENTORY_HOST=legacy-inventory-svc

kubectl get cm -l app.kubernetes.io/name=order-api -n chronos-prod -o yaml | grep INVENTORY_HOST
# Çıktı: INVENTORY_HOST: "inventory-worker"

# 4. Service Endpoints havuzunun boş (<none>) olduğunu teyit edin:
kubectl get endpoints order-api -n chronos-prod
# Beklenen: ENDPOINTS: <none>
```

#### 3. 🛠️ Adım Adım Çözüm
`helm-values/order-api-prod.yaml` dosyasındaki çakışan `extraEnv` tanımını temizleyin veya kaldırın:

```diff
-extraEnv:
-  - name: INVENTORY_HOST
-    value: "legacy-inventory-svc"
+extraEnv: []
```

Helm güncellemesini yapın ve pod'ların sağlıklı duruma gelmesini doğrulayın:

```bash
# 1. Helm upgrade çalıştırın
helm upgrade order-api ./charts/order-api -f helm-values/order-api-prod.yaml -n chronos-prod

# 2. Pod'ların yeniden başlamasını ve readiness probunun geçmesini bekleyin
kubectl rollout status deployment/order-api -n chronos-prod --timeout=60s

# 3. 3 pod'un da 1/1 Ready olduğunu doğrulayın
kubectl get pods -l app.kubernetes.io/name=order-api -n chronos-prod
# Beklenen: 3/3 pod READY 1/1, STATUS Running

# 4. Endpoints listesinin 3 Pod IP'si ile dolduğunu doğrulayın
kubectl get endpoints order-api -n chronos-prod
# Beklenen: ENDPOINTS altında 8000 portunda 3 IP görünmeli

# 5. /ready yanıtını doğrudan test edin
kubectl exec -n chronos-prod deploy/order-api -c order-api -- wget -qO- http://localhost:8000/ready
# Beklenen Çıktı:
# {"status": "ready", "database": "connected", "inventory": "connected"}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar
- **Helm `extraEnv` Tuzakları:** Büyük kurumsal Helm chart'larında ortak `values.yaml` dosyaları ortam bazında (`values-dev.yaml`, `values-prod.yaml`) ezilir. Geliştiriciler test amacıyla `extraEnv` içine statik IP veya mock host adresi gömer ve bu değer Git'e girdiğinde prod ortamında ConfigMap'teki doğru değerleri sessizce ezer.
- **Liveness vs Readiness Probe Ayrımı:**
  Bu senaryoda harici servis bağımlılığı bilinçli olarak **Readiness Probe** içerisine yerleştirilmiştir. Eğer bu kontrol `Liveness Probe` içine konulsaydı, `inventory-worker` çöktüğünde tüm `order-api` pod'ları sürekli çökecek ve `CrashLoopBackOff` zincirleme felaketine (Cascading Failure) neden olacaktı. Readiness probe sayesinde pod'lar canlı tutuldu ancak trafiğe kapatıldı.

---

### [INC-1004 / INC-904] edge-lb Asimetrik Trafik Kaybı ve targetPort Uyuşmazlığı

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **`externalTrafficPolicy: Local` Asimetrisi ve Paket Düşürme:**
  Kubernetes servislerinde varsayılan dış trafik politikası `externalTrafficPolicy: Cluster`'dır. Bir istemci herhangi bir node'un NodePort IP'sine ulaştığında, yerel `kube-proxy` (iptables/IPVS) paketi kümedeki herhangi bir pod'a yönlendirir (SNAT yaparak geri dönüş yolunu garanti eder).
  Ancak `externalTrafficPolicy: Local` ayarlandığında:
  1. İstemcinin gerçek kaynak IP adresi korunur (`source IP preservation` - SNAT kapatılır).
  2. Kube-proxy, gelen trafiği **YALNIZCA** o sunucu üzerinde çalışan yerel bir pod endpoint'ine iletir.
  3. **Kritik Davranış:** Eğer gelen istek, üzerinde ilgili servise ait pod bulunmayan bir node'a ulaşırsa, kube-proxy paketi diğer node'lara yönlendirmez; **paketi sessizce düşürür (drop)** veya bağlantıyı zaman aşımına uğratır!
  4. Kümemizde `edge-lb` tek bir replica olarak çalışıyorsa (`replicaCount: 1`), diğer node'a gelen tüm istemci trafiği kara deliğe düşer.
- **Service `targetPort` Uyuşmazlığı (L4 vs L7):**
  İstek load balancer servisine ulaşsa bile, servis tanımında `targetPort: 8081` yazıyorsa:
  - Nginx konteyneri içeride 8080 portunu dinlemektedir.
  - Kube-proxy paketleri 8081 portuna ilettiğinde çekirdek bağlantıyı reddeder (`Connection refused`).

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. edge-lb servisinin konfigürasyonunu inceleyin:
kubectl get svc edge-lb -n chronos-prod -o yaml
# Gözlemlenen Hatalar:
# spec:
#   externalTrafficPolicy: Local
#   ports:
#   - port: 80
#     targetPort: 8081

# 2. Nginx konteynerinin hangi portu dinlediğini pod spec veya config üzerinden teyit edin:
kubectl get deployment edge-lb -n chronos-prod -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}'
# Çıktı: 8080 (Servis 8081'e yönlendiriyor, uyuşmazlık!)

# 3. Servis üzerinden doğrudan healthz çağrısı yapıp hatayı görün:
kubectl exec -n chronos-prod deploy/edge-lb -- wget -qO- http://localhost:8080/healthz
# Pod içinde 8080 çalışıyor (OK)
```

#### 3. 🛠️ Adım Adım Çözüm
`helm-values/edge-lb-prod.yaml` dosyasını açarak dış trafik politikasını `Cluster` olarak ayarlayın ve hedef portu `8080`'e çekin (veya replicaCount'u 2 yapın):

```diff
-replicaCount: 1
+replicaCount: 2

 service:
   type: LoadBalancer
   port: 80
-  targetPort: 8081
-  externalTrafficPolicy: Local
+  targetPort: 8080
+  externalTrafficPolicy: Cluster
```

Helm güncellemesini uygulayın ve servis ağını doğrulayın:

```bash
# 1. Helm upgrade çalıştırın
helm upgrade edge-lb ./charts/edge-lb -f helm-values/edge-lb-prod.yaml -n chronos-prod

# 2. Servis ayarlarını doğrulayın
kubectl get svc edge-lb -n chronos-prod
# Beklenen: PORT(S): 80:30xxx/TCP, EXTERNAL-TRAFFIC-POLICY: Cluster

# 3. Servis portu üzerinden healthz kontrolü yapın
kubectl exec -n chronos-prod deploy/edge-lb -- wget -qO- http://localhost:8080/healthz
# Beklenen: OK
```

> [!NOTE]
> Artık 502 Bad Gateway ve bağlantı zaman aşımları çözülmüştür. Ancak `/api/v1/orders` çağrısı yaptığınızda `HTTP 403 Forbidden` alacaksınız. Bu durum **INC-1005**'in beklenen zeminidir.

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar
- **Bulut Yük Dengeleyicilerinde `externalTrafficPolicy: Local` Davranışı:**
  AWS NLB veya OCI Network Load Balancer ile `externalTrafficPolicy: Local` kullanıldığında, bulut sağlayıcısı `healthCheckNodePort` üzerinden node'ları tarar ve üzerinde pod olmayan sunuculara trafik göndermez. Böylece istemci IP'si korunur ve paket kaybı yaşanmaz. Ancak bare-metal kümelerde, harici donanımsal yük dengeleyicilerde veya doğrudan NodePort erişiminde bu ayar ciddi paket kayıplarına neden olur.
- **Port Naming Standardizasyonu:** `targetPort` alanına sayısal port (`8080`) yazmak yerine pod spec'inde porta isim verilmesi (`name: http-web`) ve serviste `targetPort: http-web` kullanılması, port numarası değişikliklerinde servislerin kırılmasını önler.

---

### [INC-1005 / INC-905] edge-lb Gateway Header 403 Forbidden ve Helm ConfigMap Reload Tuzağı

#### 1. 🧠 Teşhis Zihniyeti (Diagnostic Mindset)
- **L7 Yetkilendirme (403 Forbidden) vs L4 İletişim Hatası (502/504):**
  - `502 / 504`: Ağ katmanı sorunudur; istek hedefe ulaşamaz veya hedef soket yanıt vermez.
  - `403 Forbidden`: Ağ katmanı kusursuz çalışmaktadır! İstek hedefteki `order-api` uygulamasına ulaşmış, uygulama isteği ayrıştırmış, ancak güvenlik ara yazılımı (Security Interceptor / Middleware) isteği bilinçli olarak reddetmiştir.
  - `order-api`, doğrudan pod IP'sine yapılan güvensiz çağrıları engellemek için tüm ingress isteklerinde `X-Chronos-Gateway: verified` başlığının bulunmasını şart koşar. `edge-lb` yapılandırmasında `gatewayHeader: "disabled"` verildiğinden uygulama 403 döner.
- **Helm & Kubernetes ConfigMap Yeniden Yükleme (Reload) Dinamiği:**
  - SRE `helm-values/edge-lb-prod.yaml` dosyasını düzeltip `gatewayHeader: "verified"` yapar ve `helm upgrade` komutunu çalıştırır.
  - Helm, Kubernetes etcd üzerindeki `ConfigMap` nesnesini başarıyla günceller.
  - **Fakat Sorun:** Kubernetes Deployment kontrolcüsü, pod şablonu (`spec.template`) değişmediği sürece mevcut çalışan pod'lara dokunmaz! Pod'un belleğindeki Nginx süreci eski konfigürasyonla çalışmaya devam eder.
  - Kubelet diskteki dosyayı güncellese bile Nginx'e reload sinyali gitmedikçe ya da pod yeniden başlatılmadıkça (`rollout restart`) süreç eski kuralları işletmeye devam eder.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Gateway üzerinden gelen isteğin 403 aldığını ve gövdedeki güvenlik uyarısını görün:
kubectl exec -n chronos-prod deploy/edge-lb -- wget -qO- http://localhost:8080/api/v1/orders || true
# Beklenen Çıktı:
# {"error": "untrusted proxy: missing X-Chronos-Gateway header"}

# 2. edge-lb konteyneri içindeki aktif Nginx konfigürasyonunu denetleyin:
kubectl exec -n chronos-prod deploy/edge-lb -- grep -i "X-Chronos-Gateway" /etc/nginx/nginx.conf
# Gözlem: proxy_set_header X-Chronos-Gateway "disabled";
```

#### 3. 🛠️ Adım Adım Çözüm
1. `helm-values/edge-lb-prod.yaml` dosyasında başlık değerini `verified` yapın:

```diff
 proxy:
-  gatewayHeader: "disabled"
+  gatewayHeader: "verified"
```

2. Helm yükseltmesini yapın ve kritik adım olan **`rollout restart`** komutunu vererek çalışan pod'ların yeni ConfigMap ile yeniden doğmasını sağlayın:

```bash
# 1. Helm release'i güncelleyin
helm upgrade edge-lb ./charts/edge-lb -f helm-values/edge-lb-prod.yaml -n chronos-prod

# 2. ConfigMap pod'lar tarafından belleğe alındığı için Deployment'ı yeniden başlatın
kubectl rollout restart deployment/edge-lb -n chronos-prod

# 3. Yeniden başlatma sürecinin tamamlanmasını bekleyin
kubectl rollout status deployment/edge-lb -n chronos-prod --timeout=30s

# 4. Yeni pod içindeki Nginx konfigürasyonunun başlığı içerdiğini doğrulayın
kubectl exec -n chronos-prod deploy/edge-lb -- grep -i "X-Chronos-Gateway" /etc/nginx/nginx.conf
# Beklenen: proxy_set_header X-Chronos-Gateway "verified";

# 5. Uçtan Uca Doğrulama: Sipariş işleme API'sinin 200 OK döndüğünü test edin
kubectl exec -n chronos-prod deploy/edge-lb -- wget -qO- http://localhost:8080/api/v1/orders
```

Beklenen Nihai Başarı Çıktısı:
```json
{
  "status": "success",
  "orders": [
    {
      "order_id": "ORD-7701",
      "customer": "chronos-client",
      "items": [
        {
          "sku": "CHRONO-SYNC",
          "quantity": 2,
          "price": 149.99
        }
      ],
      "total": 299.98,
      "status": "confirmed"
    }
  ]
}
```

#### 4. 💡 Sektör Deneyimi & Benzer Durumlar
- **"Helm Upgrade Yaptım Ama Değişmedi" Klasik SRE Krizi:**
  Helm dünyasındaki en yaygın operasyonel hatalardan biridir. ConfigMap güncellenir, fakat Deployment pod şablonu (`spec.template`) değişmediği için Kubernetes Deployment Controller hiçbir pod'u güncellemez.
- **En İyi SRE Çözümü (Config Checksum Annotation):**
  Helm chart'larında Deployment pod şablonuna her zaman şu anotasyon eklenmelidir:
  ```yaml
  spec:
    template:
      metadata:
        annotations:
          checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
  ```
  Bu sayede ConfigMap içeriğinde tek bir bayt bile değişse, sha256 özeti değişeceği için pod şablonu değişmiş sayılır ve Kubernetes otomatik olarak sıfır kesintili rolling update tetikler.
- **Alternatif:** Kümede `Stakater Reloader` gibi açık kaynaklı bir Kubernetes Controller kullanarak ConfigMap/Secret değişikliklerinin otomatik rollout tetiklemesi sağlanabilir.
- **Zero-Trust Ağ Geçidi Başlıkları:** Mikroservis mimarilerinde iç servislerin doğrudan çağrılmasını engellemek için Ingress katmanında paylaşılan doğrulanmış başlıklar (`X-Gateway-Secret`) veya mTLS kullanılması standart güvenlik en iyi uygulamasıdır.

---

## 🏁 Uçtan Uca Production Sağlık Kontrolü (Bottom-Up Checklist)

Tüm biletler çözüldükten sonra uçtan uca platform sağlığını tek bir betikle denetleyin:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="chronos-prod"

echo "=== 1. Checking Layer 0: Stateful Backends & Workers ==="
kubectl get pod state-db-0 -n $NS -o wide
kubectl exec -n $NS state-db-0 -- pg_isready -U chronos_admin -d chronos
kubectl exec -n $NS deploy/inventory-worker -- nc -zv 127.0.0.1 9000
kubectl get endpoints state-db inventory-worker -n $NS

echo "=== 2. Checking Layer 1 & 2: order-api Scheduling & Readiness ==="
kubectl get deployment order-api -n $NS
READY_REPLICAS=$(kubectl get deployment order-api -n $NS -o jsonpath='{.status.readyReplicas}')
if [ "$READY_REPLICAS" -ne 3 ]; then
  echo "[-] FAILURE: Expected 3 ready replicas, got ${READY_REPLICAS}"
  exit 1
fi
echo "[+] All 3 order-api pods are 1/1 Ready."
kubectl get endpoints order-api -n $NS
kubectl exec -n $NS deploy/order-api -c order-api -- wget -qO- http://localhost:8000/ready

echo "=== 3. Checking Layer 3 & 4: edge-lb Delivery & L7 Authorization ==="
kubectl get svc edge-lb -n $NS
kubectl exec -n $NS deploy/edge-lb -- wget -qO- http://localhost:8080/healthz
kubectl exec -n $NS deploy/edge-lb -- wget -qO- http://localhost:8080/api/v1/orders

echo "========================================================"
echo "  🎉 ALL CHRONOS SYSTEM AUDITS PASSED - PLATFORM OPERATIONAL"
echo "========================================================"
```
