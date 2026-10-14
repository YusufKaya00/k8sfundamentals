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
