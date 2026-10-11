# ShopSphere Incident Triage — Kıdemli SRE Çözüm ve Kök Neden Analizi (RCA)

Bu doküman, `k8-troubleshoot-1` laboratuvarında karşılaşılan **11 adet gerçek dünya arıza senaryosunun (Production Incident Tickets)** derinlemesine kök neden analizini (Root Cause Analysis - RCA), teşhis komutlarını ve kesin çözümlerini içerir.

---

## Arıza Çözüm İndeksi

| Bilet No | Etkilenen Bileşen | Belirti / Hata Durumu | Kök Neden (Root Cause) |
|---|---|---|---|
| **Bilet #1** | `frontend-web` | Pod `Pending` (Schedule olamıyor) | Lokal kümede bulunmayan `eu-west-1a` zone etiketi `nodeSelector`'e yazılmış. |
| **Bilet #2** | `catalog-service` | `Endpoints: <none>` (503 Service Unavailable) | Servis selector'ünde podda bulunmayan `tier: backend` etiketi aranıyor. |
| **Bilet #3** | `catalog-api` | Pod `CrashLoopBackOff` & `CreateContainerConfigError` | Secret key adı `db_password` yazılmış (`database_password` olmalı) ve agresif livenessProbe podu açılırken öldürüyor. |
| **Bilet #4** | `order-service` | İstekler `Connection Refused` veriyor | Servis `targetPort: 80` yapılmış ama container port `8080` dinliyor. |
| **Bilet #5** | `postgres-pvc` | PVC `Pending` (PostgreSQL açılamıyor) | Bulut sınıfı `storageClassName: gp3` istenmiş; Minikube'de `standard` olmalı. |
| **Bilet #6** | `redis` | Cluster içi DNS `NXDOMAIN` veriyor | Headless Service adı `redis-service` iken StatefulSet'in `serviceName: redis` olması. |
| **Bilet #7** | `ecom-network-policy` | Backend DNS istekleri 30 sn'de timeout veriyor | NetworkPolicy egress kuralında CoreDNS'e (Port 53 UDP) izin verilmemiş. |
| **Bilet #8** | `catalog-hpa` | HPA `<unknown>/50%` gösteriyor, ölçeklemiyor | `catalog-api` podunda `resources.requests.cpu` tanımlanmamış. |
| **Bilet #9** | `node-log-collector` | DaemonSet master/control-plane node'unda çalışmıyor | `node-role.kubernetes.io/control-plane:NoSchedule` taint toleration'ı eksik. |
| **Bilet #10** | `ecom-auditor-pod` | K8s API'sine istek atarken `403 Forbidden` alıyor | Core API grubu `apiGroups: ["core"]` yazılmış (`[""]` olmalı) ve ClusterRoleBinding'de namespace eksik. |
| **Bilet #11** | `db-backup-cronjob` | CronJob çalışmıyor ya da boş `.sql` dosyası üretiyor | Quartz 6-alanlı cron sözdizimi, Kubelet'in `$(date)`'i boş string yapması ve -c parametre hatası. |

---

## Adım Adım Bilet Çözümleri

### Bilet #1: Frontend Podları `Pending` Durumunda Takılı

#### 1. Teşhis (Diagnosis)
```bash
# Pod durumunu kontrol edin
kubectl get pods -n ecom-prod -l app=frontend-web

# Scheduler olaylarını inceleyin
kubectl describe pod -n ecom-prod -l app=frontend-web
```
**Çıktı Belirtisi:**
`Warning FailedScheduling 0/1 nodes available: 1 node(s) didn't match Pod's node selector.`

#### 2. Kök Neden (RCA)
Manifest içindeki `spec.template.spec.nodeSelector` bloğunda `topology.kubernetes.io/zone: eu-west-1a` aranmaktadır. Ancak yerel kümeniz (Minikube / test node'u) AWS `eu-west-1a` etiketine sahip değildir.

#### 3. Çözüm
`manifests/03-frontend-and-security.yaml` içindeki `frontend-web` deployment'ında `nodeSelector` alanını kaldırın ya da `kubernetes.io/os: linux` yapın:
```yaml
nodeSelector:
  kubernetes.io/os: linux
```
```bash
kubectl apply -f solution/03-fixed-frontend-and-security.yaml
```

---

### Bilet #2: Catalog Servisi `Endpoints: <none>` Veriyor

#### 1. Teşhis (Diagnosis)
```bash
# Servis endpoint'lerini kontrol edin
kubectl get endpoints catalog-service -n ecom-prod

# Pod etiketleri ile Servis selector'ünü karşılaştırın
kubectl get svc catalog-service -n ecom-prod -o jsonpath='{.spec.selector}'
kubectl get pods -n ecom-prod -l app=catalog-api --show-labels
```
**Çıktı Belirtisi:**
`catalog-service   <none>   3m`  
Servis `app=catalog-api` VE `tier=backend` arıyor; ancak pod üzerinde yalnızca `app=catalog-api` etiketi var!

#### 2. Kök Neden (RCA)
Kubernetes Service selector mantığı **AND (Kesişim)** kuralıyla çalışır. Servise eklenen ve podda bulunmayan `tier: backend` etiketi yüzünden EndpointSlice controller hiçbir podu servise bağlamaz.

#### 3. Çözüm
`catalog-service` manifestindeki `selector` bloğundan `tier: backend` satırını silin:
```yaml
selector:
  app: catalog-api
```
```bash
kubectl apply -f solution/02-fixed-cache-and-backend.yaml
kubectl get endpoints catalog-service -n ecom-prod # Artık pod IP'leri görünür!
```

---

### Bilet #3: Catalog API `CreateContainerConfigError` ve `CrashLoopBackOff`

#### 1. Teşhis (Diagnosis)
```bash
kubectl get pods -n ecom-prod -l app=catalog-api
kubectl describe pod -n ecom-prod -l app=catalog-api
```
**Çıktı Belirtisi 1:**
`Error: couldn't find key db_password in ConfigMap default/ecom-secret`  
**Çıktı Belirtisi 2 (Key düzeltilirse):**
`Warning Unhealthy Liveness probe failed: HTTP probe failed with statuscode: 500`  
`Killing container catalog... Back-off restarting failed container`

#### 2. Kök Neden (RCA)
1. `ecom-secret` nesnesi içindeki key `database_password` olarak tanımlanmıştır; ancak pod `db_password` aramaktadır.
2. Servisin açılışı (`sleep 10` ile önbellek ısınması) 10 saniye sürmektedir; ancak `livenessProbe` 2. saniyede başlamakta ve 2 başarısızlıkta podu öldürmektedir. `startupProbe` koruması yoktur.

#### 3. Çözüm
1. Secret key adını `database_password` olarak düzeltin.
2. Yavaş açılan container'ı korumak için `startupProbe` ekleyin ve `livenessProbe`'u güvenli periyoda çekin:
```yaml
startupProbe:
  httpGet:
    path: /
    port: 8080
  failureThreshold: 20
  periodSeconds: 2
livenessProbe:
  httpGet:
    path: /
    port: 8080
  periodSeconds: 5
  failureThreshold: 3
```

---

### Bilet #4: Order Servisine İstekler `Connection Refused` Veriyor

#### 1. Teşhis (Diagnosis)
```bash
# Endpoints dolu mu?
kubectl get endpoints order-service -n ecom-prod
# 10.244.0.15:80 görünür (Hata burada gizlenir!)

# Küme içinden curl atın
kubectl run test-curl --rm -it --image=curlimages/curl -n ecom-prod -- curl -v http://order-service:80
```
**Çıktı Belirtisi:**
`curl: (7) Failed to connect to order-service port 80: Connection refused`

#### 2. Kök Neden (RCA)
`order-service` tanımında `port: 80` ve `targetPort: 80` yazılmıştır. Ancak pod içindeki Python/Go uygulaması **8080** portunu dinlemektedir. Servis gelen trafiği podun kapalı olan 80 portuna iletmekte ve Linux çekirdeği TCP RST (Connection Refused) dönmektedir.

#### 3. Çözüm
`order-service` tanımında `targetPort: 8080` yapın:
```yaml
ports:
  - port: 80
    targetPort: 8080
```

---

### Bilet #5: PostgreSQL Podu Başlamıyor (`postgres-pvc` Pending)

#### 1. Teşhis (Diagnosis)
```bash
kubectl get pvc -n ecom-prod
kubectl describe pvc postgres-pvc -n ecom-prod
```
**Çıktı Belirtisi:**
`Warning ProvisioningFailed storageclass.storage.k8s.io "gp3" not found`

#### 2. Kök Neden (RCA)
Manifest AWS'ye özgü `storageClassName: gp3` istemektedir. Ancak Minikube veya yerel k8s ortamında bu StorageClass yoktur (Minikube'de `standard` vardır).

#### 3. Çözüm
`postgres-pvc` içindeki `storageClassName: standard` yapın ya da satırı tamamen silerek varsayılan StorageClass'a bırakın:
```yaml
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
```
```bash
kubectl apply -f solution/01-fixed-storage-and-config.yaml
kubectl get pvc -n ecom-prod # Status: Bound olur!
```

---

### Bilet #6: Redis StatefulSet DNS Adı `NXDOMAIN` Veriyor

#### 1. Teşhis (Diagnosis)
```bash
# Redis podundan kendine DNS sorgusu atın:
kubectl exec -it redis-0 -n ecom-prod -- nslookup redis-0.redis-service.ecom-prod.svc.cluster.local
```
**Çıktı Belirtisi:**
`** server can't find redis-0.redis-service.ecom-prod.svc.cluster.local: NXDOMAIN`

#### 2. Kök Neden (RCA)
Kubernetes kuralı: StatefulSet podlarının bağımsız DNS (`pod-0.service-name`) kaydı alabilmesi için, StatefulSet'in `spec.serviceName` alanı ile Headless Service'in `metadata.name` alanı **birebir aynı** olmalıdır.  
Manifestte Service adı `redis-service` iken, StatefulSet'e `serviceName: redis` yazılmıştır!

#### 3. Çözüm
StatefulSet içinde `serviceName: "redis-service"` yapın:
```yaml
spec:
  serviceName: "redis-service"
```
```bash
kubectl apply -f solution/02-fixed-cache-and-backend.yaml
# Artık redis-0.redis-service IP adresini döner!
```

---

### Bilet #7: NetworkPolicy Yüzünden Dahili DNS Zaman Aşımına Uğruyor

#### 1. Teşhis (Diagnosis)
```bash
kubectl exec -it deploy/catalog-api -n ecom-prod -- nslookup postgres-service
```
**Çıktı Belirtisi:**
`connection timed out; no servers could be reached` (30 saniye bekler).

#### 2. Kök Neden (RCA)
`ecom-network-policy` podun `Egress` (çıkış) trafiğini kısıtlamıştır. Ancak CoreDNS'in çalıştığı `kube-system` namespace'indeki `53/UDP` portuna izin vermeyi unutmuştur. Linux resolver DNS cevabı alamadığı için kilitlenir.

#### 3. Çözüm
NetworkPolicy'nin `egress` kuralına CoreDNS portunu ekleyin:
```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
```

---

### Bilet #8: HPA `<unknown>/50%` Gösteriyor

#### 1. Teşhis (Diagnosis)
```bash
kubectl get hpa catalog-hpa -n ecom-prod
kubectl describe hpa catalog-hpa -n ecom-prod
```
**Çıktı Belirtisi:**
`Warning FailedGetResourceMetric missing request for cpu on container catalog in pod catalog-api-xxx`

#### 2. Kök Neden (RCA)
HPA yüzde hesabı yapabilmek için formüldeki paydaya (Denominator) ihtiyaç duyar:  
$\text{Yüzde} = \frac{\text{Anlık CPU Kullanımı}}{\text{İstenen CPU (Request)}} \times 100$  
Container tanımında sadece `limits` verilmiş, `requests.cpu` tanımlanmamıştır. Payda sıfır/nil olduğu için HPA yüzde hesaplayamaz.

#### 3. Çözüm
`catalog-api` container'ına `requests.cpu` tanımlayın:
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
```

---

### Bilet #9: DaemonSet Master / Control-Plane Node'unda Çalışmıyor

#### 1. Teşhis (Diagnosis)
```bash
kubectl get ds node-log-collector -n ecom-prod
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```
**Çıktı Belirtisi:**
Minikube tek node'lu olduğunda veya control-plane tainty olan sunucularda `DESIRED: 0` kalır.

#### 2. Kök Neden (RCA)
Kubernetes API server'ı DaemonSet podlarına standart node condition toleration'larını otomatik ekler; ancak `node-role.kubernetes.io/control-plane:NoSchedule` taint toleration'ını **otomatik eklemez**.

#### 3. Çözüm
DaemonSet pod şablonuna toleration ekleyin:
```yaml
tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
```

---

### Bilet #10: Güvenlik Denetçisi (Auditor Pod) `403 Forbidden` Alıyor

#### 1. Teşhis (Diagnosis)
```bash
kubectl logs ecom-auditor-pod -n ecom-prod
# Doğrudan yetkiyi test edin:
kubectl auth can-i list pods --as=system:serviceaccount:ecom-prod:ecom-auditor-sa -n ecom-prod
```
**Çıktı Belirtisi:**
`"error": "pods is forbidden: User system:serviceaccount:ecom-prod:ecom-auditor-sa cannot list resource pods in API group \"\""`

#### 2. Kök Neden (RCA)
1. ClusterRole içinde core kaynaklar için `apiGroups: ["core"]` yazılmıştır. Oysa Kubernetes'te temel kaynakların (pod, service, configmap) grubu **`""` (boş dizedir)**.
2. ClusterRoleBinding içindeki ServiceAccount tanımında `namespace: ecom-prod` yazılmamıştır. Küme bunu `default` namespace'i varsaymıştır.

#### 3. Çözüm
ClusterRole'de `apiGroups: [""]` yapın ve Binding'e `namespace: ecom-prod` ekleyin:
```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list"]
---
subjects:
  - kind: ServiceAccount
    name: ecom-auditor-sa
    namespace: ecom-prod
```

---

### Bilet #11: Yedekleme CronJob'ı Çalışmıyor / Boş Dosya Üretiyor

#### 1. Teşhis (Diagnosis)
```bash
kubectl get cronjob db-backup-cronjob -n ecom-prod
kubectl create job --from=cronjob/db-backup-cronjob test-run -n ecom-prod
kubectl logs job/test-run -n ecom-prod
```
**Çıktı Belirtisi:**
1. `schedule: "0 2 ? * * *"` ifadesi geçersiz 6-alanlı Quartz formatıdır (`?` K8s'te yoktur).
2. Kubelet `$(date +%F)` ifadesini ortam değişkeni sanıp boş dizeye dönüştürür.
3. `/bin/sh -c` sonrasına virgülle ayrı dizi elemanı yazıldığı için sadece birinci satır çalışır, yedek komutu hiç işletilmez.

#### 2. Kök Neden (RCA)
POSIX 5-alanlı cron standardı ihlal edilmiş ve container shell argümanları hatalı formatlanmıştır.

#### 3. Çözüm
Standard 5-alanlı `0 2 * * *` formatına geçin ve tek bir multiline bash scripti (`|`) kullanın:
```yaml
schedule: "0 2 * * *"
command:
  - /bin/sh
  - -c
  - |
    set -euo pipefail
    DATE_TAG=$(date +%Y-%m-%d)
    pg_dump -h postgres-service.ecom-prod.svc -U postgres ecom_db > "/tmp/backup-${DATE_TAG}.sql"
```
```bash
kubectl apply -f solution/04-fixed-ops-and-batch.yaml
```

---

## Tüm Ortamı Sıfırlama ve Doğrulama
Tüm düzeltmeleri tek seferde doğrulamak için:
```bash
kubectl apply -f solution/01-fixed-storage-and-config.yaml
kubectl apply -f solution/02-fixed-cache-and-backend.yaml
kubectl apply -f solution/03-fixed-frontend-and-security.yaml
kubectl apply -f solution/04-fixed-ops-and-batch.yaml
```
Tüm podların `Running 1/1` olduğunu ve servis endpoint'lerinin dolduğunu teyit edin:
```bash
kubectl get all -n ecom-prod
```
