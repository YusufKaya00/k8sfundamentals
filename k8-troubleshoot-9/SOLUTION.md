# 🛠️ SRE Olay Müdahale Rehberi ve Post-Mortem: Lab 9 (PayStream)

Bu belge **Lab 9 (PayStream — `paystream-prod` namespace)** kesintisinin kök neden analizlerini (RCA), Kubernetes kontrol düzlemi seviyesindeki davranışlarını, teşhis komutlarını, doğrusal çözüm adımlarını ve kıdemli SRE pratiklerini içerir.

> [!NOTE]
> Manifest dosyaları (`manifests/`) bilerek hatalı yapılandırılmıştır. Sorunları aşağıdaki sırayla çözünüz. Bir önceki katman ayağa kalkmadan sonraki katmanın teşhis kanıtları doğrulanamaz.

---

## 📑 Yönetici Özeti (Incident Matrix)

| Ticket | Bileşen | Kök Neden | Düzeltme | Kontrol Düzlemi Bileşeni | Önem |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **INC-901** | `ledger-db` (Postgres) | 1A: Toleration eksikliği (`Pending`)<br/>1B: ext4 `lost+found` initdb engeli | Toleration: `workload=database:NoSchedule`<br/>`subPath: pgdata` veya `PGDATA` tanımı | `kube-scheduler` (TaintToleration) & `kubelet` volume mount | P1 |
| **INC-902** | `rate-limiter` (Redis) | 2A: Block volume'da `ReadWriteMany`<br/>2B: Service selector `redis-cache` | PVC accessMode: `ReadWriteOnce`<br/>Selector: `app.kubernetes.io/name: rate-limiter` | CSI Driver / PV Controller & Endpoints Controller | P1 |
| **INC-903** | `payment-api` (Bootstrap) | 3A: initContainer yanlış port (5433)<br/>3B: livenessProbe yanlış port (8080) | initContainer port -> 5432<br/>livenessProbe port -> 8000 | Kubelet Pod Lifecycle & Liveness Prober | P1 |
| **INC-904** | `payment-api` (Readiness) | ConfigMap `REDIS_PORT: 6380` -> Redis bağlantısı kopuk, 0/1 Ready | ConfigMap port -> 6379 & rollout restart | Kubelet Readiness Prober & Endpoints Controller | P1 |
| **INC-905** | `edge-gateway` (Nginx) | 5A: NetPol selector `ingress-gateway`<br/>5B: Nginx `proxy_pass` trailing slash | NetPol: `app.kubernetes.io/name: edge-gateway`<br/>`proxy_pass` sondaki `/` kaldırılması | CNI NetworkPolicy Engine & Nginx Reverse Proxy Core | P1 |

---

## 🔧 Ticket Bazında Çözümler

---

### [INC-901] ledger-db Pod Stuck in Pending & CrashLoopBackOff

#### 1. 🧠 Teşhis Zihniyeti
- **1A Hipotezi (Scheduling):** `ledger-db-0` pod'u `Pending` durumunda ve hiçbir node'a bağlanamıyor (`NODE: <none>`). Küme topolojisine bakıldığında veritabanı iş yükleri için ayrılmış olan Node-3'ün üzerinde `workload=database:NoSchedule` taint'i bulunmaktadır. StatefulSet içinde `nodeSelector: tier: database` tanımlı olduğu için scheduler yalnızca Node-3'ü aday olarak değerlendirir. Ancak pod spec'inde bu taint'i karşılayacak bir `tolerations` bloğu bulunmadığından `kube-scheduler`'ın `TaintToleration` filtresi pod'u reddeder.
- **1B Hipotezi (Volume Init):** Toleration eklenip pod Node-3'e atandığında hemen `CrashLoopBackOff`'a düşer. `oci-bv` (Oracle Block Volume CSI) yeni oluşturulan diski `ext4` dosya sistemiyle formatlar. ext4 dosya sisteminin kök dizininde dosya kurtarma amacıyla her zaman bir `lost+found` dizini bulunur. Postgres container imajı ise veri dizininin (`PGDATA`, varsayılan `/var/lib/postgresql/data`) kesinlikle tamamen boş olmasını şart koşar. Mount path doğrudan data dizini yapıldığında `initdb: directory "/var/lib/postgresql/data" exists but is not empty` hatası ile süreç `exit code 1` vererek çöker.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1A Kanıtı: Scheduler neden reddetti?
kubectl -n paystream-prod get pod ledger-db-0 -o wide
kubectl -n paystream-prod describe pod ledger-db-0 | grep -A 8 "Events:"
# Çıktı: 0/3 nodes available: 1 node(s) had untolerated taint {workload: database}, 2 node(s) didn't match Pod's node affinity/selector.

# Node taint ve etiketlerini kontrol etme:
kubectl get nodes -L tier -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# 1B Kanıtı: Toleration verildikten sonra pod neden çöküyor?
kubectl -n paystream-prod logs ledger-db-0 --previous
# Çıktı:
# initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
# It contains a lost+found directory, perhaps due to it being a mount point.
# Using a mount point directly as the data directory is not recommended.
# Create a subdirectory under the mount point.
```

#### 3. 🛠️ Adım Adım Çözüm
`k8-troubleshoot-9/manifests/10-ledger-db.yaml` dosyasında pod spec'ine toleration ve mount'a `subPath` eklenir:

```diff
     spec:
       nodeSelector:
         tier: database
+      tolerations:
+        - key: workload
+          operator: Equal
+          value: database
+          effect: NoSchedule
       containers:
         - name: postgres
           image: docker.io/library/postgres:16-alpine
+          env:
+            - name: PGDATA
+              value: /var/lib/postgresql/data/pgdata
           volumeMounts:
             - name: data
               mountPath: /var/lib/postgresql/data
+              subPath: pgdata
```

Uygulama ve doğrulama:
```bash
kubectl apply -f manifests/10-ledger-db.yaml

# StatefulSet Pending pod'u otomatik yeniden başlatmayabilir; pod'u silerek yeniden oluşmasını sağlayın:
kubectl -n paystream-prod delete pod ledger-db-0 --ignore-not-found

# Pod'un çalışmasını ve servisin endpoint almasını doğrulayın:
kubectl get pod ledger-db-0 -n paystream-prod -o wide
kubectl get endpoints ledger-db -n paystream-prod
kubectl exec -n paystream-prod ledger-db-0 -- pg_isready -U ledger_admin -d paystream
```

#### 4. 💡 Benzer Durumlarda Ne Olurdu? (Sektör Deneyimi)
- **Taint / Toleration Eşleşmeleri:** En sık yapılan hatalar `effect` alanının unutulması ya da yanlış yazılması (`NoExecute` vs `NoSchedule`), veya `operator: Exists` kullanılırken `value` alanının bırakılmasıdır.
- **ext4 vs xfs Mount Noktaları:** `ext4` dosya sisteminde her zaman `lost+found` oluşur. Veritabanı container'larında (Postgres, MySQL, MariaDB) kalıcı disk hiçbir zaman doğrudan veri köküne mount edilmemeli; mutlaka bir `subPath` (örneğin `subPath: pgdata` veya `subPath: data`) ya da `PGDATA` alt dizini kullanılmalıdır.
- **Önleme:** Admission controller (Kyverno veya Gatekeeper) politikası ile veritabanı storage mount'larında `subPath` zorunlu kılınabilir.

---

### [INC-902] rate-limiter Pod Pending & Service Unreachable

#### 1. 🧠 Teşhis Zihniyeti
- **2A Hipotezi (Storage Capability Mismatch):** `rate-limiter` pod'u `Pending` durumunda takılı kalmıştır. `describe pod` incelendiğinde pod'un `rate-limiter-pvc` PersistentVolumeClaim'inin bağlanmasını beklediği görülür. PVC incelendiğinde `accessModes: [ReadWriteMany]` istendiği görülür. Ancak `oci-bv` (Oracle Block Volume) bir blok depolama (Block Storage) CSI eklentisidir ve blok cihazlar donanımsal olarak çoklu node yazımını (`ReadWriteMany` / RWX) desteklemez; yalnızca `ReadWriteOnce` (RWO) sağlayabilir. CSI storage provisioner controller bu talebi karşılayamadığı için PVC sonsuza dek `Pending` kalır.
- **2B Hipotezi (Service Selector Mismatch):** PVC düzeltilip pod ayağa kalktığında bile diğer servisler Redis'e bağlanamaz. `kubectl get endpoints rate-limiter` komutu `<none>` döner. Servisin `spec.selector` alanında `app.kubernetes.io/name: redis-cache` yazılıdır, oysa Deployment pod template'indeki gerçek etiket `app.kubernetes.io/name: rate-limiter`'dır. Kubernetes Endpoints Controller etiket uyuşmazlığı nedeniyle pod'u servise bağlayamaz.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 2A Kanıtı: PVC neden Pending?
kubectl -n paystream-prod get pvc rate-limiter-pvc
kubectl -n paystream-prod describe pvc rate-limiter-pvc
# Çıktı: Events: ProvisioningFailed: ... accessMode ReadWriteMany is not supported by storage class oci-bv.

# 2B Kanıtı: Pod çalışıyor ama Endpoint neden boş?
kubectl -n paystream-prod get pod -l app.kubernetes.io/name=rate-limiter
# Pod çalışıyor (Running 1/1)

kubectl -n paystream-prod get endpoints rate-limiter
# Çıktı: ENDPOINTS: <none>

# Selector ve Pod etiketlerini karşılaştırın:
kubectl -n paystream-prod get svc rate-limiter -o jsonpath='{.spec.selector}'
# Çıktı: {"app.kubernetes.io/name":"redis-cache"}

kubectl -n paystream-prod get pods -n paystream-prod --show-labels
# Çıktı: app.kubernetes.io/name=rate-limiter
```

#### 3. 🛠️ Adım Adım Çözüm
1. PVC `accessModes` alanı Kubernetes API'sinde **değiştirilemez (immutable)** bir alandır. Bu yüzden mevcut PVC'yi silip `ReadWriteOnce` olarak yeniden oluşturmak gerekir.
2. `manifests/20-rate-limiter.yaml` dosyasında PVC modunu ve Service selector'ını düzeltin:

```diff
 apiVersion: v1
 kind: PersistentVolumeClaim
 metadata:
   name: rate-limiter-pvc
   namespace: paystream-prod
 spec:
   accessModes:
-    - ReadWriteMany
+    - ReadWriteOnce
   storageClassName: oci-bv
---
 apiVersion: v1
 kind: Service
 metadata:
   name: rate-limiter
   namespace: paystream-prod
 spec:
   type: ClusterIP
   selector:
-    app.kubernetes.io/name: redis-cache
+    app.kubernetes.io/name: rate-limiter
   ports:
     - name: redis
```

Uygulama ve doğrulama:
```bash
# Eski kilitli PVC'yi ve ilişkili bekleyen pod'u temizleyin:
kubectl -n paystream-prod delete pvc rate-limiter-pvc --force --grace-period=0
kubectl apply -f manifests/20-rate-limiter.yaml

# Deployment pod'unun bağlanmasını sağlayın:
kubectl -n paystream-prod rollout restart deploy/rate-limiter
kubectl -n paystream-prod rollout status deploy/rate-limiter

# Doğrulama:
kubectl get pvc rate-limiter-pvc -n paystream-prod
# Beklenen: Bound, RWO

kubectl get endpoints rate-limiter -n paystream-prod
# Beklenen: <POD_IP>:6379

kubectl exec -n paystream-prod deploy/rate-limiter -- redis-cli ping
# Beklenen: PONG
```

#### 4. 💡 Benzer Durumlarda Ne Olurdu? (Sektör Deneyimi)
- **RWO vs RWX Yanılgısı:** AWS EBS, GCP Persistent Disk, Azure Disk, OCI Block Volume gibi bulut blok cihazlarının tamamı `ReadWriteOnce` çalışır. RWX gerektiren iş yükleri (paylaşımlı dosya sistemleri) için NFS, CephFS, AWS EFS, GCP Filestore veya OCI File Storage (FSS) kullanılmalıdır.
- **Service Selector Silent Failure:** Servis selector hataları Kubernetes API tarafından sözdizimi hatası olarak kabul edilmez. API nesneyi başarıyla kaydeder, ancak arkasında hiçbir endpoint oluşmaz. CI/CD testlerinde servis dağıtıldıktan sonra `kubectl get endpoints <svc>` kontrolü yapmak bu hataları üretime çıkmadan yakalar.

---

### [INC-903] Payment API Initialization Failure & Pod CrashLoop

#### 1. 🧠 Teşhis Zihniyeti
- **3A Hipotezi (InitContainer Port Mismatch):** `payment-api` pod'ları `Init:0/1` durumunda takılır. Pod logları incelendiğinde `wait-for-db` init konteynerinin `until nc -zv ledger-db 5433; do sleep 2; done` komutunu çalıştırdığı görülür. Ancak PostgreSQL veritabanı 5432 portunda çalışmaktadır! Init konteyner 5433 portuna TCP bağlantısı kuramadığı için timeout'a düşer ve ana uygulama konteyneri hiç başlatılamaz.
- **3B Hipotezi (Liveness Probe Target Port Mismatch):** Init konteyner portu 5432 yapıldığında ana uygulama konteyneri başlar fakat 30 saniye sonra Kubelet tarafından öldürülür (`CrashLoopBackOff`, restarts sürekli artar). Kubelet pod event'lerinde `Liveness probe failed: connection refused` görülür. Pod spec incelendiğinde Python uygulamasının 8000 portunda dinleme yaptığı, ancak `livenessProbe`'un `port: 8080`'e istek attığı anlaşılır. Kubelet yanıt alamayınca konteyneri sonlandırır.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 3A Kanıtı: InitContainer neden takıldı?
kubectl -n paystream-prod get pods -l app.kubernetes.io/name=payment-api
# Çıktı: STATUS: Init:0/1

kubectl -n paystream-prod logs deploy/payment-api -c wait-for-db --tail=20
# Çıktı: nc: connect to ledger-db (10.96.x.y) port 5433 (tcp) failed: Connection refused

# 3B Kanıtı: Ana konteyner başladıktan sonra neden yeniden başlıyor?
kubectl -n paystream-prod describe pod -l app.kubernetes.io/name=payment-api | grep -E "Liveness|Restart Count|Events:" -A 10
# Çıktı:
# Warning  Unhealthy  ... kubelet  Liveness probe failed: Get "http://10.244.x.y:8080/health": dial tcp 10.244.x.y:8080: connect: connection refused
```

#### 3. 🛠️ Adım Adım Çözüm
`manifests/30-payment-api.yaml` dosyasında init konteyner komutundaki portu ve `livenessProbe` portunu düzeltin:

```diff
       initContainers:
         - name: wait-for-db
           image: docker.io/library/busybox:1.36
           command:
             - sh
             - -c
             - |
-              until nc -zv ledger-db 5433; do
+              until nc -zv ledger-db 5432; do
-                echo "Waiting for ledger-db on port 5433..."
+                echo "Waiting for ledger-db on port 5432..."
                 sleep 2
               done
       containers:
         - name: api
...
           livenessProbe:
             httpGet:
               path: /health
-              port: 8080
+              port: 8000
             initialDelaySeconds: 5
             periodSeconds: 10
```

Uygulama ve doğrulama:
```bash
kubectl apply -f manifests/30-payment-api.yaml
kubectl -n paystream-prod rollout status deploy/payment-api --timeout=60s

# Pod durumunu kontrol edin:
kubectl -n paystream-prod get pods -l app.kubernetes.io/name=payment-api
# Beklenen: STATUS Running, RESTARTS: 0 (artış durdu).
# NOT: Pod'un 0/1 READY kalması beklenen tasarımdır ve INC-904'ün kapısını aralar.
```

#### 4. 💡 Benzer Durumlarda Ne Olurdu? (Sektör Deneyimi)
- **InitContainer Kilitlenmeleri:** Init konteynerler başarıyla tamamlanmadan (`exit code 0`) ana pod asla ayağa kalkamaz. Üretim ortamında sonsuz döngülü `until nc ...` yerine maksimum deneme sayısı (timeout / retry limit) konulması ve metrik fırlatılması tavsiye edilir.
- **Liveness vs Readiness Probe Farkı:** Liveness probe'un görevi çöken/kilitlenen (deadlock) süreci yeniden başlatmaktır. Dış bağımlılıkların (veritabanı, redis) kontrolü ASLA liveness probe içine konulmamalıdır! Eğer liveness probe dış servisi kontrol ederse, veritabanı yavaşladığında kümedeki tüm API pod'ları aynı anda restart döngüsüne girerek durumu felakete çevirir (Cascading Failure).

---

### [INC-904] Payment API Readiness Probe Failure & Traffic Blackhole

#### 1. 🧠 Teşhis Zihniyeti
- **Hipotez:** Pod'lar `Running` durumundadır ve restart atmaz, ancak `0/1 Ready` kalırlar. Kubelet pod event'lerinde `Readiness probe failed: HTTP probe failed with statuscode: 503` hatası basılmaktadır.
- Uygulama kodundaki `/ready` endpoint'i incelendiğinde:
  - Veritabanı soket kontrolü (`DB_HOST:DB_PORT`) ve Redis soket kontrolü (`REDIS_HOST:REDIS_PORT`) yapılmaktadır. İki bağlantı da başarılı olursa HTTP 200, biri bile başarısız olursa HTTP 503 dönmektedir.
  - Pod çevre değişkenleri (`envFrom: configMapRef: payment-api-config`) incelendiğinde `REDIS_PORT: "6380"` olarak tanımlandığı görülür! Oysa INC-902'de ayağa kaldırılan Redis 6379 portunda çalışmaktadır.
  - Kubelet readiness probe başarısız olduğu için pod'u hazır kabul etmez ve `Endpoints Controller` pod IP'lerini `payment-api` servisinin endpoint havuzuna eklemez. Servis trafiği kara deliğe düşer.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 1. Readiness probe hatasını event'lerde görme:
kubectl -n paystream-prod describe pod -l app.kubernetes.io/name=payment-api | grep -A 5 "Readiness probe failed"

# 2. Pod içinden /ready endpoint'ini manuel çağırıp JSON yanıtını okuma:
kubectl exec -n paystream-prod deploy/payment-api -c api -- python -c "
import urllib.request, json
try:
    res = urllib.request.urlopen('http://localhost:8000/ready')
    print(res.read().decode())
except urllib.error.HTTPError as e:
    print(f'Status: {e.code}, Body: {e.read().decode()}')
"
# Çıktı: Status: 503, Body: {
#   "ready": false,
#   "database": {"host": "ledger-db", "port": 5432, "reachable": true, "detail": "connected"},
#   "cache": {"host": "rate-limiter", "port": 6380, "reachable": false, "detail": "[Errno 111] Connection refused"}
# }

# 3. ConfigMap içeriğini denetleme:
kubectl -n paystream-prod get configmap payment-api-config -o yaml | grep REDIS_PORT
# Çıktı: REDIS_PORT: "6380"

# 4. Servis endpoint durumunu inceleme:
kubectl -n paystream-prod get endpoints payment-api
# Çıktı: ENDPOINTS: <none>
```

#### 3. 🛠️ Adım Adım Çözüm
`manifests/30-payment-api.yaml` içindeki ConfigMap verisinde `REDIS_PORT`'u `6379` yapın:

```diff
 apiVersion: v1
 kind: ConfigMap
 metadata:
   name: payment-api-config
   namespace: paystream-prod
 data:
   DB_HOST: "ledger-db"
   DB_PORT: "5432"
   REDIS_HOST: "rate-limiter"
-  REDIS_PORT: "6380"
+  REDIS_PORT: "6379"
   PORT: "8000"
```

Uygulama ve ConfigMap değişikliğini çalışan pod'lara yansıtmak için rollout restart:
```bash
kubectl apply -f manifests/30-payment-api.yaml

# ConfigMap pod'lara env olarak verildiği için Deployment yeniden başlatılmalıdır:
kubectl -n paystream-prod rollout restart deploy/payment-api
kubectl -n paystream-prod rollout status deploy/payment-api

# Doğrulama:
kubectl -n paystream-prod get pods -l app.kubernetes.io/name=payment-api
# Beklenen: 2/2 pod READY 1/1, STATUS Running

kubectl -n paystream-prod get endpoints payment-api
# Beklenen: İki pod'un IP'si 8000 portunda kayıtlı olmalı (ör. 10.244.1.5:8000, 10.244.2.8:8000)
```

#### 4. 💡 Benzer Durumlarda Ne Olurdu? (Sektör Deneyimi)
- **ConfigMap Güncellemelerinin Pod'a Yansıması:** ConfigMap bir volume olarak mount edilmişse dosya güncellenir (kubelet senkronizasyon periyoduna bağlı olarak), ancak `env` veya `envFrom` ile aktarılan değişkenler konteyner sürecinin başlangıcında sabitlenir. Dolayısıyla env tabanlı ConfigMap değişikliklerinde mutlaka `kubectl rollout restart` yapılmalıdır.
- **Readiness Probe & Zero-Downtime:** Readiness probe bir pod'un trafiğe hazır olup olmadığını belirler. Hazır olmayan pod endpoint'ten çıkarılır ama öldürülmez. Bu sayede bağımlılık geçici olarak koptuğunda kullanıcıya 502/504 gitmesi engellenir.

---

### [INC-905] Edge Gateway Ingress Drop & API Route 404

#### 1. 🧠 Teşhis Zihniyeti
- **5A Hipotezi (NetworkPolicy Dropping Traffic):** `edge-gateway` üzerinden `/api/v1/settlements` çağrıldığında Nginx `504 Gateway Time-out` (veya timeout) döner. Nginx error log'unda `upstream timed out (110: Connection timed out) while connecting to upstream` görülür. Kümeye uygulanan `payment-api-netpol` (`NetworkPolicy`) incelendiğinde, Ingress kuralında yalnızca `podSelector: matchLabels: app.kubernetes.io/name: ingress-gateway` etiketine sahip pod'lara izin verildiği görülür. Ancak bizim gateway pod'umuzun etiketi `app.kubernetes.io/name: edge-gateway`'dir. CNI eklentisi (Calico/Cilium) gateway'den gelen tüm TCP syn paketlerini düşürür.
- **5B Hipotezi (Nginx Reverse Proxy Path Stripping):** NetworkPolicy düzeltildikten sonra gateway üzerinden tekrar istek atıldığında `HTTP 404 Not Found` (`{"error": "not_found"}`) döner.
  - Nginx config'i (`manifests/40-edge-gateway.yaml`) incelendiğinde:
    ```nginx
    location /api/v1/settlements {
        proxy_pass http://payment_api/; # Sondaki eğik çizgiye (trailing slash) dikkat!
    }
    ```
  - Nginx kurallarına göre `proxy_pass` yönergesinde URI kısmında bir yol (`/`) belirtilmişse, Nginx `location` ile eşleşen kısmı kırpar ve kalan kısmı iletir. İstek `/api/v1/settlements` olduğunda Nginx bu yolu tamamen silip upstream'e yalnızca `GET /` gönderir!
  - Upstream Python sunucusunda ise `/` rotası bulunmamakta, yalnızca `/api/v1/settlements` rotası işlenmektedir. Dolayısıyla sunucu 404 döner.
  - Sondaki slash (`/`) kaldırıldığında Nginx gelen yolu değiştirmeden (`GET /api/v1/settlements`) upstream'e iletir ve Python API `HTTP 200 OK` döner.

#### 2. 🔍 Teşhis Komutları (Kanıt Toplama)
```bash
# 5A Kanıtı: Gateway neden timeout alıyor?
kubectl exec -n paystream-prod deploy/edge-gateway -- wget -T 3 -qO- http://localhost:8080/api/v1/settlements
# Çıktı: wget: download timed out (veya 504 Gateway Time-out)

# Gateway pod'unun loglarını inceleme:
kubectl -n paystream-prod logs deploy/edge-gateway --tail=10
# Çıktı: [error] ... upstream timed out while connecting to upstream, upstream: "http://10.96.x.y:80/api/v1/settlements"

# NetworkPolicy etiket eşleşmesini denetleme:
kubectl -n paystream-prod get netpol payment-api-netpol -o yaml
# Çıktı: matchLabels: { app.kubernetes.io/name: ingress-gateway }

kubectl -n paystream-prod get pods -l app.kubernetes.io/name=edge-gateway --show-labels
# Çıktı: app.kubernetes.io/name=edge-gateway (UYUŞMAZLIK!)

# 5B Kanıtı: NetPol düzeltildikten sonra neden 404 dönüyor?
kubectl exec -n paystream-prod deploy/edge-gateway -- wget -qO- http://localhost:8080/api/v1/settlements
# Çıktı: {"error": "not_found"}

# Upstream payment-api loglarını inceleme:
kubectl -n paystream-prod logs -l app.kubernetes.io/name=payment-api -c api --tail=10
# Çıktı: "GET / HTTP/1.0" 404 -  (İstek /api/v1/settlements olarak gelmemiş, / olarak gelmiş!)
```

#### 3. 🛠️ Adım Adım Çözüm
1. `manifests/50-network-policy.yaml` içinde Ingress etiketini `edge-gateway` yapın:

```diff
   ingress:
     - from:
         - podSelector:
             matchLabels:
-              app.kubernetes.io/name: ingress-gateway
+              app.kubernetes.io/name: edge-gateway
       ports:
         - protocol: TCP
           port: 8000
```

2. `manifests/40-edge-gateway.yaml` içinde `proxy_pass` yönergesindeki sondaki `/` işaretini kaldırın:

```diff
             location /api/v1/settlements {
-                proxy_pass http://payment_api/;
+                proxy_pass http://payment_api;
                 proxy_connect_timeout 3s;
                 proxy_read_timeout 5s;
             }
```

Uygulama ve doğrulama:
```bash
kubectl apply -f manifests/50-network-policy.yaml
kubectl apply -f manifests/40-edge-gateway.yaml

# Nginx konfigürasyonunu yüklemek için gateway'i yeniden başlatın:
kubectl -n paystream-prod rollout restart deploy/edge-gateway
kubectl -n paystream-prod rollout status deploy/edge-gateway

# Nihai Uçtan Uca Doğrulama:
kubectl exec -n paystream-prod deploy/edge-gateway -- wget -qO- http://localhost:8080/api/v1/settlements
```

Beklenen çıktı:
```json
{
  "status": "success",
  "service": "payment-api",
  "settlement_engine": "active",
  "transactions_sample": [
    {
      "id": "tx_1001",
      "amount": 250.0,
      "currency": "USD",
      "state": "SETTLED"
    },
    {
      "id": "tx_1002",
      "amount": 149.99,
      "currency": "EUR",
      "state": "PROCESSING"
    },
    {
      "id": "tx_1003",
      "amount": 850.5,
      "currency": "USD",
      "state": "SETTLED"
    }
  ]
}
```

#### 4. 💡 Benzer Durumlarda Ne Olurdu? (Sektör Deneyimi)
- **Nginx Trailing Slash Tuzağı:** Nginx'te `proxy_pass http://upstream/;` ile `proxy_pass http://upstream;` arasındaki fark web mühendisliğinde en sık yaşanan yönlendirme hatalarındandır. Sondaki slash URI normalizasyonunu tetikler ve `location` bloğundaki prefix'i kırparak arkadaki servise sadece arta kalan yolu iletir.
- **NetworkPolicy Sessiz Engellemesi:** NetworkPolicy paketleri kernel seviyesinde (iptables / eBPF) sessizce düşürür (DROP). İstemci tarafında `Connection timed out` hatası oluşur. Bu tip durumlarda Cilium Hubble (`hubble observe --verdict DROPPED`) ya da Calico logları ile paket düşürmelerini doğrudan kernel seviyesinde izlemek teşhisi saniyelere indirir.

---

## 🏁 Uçtan Uca Production Sağlık Kontrolü (Bottom-Up Checklist)

Tüm adımlar tamamlandığında kümenin tam sağlığını tek bir betikle denetleyebilirsiniz:

```bash
#!/usr/bin/env bash
set -euo pipefail

NS="paystream-prod"

echo "=== 1. Checking Layer 0: Stateful Backends ==="
kubectl get pod ledger-db-0 -n $NS -o wide
kubectl exec -n $NS ledger-db-0 -- pg_isready -U ledger_admin -d paystream
kubectl exec -n $NS deploy/rate-limiter -- redis-cli ping
kubectl get endpoints ledger-db rate-limiter -n $NS

echo "=== 2. Checking Layer 1 & 2: Application Cluster ==="
kubectl get deploy payment-api -n $NS
kubectl get endpoints payment-api -n $NS
kubectl exec -n $NS deploy/payment-api -c api -- python -c "
import urllib.request, json
res = urllib.request.urlopen('http://localhost:8000/ready')
data = json.loads(res.read().decode())
assert data['ready'] is True, f'Readiness failed: {data}'
print('Payment API Readiness: OK')
"

echo "=== 3. Checking Layer 3: Edge Gateway & Settlement Output ==="
kubectl exec -n $NS deploy/edge-gateway -- wget -qO- http://localhost:8080/api/v1/settlements

echo "========================================================"
echo "  [SUCCESS] All PayStream SLAs satisfied. Incident Resolved!"
echo "========================================================"
```
