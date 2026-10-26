# 🚀 Proje 3: Rancher Web Arayüzü (UI) ile RKE2 Kümesi & Multi-Tier Uygulama Kurulumu

Bu projede; Azure for Students (`6 vCPU` ve `3 Public IP`) kotalarına %100 uyumlu olarak **Terraform** ile 5 sunuculu altyapıyı, **Ansible** ile RKE2 + Local-Path Storage + Rancher Dashboard'u otomatik kuruyoruz. Ardından **Rancher Web Arayüzü (v2.9/v2.10)** üzerinden adım adım:
1. Düğümlere **Label** ve **Taint** basmayı,
2. **Project / Namespace** hiyerarşisini (yaratılan objelerin arayüzde kaybolmaması için),
3. **Helm Repository** (`bitnami`) ekleyip 3 ayrı veritabanını (`Redis`, `PostgreSQL`, `MongoDB`) kendi izole sunucularına dağıtmayı,
4. Web uygulamasını (`Deployment`, `Service`, `Ingress`) Rancher UI üzerinden kurup birbirine bağlamayı deneyimleyeceğiz.

---

## 📌 Mimari Genel Bakış

```
                        [ İnternet / DevOps Mühendisi ]
                                       │
        ┌──────────────────────────────┴──────────────────────────────┐
        ▼ (Port 443 HTTPS)                                           ▼ (Port 80 HTTP)
 🌐 <MASTER_PUBLIC_IP>                                        🌐 <APP_WORKER_PUBLIC_IP>
 ┌─────────────────────────────────────────┐                 ┌───────────────────────────┐
 │ vm-master (Standard_B2s_v2)             │                 │ vm-worker-app             │
 │ 2 vCPU / 8 GB RAM                       │                 │ 1 vCPU / 2 GB RAM         │
 │ • RKE2 Control Plane (API Server, etcd) │                 │ • tier=app (Taint YOK)    │
 │ • Rancher Dashboard Web UI              │                 │ • RKE2 NGINX Ingress      │
 │ • Local-Path Storage Provisioner        │                 │ • my-app (FastAPI Pod)    │
 └─────────────────────────────────────────┘                 └─────────────┬─────────────┘
                                                                           │ CoreDNS (data.svc.cluster.local)
                                                                           ▼
 ┌───────────────────────────────────────────────────────────────────────────────────────┐
 │ ÖZEL AĞDAKİ VERİ TABANI DÜĞÜMLERİ (Public IP YOK - NAT Gateway ile İnternete Çıkarlar)│
 │                                                                                       │
 │ ┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐ │
 │ │ vm-worker-infra         │  │ vm-worker-pg            │  │ vm-worker-mongo         │ │
 │ │ 1 vCPU / 2 GB RAM       │  │ 1 vCPU / 2 GB RAM       │  │ 1 vCPU / 2 GB RAM       │ │
 │ │ Label: tier=infra       │  │ Label: tier=db-sql      │  │ Label: tier=db-nosql    │ │
 │ │ Taint: dedicated=infra  │  │ Taint: dedicated=db-sql │  │ Taint: dedicated=db-nosql│
 │ │ • Redis Master Pod      │  │ • PostgreSQL Pod        │  │ • MongoDB Pod           │ │
 │ └─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘ │
 └───────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 ADIM 1: Altyapıyı Terraform ile Kurma

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/terraform
terraform init
terraform apply -auto-approve
```

Kurulum bittiğinde ekranda şu 3 çıktıyı not al:
* `master_public_ip`: Rancher erişim IP'si
* `app_worker_public_ip`: Web uygulaması Ingress IP'si (`app.<APP_WORKER_PUBLIC_IP>.nip.io`)
* `rancher_url`: `https://rancher.<MASTER_PUBLIC_IP>.nip.io`

---

## ⚙️ ADIM 2: Ansible ile RKE2, Local-Path Storage ve Rancher Kurulumu

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/ansible
ansible-playbook -i hosts.ini site.yml
```

> [!NOTE]
> **Playbook Neleri Otomatik Hazırlar?**
> 1. 5 sunucuda da Swap kapatılır ve kernel ağ ayarları yapılır.
> 2. `vm-master` üzerinde RKE2 Server ayağa kalkar ve `rke2-ingress-nginx-controller` Admission Webhook'un tam olarak hazır olması beklenir.
> 3. **Local-Path Provisioner (`local-path`)** varsayılan (`default`) `StorageClass` olarak kurulur ve tüm Taint'li worker düğümlerinde PVC klasörü açabilmesi için `helper-pod` toleration yaması otomatik uygulanır.
> 4. `cert-manager` ve **Rancher Dashboard** kurulur, 4 worker düğümü kümeye katılır.

---

## 🖥️ ADIM 3: Rancher Web Arayüzüne Giriş ve En Kritik Arayüz Kuralı!

1. Tarayıcıdan Terraform çıktısındaki `rancher_url` adresine git:  
   **`https://rancher.<MASTER_PUBLIC_IP>.nip.io`**
2. Güvenlik uyarısında **Gelişmiş -> İlerle** seçeneğine tıkla.
3. Giriş yap:
   * **Username:** `admin`
   * **Password:** `AdminPassword2026!`
4. **Sol menüden `local` kümesine tıkla.**

> [!IMPORTANT]
> **RANCHER ARAYÜZÜNDE "YARATTIĞIM ŞEY NEDEN GÖRÜNMÜYOR?" KURALI:**
> Rancher ekranının **en üst barında** (`local` küme adının hemen sağında) bir **Project/Namespace Filtre Kutusu** bulunur.
> * Eğer orada sadece `data` seçiliyse, `app` namespace'inde yarattığın **Deployment, Service veya Ingress ekranda GİZLENİR!**
> * Üstteki o filtre kutusuna tıklayıp her zaman **`All Namespaces`** (veya `Default Project`) seçili olduğundan emin ol!

---

## 📁 ADIM 4: `data` ve `app` Namespace'lerini Doğru Yerde (`Default` Project İçinde) Oluşturma

Rancher'da bir Namespace oluştururken onu bir **Project** içine koymazsan (`Not in a Project` kalırsa), Rancher menülerindeki açılır listelerde o Namespace görünmez! Doğru oluşturma yolu:

1. Sol menüden **Cluster -> Projects/Namespaces** sekmesine tıkla.
2. Sağ üstteki **Group by Project** görünümünde **`Project: Default`** satırını bul ve onun sağındaki **`Create Namespace`** butonuna tıkla:
   * **Name:** `data` -> **Create** butonuna bas.
3. Tekrar **`Project: Default`** satırının sağındaki **`Create Namespace`** butonuna tıkla:
   * **Name:** `app` -> **Create** butonuna bas.
4. Şimdi ekranın **en üst barındaki** Namespace filtresine tıkla ve **`All User Namespaces`** (veya hem `data` hem `app`) seçili hale getir!

---

## 🏷️ ADIM 5: Rancher UI Üzerinden Node Label ve Taint Verme

1. Sol menüden **Cluster -> Nodes** sekmesine tıkla (`5` sunucunun da `Active` olduğunu gör).
2. Her bir worker düğümünün en sağındaki **üç noktaya (`⋮`) -> Edit Config** diyerek sırayla şunları gir:

| Düğüm Adı | Labels Sekmesi (`Add Label`) | Taints Sekmesi (`Add Taint`) |
| :--- | :--- | :--- |
| **`vm-worker-infra`** | Key: `tier` / Value: `infra` | Key: `dedicated` / Value: `infra` / Effect: `NoSchedule` |
| **`vm-worker-pg`** | Key: `tier` / Value: `db-sql` | Key: `dedicated` / Value: `db-sql` / Effect: `NoSchedule` |
| **`vm-worker-mongo`** | Key: `tier` / Value: `db-nosql` | Key: `dedicated` / Value: `db-nosql` / Effect: `NoSchedule` |
| **`vm-worker-app`** | Key: `tier` / Value: `app` | **Taint EKLEME! (Boş bırak)** |

Her birinde **Save** butonuna basarak kaydet.

---

## 📦 ADIM 6: Bitnami Helm Reposunu Rancher UI'a Ekleme ve 3 Veritabanını Kurma

Rancher ilk kurulduğunda içinde Bitnami katalogları ekli değildir. Eklemek için:

1. Sol menüden **Apps -> Repositories** sekmesine tıkla -> Sağ üstten **Create** butonuna bas:
   * **Name:** `bitnami`
   * **Target:** `http(s) URL to an index generated by Helm`
   * **Index URL:** `https://charts.bitnami.com/bitnami`
   * **Create** butonuna bas ve durumunun yeşil **`Active`** olmasını bekle (10-15 sn).

### Şimdi 3 Veritabanını Kur (`Apps -> Charts`):

#### 1. Redis Kurulumu (`vm-worker-infra`):
* Sol menüden **Apps -> Charts**'a gir, arama kutusuna **`redis`** yaz ve **Redis (by Bitnami)** kartına tıkla -> **Install**.
* **Namespace:** `data` | **Name:** `redis` -> **Next** butonuna bas.
* Açılan YAML editöründeki her şeyi sil ve yerine aşağıdakini yapıştırıp **Install** de:
```yaml
architecture: standalone
auth:
  enabled: true
  password: "RedisStrongPassword123!"
master:
  nodeSelector:
    tier: infra
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "infra"
      effect: "NoSchedule"
  persistence:
    enabled: true
    size: 2Gi
```

#### 2. PostgreSQL Kurulumu (`vm-worker-pg`):
* **Apps -> Charts** ekranında **`postgresql`** ara -> **PostgreSQL (by Bitnami)** -> **Install**.
* **Namespace:** `data` | **Name:** `postgres` -> **Next** butonuna bas.
* YAML editörüne aşağıdakini yapıştırıp **Install** de:
```yaml
auth:
  postgresPassword: "PgStrongPassword123!"
  username: "appuser"
  password: "AppDbPassword123!"
  database: "appdb"
primary:
  nodeSelector:
    tier: db-sql
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "db-sql"
      effect: "NoSchedule"
  persistence:
    enabled: true
    size: 4Gi
```

#### 3. MongoDB Kurulumu (`vm-worker-mongo`):
* **Apps -> Charts** ekranında **`mongodb`** ara -> **MongoDB (by Bitnami)** -> **Install**.
* **Namespace:** `data` | **Name:** `mongodb` -> **Next** butonuna bas.
* YAML editörüne aşağıdakini yapıştırıp **Install** de:
```yaml
architecture: standalone
auth:
  rootPassword: "MongoRootPassword123!"
  usernames: ["appuser"]
  passwords: ["AppMongoPassword123!"]
  databases: ["appdb"]
nodeSelector:
  tier: db-nosql
tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "db-nosql"
    effect: "NoSchedule"
persistence:
  enabled: true
  size: 4Gi
```

> **Kontrol:** Sol menüden **Workloads -> Pods** ekranına gittiğinde `redis-master-0`, `postgres-postgresql-0` ve `mongodb-0` podlarının kendi sunucularında **`Running` (`1/1`)** olduğunu ve **Storage -> PersistentVolumeClaims** ekranında 3 PVC'nin de **`Bound`** olduğunu gör!

---

## 🌐 ADIM 7: Web Uygulamasını (`Deployment` + `Service` + `Ingress`) Rancher UI ile Kurma

Rancher UI'da Deployment oluştururken Service otomatik bağlanmayabilir veya Selector etiketleri karışabilir. Aşağıdaki **2 Yöntemden** istediğini kullanabilirsin:

### Yöntem A: Rancher UI Formlarından Adım Adım Oluşturma

#### 1. Deployment Oluştur (`Workloads -> Deployments -> Create`):
* **Namespace:** `app` | **Name:** `my-app`
* **Container Image:** `yusufk00/rke2-multi-app:v2` *(veya kendi imajın)*
* **Ports -> Add Port:**
  * **Service Type:** `Cluster IP` *(ÖNEMLİ: Varsayılan "Do not create a service" kalırsa Service yaratmaz! Mutlaka `Cluster IP` seç!)*
  * **Name:** `http`
  * **Private Container Port:** `8000`
  * **Listening Port:** `80`
* **Environment Variables -> Add Variable (10 Adet):**
  * `REDIS_HOST` = `redis-master.data.svc.cluster.local`
  * `REDIS_PASS` = `RedisStrongPassword123!`
  * `PG_HOST` = `postgres-postgresql.data.svc.cluster.local`
  * `PG_PASS` = `AppDbPassword123!`
  * `PG_USER` = `appuser`
  * `PG_DB` = `appdb`
  * `MONGO_HOST` = `mongodb.data.svc.cluster.local`
  * `MONGO_PASS` = `AppMongoPassword123!`
  * `MONGO_USER` = `appuser`
  * `MONGO_DB` = `appdb`
* Sol alt menüden (Pod seviyesindeki) **Node Scheduling** sekmesine tıkla:
  * **Node Selector -> Add Rule:** Key: `tier` | Value: `app`
* Sağ alttan **Create** butonuna bas!
  *(Artık hem `Workloads -> Deployments` altında `my-app`, hem de `Service Discovery -> Services` altında `my-app` servisi otomatik oluşur!)*

#### 2. Ingress Oluştur (`Service Discovery -> Ingresses -> Create`):
* **Namespace:** `app` | **Name:** `my-app-ingress`
* **Rules** sekmesinde:
  * **Request Host:** `app.<APP_WORKER_PUBLIC_IP>.nip.io` *(Örn: `app.9.205.159.29.nip.io`)*
  * **Path:** `Prefix` seç ve `/` yaz
  * **Target Service:** `my-app`
  * **Port:** `80` (veya `http`)
* Üstteki **Ingress Class** sekmesine tıkla:
  * **Ingress Class Name:** `nginx` seç! *(Bunu seçmezsen RKE2 Nginx Ingress isteği karşılamaz!)*
* Sağ alttan **Create** butonuna bas!

---

### Yöntem B: Rancher UI Sağ Üst `Import YAML` Butonu ile Tek Tıkta Kurma

Formlarda tek tek 10 tane Env Variable yazmak istemezsen:
1. Rancher ekranının en sağ üst köşesindeki **`Import YAML`** ikonuna (sayfa içine ok giren ikon) tıkla.
2. Aşağıdaki YAML'da `<APP_WORKER_PUBLIC_IP>` kısmına kendi App Worker IP'ni yazıp yapıştır ve **Import** de:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  namespace: app
  labels:
    app: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      nodeSelector:
        tier: app
      containers:
        - name: my-app
          image: yusufk00/rke2-multi-app:v2
          imagePullPolicy: Always
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          env:
            - name: REDIS_HOST
              value: "redis-master.data.svc.cluster.local"
            - name: REDIS_PASS
              value: "RedisStrongPassword123!"
            - name: PG_HOST
              value: "postgres-postgresql.data.svc.cluster.local"
            - name: PG_PASS
              value: "AppDbPassword123!"
            - name: PG_USER
              value: "appuser"
            - name: PG_DB
              value: "appdb"
            - name: MONGO_HOST
              value: "mongodb.data.svc.cluster.local"
            - name: MONGO_PASS
              value: "AppMongoPassword123!"
            - name: MONGO_USER
              value: "appuser"
            - name: MONGO_DB
              value: "appdb"
---
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: app
  labels:
    app: my-app
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - name: http
      port: 80
      targetPort: 8000
      protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: app
spec:
  ingressClassName: nginx
  rules:
    - host: app.<APP_WORKER_PUBLIC_IP>.nip.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

---

## ✅ ADIM 8: Canlı Doğrulama

Tarayıcıdan veya terminalden `http://app.<APP_WORKER_PUBLIC_IP>.nip.io/` adresine git:

```bash
curl -s http://app.<APP_WORKER_PUBLIC_IP>.nip.io/ | jq .
```

3 veritabanının da (`redis`, `postgresql`, `mongodb`) **`CONNECTED`** döndüğünü göreceksin!

---

## 🧹 ADIM 9: Temizlik

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/terraform
terraform destroy -auto-approve
```
