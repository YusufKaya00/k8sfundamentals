# 🚀 Proje 3: Rancher Web Arayüzü ile RKE2 Kümesi Yönetim Labı

Bu lab; Azure for Students ($100 kredi / 6 vCPU / 3 Public IP) kotalarına %100 uyumlu olarak, **Terraform** ile altyapı kurulduktan sonra **Kubernetes kümesini, düğümleri, etiketleri, izolasyon kurallarını (Taints) ve tüm iş yüklerini (Veritabanları + Multi-Tier Web App) Rancher Web Arayüzü üzerinden** adım adım kurup yönetmeni sağlayan kapsamlı bir görsel rehberdir.

---

## 📌 Mimari Genel Bakış ve Kotaya Uyum

```
                        [ İnternet / DevOps Mühendisi ]
                                       │
        ┌──────────────────────────────┴──────────────────────────────┐
        ▼ (Port 443 HTTPS)                                           ▼ (Port 80 HTTP)
 🌐 9.205.31.X (Master Public IP)                             🌐 9.205.31.Y (App Public IP)
 ┌─────────────────────────────────────────┐                 ┌───────────────────────────┐
 │ vm-master (Standard_B2s_v2)             │                 │ vm-worker-app             │
 │ 2 vCPU / 8 GB RAM                       │                 │ 1 vCPU / 2 GB RAM         │
 │ • RKE2 Control Plane (API Server, etcd) │                 │ • tier=app (Taint YOK)    │
 │ • Rancher Dashboard Web UI              │                 │ • RKE2 NGINX Ingress      │
 │ • Cert-Manager (TLS)                    │                 │ • my-app (FastAPI Pod)    │
 └─────────────────────────────────────────┘                 └─────────────┬─────────────┘
                                                                           │ CoreDNS (10.10.1.X)
                                                                           ▼
 ┌───────────────────────────────────────────────────────────────────────────────────────┐
 │ ÖZEL AĞDAKİ VERİ TABANI DÜĞÜMLERİ (Public IP YOK - NAT Gateway ile İnternete Çıkarlar)│
 │                                                                                       │
 │ ┌─────────────────────────┐  ┌─────────────────────────┐  ┌─────────────────────────┐ │
 │ │ vm-worker-infra         │  │ vm-worker-pg            │  │ vm-worker-mongo         │ │
 │ │ 1 vCPU / 2 GB RAM       │  │ 1 vCPU / 2 GB RAM       │  │ 1 vCPU / 2 GB RAM       │ │
 │ │ Taint: dedicated=infra  │  │ Taint: dedicated=db-sql │  │ Taint: dedicated=db-nosql│
 │ │ • Redis Master Pod      │  │ • PostgreSQL Pod        │  │ • MongoDB Pod           │ │
 │ └─────────────────────────┘  └─────────────────────────┘  └─────────────────────────┘ │
 └───────────────────────────────────────────────────────────────────────────────────────┘
```

### Neyi Neden Kullandık?
| Bileşen | Seçim | Nedeni |
|---|---|---|
| **Bulut VM Kotası** | `Standard_B2s_v2` (Master) + 4x `Standard_B1ms` (Workers) | Azure for Students toplam 6 vCPU kotasına tam uyar (2 + 4 = 6). |
| **Master Belleği** | 8 GB RAM | Rancher Dashboard zengin bir platformdur; 8 GB RAM ile çok rahat çalışır. |
| **IP Mimarisi** | 3 Public IP (Master, App, NAT Gateway) | Azure for Students bölge başına en fazla 3 IP verir; kota aşımı engellenir. |
| **SSH Anahtarı** | `~/.ssh/id_rsa.pub` (Sabit anahtar) | Geçici anahtar üretilmez; `Permission denied` veya `known_hosts` hatası yaşanmaz. |
| **Ingress Sınıfı** | `ingressClassName: nginx` | RKE2'nin gömülü kurumsal standardı Nginx'tir. |

---

## 🛠️ ADIM 1: Eski Labı Temizleme (Kota Açma)

Azure'daki 6 vCPU kotanı boşaltmak için önceki labı sil:

```bash
cd ~/k8sfundamentals/Projects/rk2-azure-project-2/terraform
terraform destroy -auto-approve
```

---

## 🚀 ADIM 2: Yeni Altyapıyı Terraform ile Kurma

Yeni proje dizinine git ve Terraform'u çalıştır:

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/terraform
terraform init
terraform apply -auto-approve
```

Kurulum bittiğinde ekranda şu çıktıları göreceksin:
* `master_public_ip`: Rancher erişim IP'si
* `app_worker_public_ip`: Web uygulaması Ingress IP'si
* `rancher_url`: `https://rancher.<MASTER_IP>.nip.io`

---

## ⚙️ ADIM 3: Ansible ile Ön Hazırlık ve Rancher'ı Başlatma

Ansible dizinine geç ve tek komutla sunucuları hazırlayıp Rancher'ı ayağa kaldır:

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/ansible
ansible-playbook site.yml
```

> **Bu playbook ne yapar?**
> 1. Tüm sunucularda Swap'ı kapatır, kernel ağ modüllerini açar.
> 2. `vm-master` üzerinde RKE2 Server, Cert-Manager ve Rancher Dashboard'u kurar.
> 3. 4 adet worker sunucusunu RKE2 kümesine bağlar.

---

## 🖥️ ADIM 4: Rancher Web Arayüzüne İlk Giriş

1. Tarayıcını aç ve Terraform çıktısındaki adrese git:  
   **`https://rancher.<MASTER_IP>.nip.io`**
2. Tarayıcı *"Bağlantınız gizli değil"* uyarısı verirse:  
   **Gelişmiş -> ... sitesine ilerle (güvensiz)** seçeneğine tıkla.
3. Giriş Bilgileri:
   * **Username:** `admin`
   * **Password:** `AdminPassword2026!`
4. Karşına gelen ekranda Server URL'in `https://rancher.<MASTER_IP>.nip.io` olduğunu onayla ve Dashboard'a gir!

---

## 🏷️ ADIM 5: Rancher UI Üzerinden Node Label ve Taint Verme

Artık terminale girmeden düğümlerimizi arayüzden etiketleyip izole edeceğiz:

1. Sol üstteki menüden **☰ -> Cluster Management** seçeneğine tıkla.
2. Açılan listede **`local`** kümesine tıkla ve üst menüden **Nodes** sekmesine gel.
3. 5 adet sunucunun da (`vm-master` ve 4 worker) `Active` olduğunu göreceksin.

### Düğümleri Sırayla Yapılandıralım:

#### 1. `vm-worker-infra` (Redis için):
* Sağdaki üç noktaya **(...)** tıkla -> **Edit Config** de.
* **Labels & Annotations** sekmesini aç:
  * Key: `tier`
  * Value: `infra`
* **Taints** sekmesini aç:
  * Key: `dedicated`
  * Value: `infra`
  * Effect: `NoSchedule`
* En alttan **Save** butonuna tıkla.

#### 2. `vm-worker-pg` (PostgreSQL için):
* Üç nokta -> **Edit Config**:
  * Label: Key=`tier`, Value=`db-sql`
  * Taint: Key=`dedicated`, Value=`db-sql`, Effect=`NoSchedule`
* **Save** de.

#### 3. `vm-worker-mongo` (MongoDB için):
* Üç nokta -> **Edit Config**:
  * Label: Key=`tier`, Value=`db-nosql`
  * Taint: Key=`dedicated`, Value=`db-nosql`, Effect=`NoSchedule`
* **Save** de.

#### 4. `vm-worker-app` (Web Uygulaması için):
* Üç nokta -> **Edit Config**:
  * Label: Key=`tier`, Value=`app`
  * **Taint EKLEME!** (Boş bırak ki uygulama ve genel Ingress rahatça yerleşsin).
* **Save** de.

---

## 💾 ADIM 6: Rancher UI ile StorageClass (Local-Path) Kurulumu

Veritabanlarının PVC disk alabilmesi için:

1. Sol menüden **Explore Cluster** (veya üstten `local` kümesini seç).
2. Sol menüde **Apps -> Charts** kısmına git.
3. Arama kutusuna `local-path` yaz veya **Storage -> Local Path Provisioner**'ı bul.
4. **Install** butonuna tıkla, namespace olarak `local-path-storage` seç ve varsayılan ayarlarla **Next -> Install** de.
5. Birkaç saniye içinde depolama sınıfı hazır hale gelir.


# 1. Resmi Local Path Provisioner manifestosunu küçüğe ve özelleştirmeye uygun olarak uygula
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

# 2. Master ve taints eklenmiş Worker sunucularında sorunsuz çalışması için tolerasyonları ekle
kubectl patch deployment local-path-provisioner -n local-path-storage --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/tolerations", "value": [{"operator": "Exists"}]}]'

kubectl patch configmap local-path-config -n local-path-storage --type merge -p '{
  "data": {
    "helperPod.yaml": "apiVersion: v1\nkind: Pod\nmetadata:\n  name: helper-pod\nspec:\n  tolerations:\n  - operator: Exists\n  containers:\n  - name: helper-pod\n    image: busybox\n    imagePullPolicy: IfNotPresent\n"
  }
}'

# 3. Varsayılan (Default) StorageClass olarak işaretle (Böylece PVC'ler otomatik bunu seçer)
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
---

🎯 Rancher UI'da Bitnami Chart'larını Getirme (30 Saniye)
Sol menüden Apps -> Repositories sekmesine tıkla.
Sağ üstteki Create butonuna bas.
Şu bilgileri gir:
Name: bitnami
Target: http(s) URL to an index generated by Helm (varsayılan seçili olan)
Index URL: https://charts.bitnami.com/bitnami
Sağ alttan Create butonuna bas.
Listede bitnami satırının durumunun yeşil Active olmasını bekle (yaklaşık 10-15 saniye sürer, katalog indeksini indirir).
## 🗄️ ADIM 7: Veritabanlarını Rancher UI ile Dağıtma

### Önce `data` Namespace'ini Aç:
1. Sol menüde **Projects/Namespaces** seçeneğine tıkla.
2. **Create Namespace** de:
   * Name: `data`
   * **Create** butonuna tıkla.

### Veritabanlarını Dağıtma:
Sol menüden **Apps -> Charts** seçeneğine gel ve Bitnami repolarından kur:

1. **Redis:**
   * Charts ekranında `redis` ara.
   * Namespace: `data`
   * Release Name: `redis`
   * Values sekmesinde `nodeSelector` kısmına `{ tier: infra }`, `tolerations` kısmına `dedicated=infra:NoSchedule` toleration'ını ekle (Hazır şablon `helm-values/redis-values.yaml` içindedir).
   * **Install** de.
2. **PostgreSQL:**
   * `postgresql` ara -> Namespace: `data` -> Release Name: `postgres`.
   * NodeSelector: `tier: db-sql`, Toleration: `dedicated=db-sql:NoSchedule`.
   * **Install** de.
3. **MongoDB:**
   * `mongodb` ara -> Namespace: `data` -> Release Name: `mongodb`.
   * NodeSelector: `tier: db-nosql`, Toleration: `dedicated=db-nosql:NoSchedule`.
   * **Install** de.

> [!TIP]
> **Hızlı Yol:** İstersen `helm-values/` klasöründeki dosyaların içeriğini Rancher UI'ın **Edit YAML** sekmesine doğrudan yapıştırabilirsin!

---

## 🌐 ADIM 8: Multi-Tier Uygulamayı (`my-app`) Rancher UI ile Kurma

1. **`app` Namespace'i Oluştur:**
   * Projects/Namespaces -> **Create Namespace** -> Name: `app` -> **Create**.
2. **Deployment Oluştur:**
   * Sol menüden **Workloads -> Deployments -> Create**:
     * **Name:** `my-app`
     * **Namespace:** `app`
     * **Container Image:** `yusufk00/rke-multi-app:v1`
   * **Node Scheduling Tab:**
     * `Node Selector` seç -> Key: `tier`, Value: `app`.
   * **Environment Variables Tab (CoreDNS DB Adresleri):**
     * `REDIS_HOST`: `redis-master.data.svc.cluster.local`
     * `REDIS_PASS`: `RedisStrongPassword123!`
     * `PG_HOST`: `postgres-postgresql.data.svc.cluster.local`
     * `PG_PASS`: `AppDbPassword123!`
     * `PG_USER`: `appuser`
     * `PG_DB`: `appdb`
     * `MONGO_HOST`: `mongodb.data.svc.cluster.local`
     * `MONGO_PASS`: `AppMongoPassword123!`
     * `MONGO_USER`: `appuser`
     * `MONGO_DB`: `appdb`
   * **Networking Tab:**
     * Port Name: `http`, Service Type: `ClusterIP`, Private Port: `8000`, Listening Port: `80`.
   * **Create** butonuna tıkla!
3. **Ingress Tanımla:**
   * Sol menüden **Service Discovery -> Ingresses -> Create**:
     * **Name:** `my-app-ingress`
     * **Namespace:** `app`
     * **Ingress Class:** `nginx`
     * **Rules:**
       * Request Host: `app.<APP_WORKER_PUBLIC_IP>.nip.io`
       * Path: `/`
       * Target Service: `my-app` (Port: 80)
     * **Create** butonuna bas!

---

## 🔍 ADIM 9: Rancher UI'ın Süper Güçlerini Keşfet

Uygulaman kurulduktan sonra Rancher arayüzünde şunları dene:

1. **Canlı Pod Logları:**
   * **Workloads -> Pods** sekmesine gel.
   * `my-app-...` pod'unun sağındaki üç noktaya bas -> **View Logs** de. Canlı log akışını tarayıcıdan izle.
2. **Tarayıcıdan Pod İçine Girme (Shell):**
   * Üç noktaya bas -> **Execute Shell** de. Pod'un içine tarayıcıdan Linux terminali gibi bağlan!
   * `env` veya `cat /etc/resolv.conf` çalıştır.
3. **Canlı Metrikler:**
   * **Cluster -> Dashboard** ekranında kümenin anlık CPU, RAM, Pod kapasitesi grafiklerini incele.

---

## ✅ ADIM 10: Canlı Doğrulama

Kendi yerel terminalinden web uygulamasını test et:

```bash
curl -s http://app.<APP_WORKER_PUBLIC_IP>.nip.io/
```

Beklenen çıktı:
```json
{
  "platform": "RKE2 5-Node High-Isolation Enterprise Architecture",
  "app_node": "vm-worker-app",
  "services": {
    "redis": { "status": "CONNECTED (vm-worker-infra)", "visits": 1 },
    "postgresql": { "status": "CONNECTED (vm-worker-pg)", "version": ["PostgreSQL", "18.6"] },
    "mongodb": { "status": "CONNECTED (vm-worker-mongo)", "total_logs": 1 }
  }
}
```

---

## 🧹 ADIM 11: Maliyet Kontrolü ve Temizlik

Lab ile işin bittiğinde Azure kredini korumak için:

```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/terraform
terraform destroy -auto-approve
```
