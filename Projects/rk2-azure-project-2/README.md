# 🚀 RKE2 5-Node High-Isolation Enterprise Platform + Rancher Dashboard (Terraform & Ansible)

Bu proje, Azure üzerinde **5 sanal makineden (VM)** oluşan yüksek izolasyonlu ve üretime hazır (production-grade) bir **RKE2 Kubernetes** kümesini ve görsel yönetim arayüzü olan **Rancher Dashboard**'u **Terraform (IaC)** ve **Ansible (Configuration Management)** ile uçtan uca otomatikleştirir.

---

## 🏛️ Mimari ve Azure Öğrenci Kotası Planı

Azure for Students bölgesel **6 vCPU** kotasını aşmamak ve bellek açlığını önlemek için hibrit VM aileleri kullanılmıştır:

| Sunucu Adı | Rolü & İş Yükü | Azure Boyutu | vCPU / RAM | Aile | Public IP | Etiket & Taint Kalkanı |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`vm-master`** | Control Plane + etcd + Rancher | `Standard_B2s_v2` | 2 vCPU / 8 GB | `Bsv2` | Var | `CriticalAddonsOnly=true:NoSchedule` |
| **`vm-worker-infra`** | Redis (Oturum / Önbellek) | `Standard_B1ms` | 1 vCPU / 2 GB | `BS` | Var | `tier=infra` / `dedicated=infra:NoSchedule` |
| **`vm-worker-pg`** | PostgreSQL 18 (İlişkisel DB) | `Standard_B1ms` | 1 vCPU / 2 GB | `BS` | Var | `tier=db-sql` / `dedicated=db-sql:NoSchedule` |
| **`vm-worker-mongo`** | MongoDB (NoSQL Audit Log) | `Standard_B1ms` | 1 vCPU / 2 GB | `BS` | Var | `tier=db-nosql` / `dedicated=db-nosql:NoSchedule` |
| **`vm-worker-app`** | Traefik Ingress + Multi-App | `Standard_B1ms` | 1 vCPU / 2 GB | `BS` | Var | `tier=app` (Taint Yok) |

* **Toplam Bölgesel vCPU:** 6 / 6 (Kotaya %100 Uyumlu: 4 vCPU BS + 2 vCPU Bsv2).
* **Ağ (VNet):** `10.10.0.0/16` özel VNet ve `snet-nodes` (`10.10.1.0/24`) alt ağı.
* **Depolama (Storage):** Rancher Local-Path Provisioner (Varsayılan StorageClass).

---

## 📂 Proje Dizin Yapısı

```text
Projects/rk2-azure-project-2/
├── README.md                      # Bu doküman
├── terraform/                     # Azure Altyapı Otomasyonu
│   ├── main.tf                    # Resource Group, VNet, NSG, 5 VM ve SSH Key
│   ├── variables.tf               # Bölge, CIDR ve Kullanıcı değişkenleri
│   └── outputs.tf                 # Public IP'ler ve otomatik ansible/hosts.ini üretimi
├── ansible/                       # RKE2, Rancher ve İş Yükü Otomasyonu
│   ├── ansible.cfg                # SSH ve yetki yapılandırması
│   ├── hosts.ini                  # Terraform tarafından otomatik oluşturulur
│   ├── site.yml                   # Ana orkestrasyon playbook'u
│   └── playbooks/
│       ├── 01-common.yml          # Swap kapatma, kernel modülleri, sysctl
│       ├── 02-master.yml          # RKE2 Server kurulumu, token alma, kubeconfig
│       ├── 03-workers.yml         # 4 Worker'a RKE2 Agent kurulumu ve master'a bağlama
│       ├── 04-labels-storage.yml  # Node label & taint ayarları, Local-Path Storage, Helm
│       └── 05-rancher-workloads.yml # Cert-Manager, Rancher Dashboard, DB'ler ve App
├── helm-values/                   # Veritabanı Helm Değerleri
│   ├── redis-values.yaml
│   ├── postgres-values.yaml
│   └── mongo-values.yaml
└── my-app/                        # 3 Veritabanına Bağlanan FastAPI Uygulaması
    ├── Chart.yaml
    ├── values.yaml                # Traefik Ingress ve CoreDNS referansları
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        └── ingress.yaml
```

---

## 🚀 Adım Adım Kurulum ve Çalıştırma

### 1. Ön Koşullar
Yerel bilgisayarında `az cli`, `terraform` ve `ansible` kurulu olmalıdır:
```bash
az login
```

---

### 2. Aşama 1: Terraform ile Bulut Altyapısını Kurma

```bash
cd ~/k8sfundamentals/Projects/rk2-azure-project-2/terraform
terraform init
terraform apply -auto-approve
```

> **Otomasyon Notu:**  
> Terraform kurulum bittiğinde:
> 1. Güvenli bir SSH anahtar çifti (`id_rsa` ve `id_rsa.pub`) üretir.
> 2. Tüm VM'lerin Public ve Private IP'lerini alıp `../ansible/hosts.ini` dosyasını otomatik olarak doldurur!

---

### 3. Aşama 2: Ansible ile RKE2, Rancher ve Uygulamaları Dağıtma

Terraform tamamlandıktan sonra doğrudan Ansible dizinine geçip tek komutla tüm cluster'ı kur:

```bash
cd ../ansible
ansible-playbook site.yml
```

Bu playbook sırasıyla şunları gerçekleştirir:
1. **01-common:** 5 sunucunun tamamında Swap'ı kapatır, `overlay` ve `br_netfilter` modüllerini yükler.
2. **02-master:** `vm-master` üzerine RKE2 Server kurar, servisleri başlatır, `node-token`'ı çeker.
3. **03-workers:** 4 worker sunucusuna RKE2 Agent kurar ve token ile master'a bağlar.
4. **04-labels-storage:** Tüm sunucuların `Ready` olmasını bekler, Taint ve Label'ları basar, Local-Path StorageClass'ı ve Helm 3'ü kurar.
5. **05-rancher-workloads:**
   * `cert-manager` kurar (TLS sertifikaları için).
   * **Rancher Dashboard**'u kurar.
   * `data` namespace'i açıp Redis, PostgreSQL ve MongoDB'yi ilgili worker'lara dağıtır.
   * `app` namespace'i açıp `yusufk00/rke-multi-app:v1` uygulamasını Traefik Ingress ile canlıya alır!

---

## 🖥️ Erişim ve Zafer Doğrulaması

Kurulum bittiğinde Terraform çıktısındaki veya `hosts.ini` dosyasındaki `app_worker_public_ip` adresini kullanarak servisleri test edebilirsin:

### 1. Rancher Dashboard (Görsel Arayüz):
Tarayıcından şu adrese git:
```text
https://rancher.<APP_WORKER_PUBLIC_IP>.nip.io
```
* **Kullanıcı:** `admin`
* **Parola:** `AdminPassword2026!`
* *(İlk girişte kendinden imzalı sertifika uyarısını "Gelişmiş > Yine de devam et" diyerek geç).*  
Ekranda 5 Node'lu cluster'ını, tüm pod'ları, bellek/CPU grafiklerini ve canlı logları görsel olarak izleyebilirsin!

---

### 2. Canlı Multi-Tier Uygulama Testi:
Tarayıcından veya terminalden test et:
```bash
curl http://app.<APP_WORKER_PUBLIC_IP>.nip.io/
```

**Beklenen Çıktı:**
```json
{
  "platform": "RKE2 5-Node High-Isolation Enterprise Architecture",
  "app_node": "vm-worker-app",
  "services": {
    "redis": {
      "status": "CONNECTED (vm-worker-infra)",
      "visits": 1
    },
    "postgresql": {
      "status": "CONNECTED (vm-worker-pg)",
      "version": ["PostgreSQL", "18.6"]
    },
    "mongodb": {
      "status": "CONNECTED (vm-worker-mongo)",
      "total_logs": 1
    }
  }
}
```

---

## 💰 Maliyet Kontrolü (Kaynakları Durdurma ve Silme)

Öğrenci kredini korumak için pratik bittiğinde:

```bash
# 1. Veriler silinmesin ama saatlik vCPU/RAM faturası dursun (Deallocate):
az vm deallocate --ids $(az vm list -g rg-rke2-prod --query "[].id" -o tsv)

# 2. Çalışmaya tekrar devam etmek istediğinde:
az vm start --ids $(az vm list -g rg-rke2-prod --query "[].id" -o tsv)

# 3. Lab tamamen bittiğinde tüm ortamı kalıcı olarak silmek için:
cd ~/k8sfundamentals/Projects/rk2-azure-project-2/terraform
terraform destroy -auto-approve
```
