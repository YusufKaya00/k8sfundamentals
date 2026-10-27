# 🚀 Proje 4: OmniStream — Kurumsal DevSecOps, GitOps (ArgoCD), Event-Driven (Kafka + 3 DB), Rancher UI ve Gözlemlenebilirlik (Prometheus & Grafana) Platformu

Bu proje; gerçek dünyadaki kurumsal bir **Platform / DevSecOps Mühendisliği** mimarisinin uçtan uca tüm katmanlarını (**Terraform IaC**, **Ansible Konfigürasyon Yönetimi**, **RKE2 Kubernetes**, **Rancher UI**, **Apache Kafka (KRaft) + PostgreSQL + MongoDB + Redis**, **GitLab CI + Buildah + Trivy + Docker Hub**, **ArgoCD GitOps** ve **Prometheus + Grafana**) tek bir 5 sunuculu kümede birleştiren kapsamlı bir bitirme (capstone) projesidir.

> [!TIP]
> **Öğretici Kod Mimarisi:** Bu projedeki **tüm Terraform (`.tf`), Ansible (`.yml`), Helm (`values.yaml`), Uygulama (`app.py`, `Dockerfile`) ve CI/CD (`.gitlab-ci.yml`) dosyalarının içinde satır satır Türkçe mimari yorumlar** yer alır. Her bir parametrenin sektörde *neden* öyle yazıldığını dosyaları okurken doğrudan öğrenebilirsin.

---

## 🏛️ 1. Sistem Mimarisi ve 5-Node Donanım İzolasyonu

Azure for Students kısıtlarına (**`denmarkeast`** bölgesi, toplam **`6 vCPU`** ve maksimum **`3 Public IP`**) %100 uyumlu olacak şekilde, hiçbir sunucuda `OOMKilled` (`137`) veya `Insufficient cpu` yaşanmaması için iş yükleri **Taint & Toleration** ve **NodeSelector** kurallarıyla 5 sunucuya matematiksel olarak dağıtılmıştır:

```
                         [ İnternet / DevOps Mühendisi ]
                                        │
        ┌───────────────────────────────┴───────────────────────────────┐
        ▼ (Public IP #1: Master IP)                                     ▼ (Public IP #2: App IP)
 🌐 https://rancher.<MASTER_IP>.nip.io                           🌐 http://app.<APP_IP>.nip.io
 🌐 http://argocd.<MASTER_IP>.nip.io
 🌐 http://grafana.<MASTER_IP>.nip.io
 ┌─────────────────────────────────────────────┐                 ┌───────────────────────────────────┐
 │ vm-master (Standard_B2s_v2: 2 vCPU / 8 GB)  │                 │ vm-worker-app (1 vCPU / 2 GB RAM) │
 │ • IP: 10.20.1.4                             │                 │ • IP: 10.20.1.8                   │
 │ • Taint: CriticalAddonsOnly=true:NoSchedule │                 │ • Label: tier=app (Taint YOK)     │
 │ • RKE2 Control Plane & etcd                 │                 │ • OmniStream FastAPI App          │
 │ • Rancher UI (cattle-system)                │                 │ • GitLab Runner (CI Podları)      │
 │ • ArgoCD GitOps Engine (argocd)             │                 └─────────────────┬─────────────────┘
 │ • Prometheus & Grafana (monitoring)         │                                   │ CoreDNS
 └─────────────────────────────────────────────┘                                   ▼
 ┌───────────────────────────────────────────────────────────────────────────────────────────────────┐
 │ ÖZEL ALT AĞDAKİ VERİ & AKIŞ DÜĞÜMLERİ (Public IP YOK — NAT Gateway Public IP #3 ile İnternete Çıkar)│
 │                                                                                                   │
 │ ┌───────────────────────────────┐ ┌─────────────────────────────┐ ┌─────────────────────────────┐ │
 │ │ vm-worker-stream (2 GB RAM)   │ │ vm-worker-sql (2 GB RAM)    │ │ vm-worker-nosql (2 GB RAM)  │ │
 │ │ • IP: 10.20.1.5               │ │ • IP: 10.20.1.6             │ │ • IP: 10.20.1.7             │ │
 │ │ • Label: tier=stream          │ │ • Label: tier=db-sql        │ │ • Label: tier=db-nosql      │ │
 │ │ • Taint: dedicated=stream     │ │ • Taint: dedicated=db-sql   │ │ • Taint: dedicated=db-nosql │ │
 │ │ • Apache Kafka (KRaft Mode)   │ │ • PostgreSQL 16             │ │ • MongoDB 7                 │ │
 │ │ • Redis 7 (Standalone)        │ │   (transactions_ledger)     │ │   (audit_events)            │ │
 │ └───────────────────────────────┘ └─────────────────────────────┘ └─────────────────────────────┘ │
 └───────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 🧠 Neyi Neden Böyle Tasarladık? (Sektör & Mülakat Mantığı)

| Katman | Mimari Karar | Sektörde Neden Böyle Yapılır? |
| :--- | :--- | :--- |
| **Terraform Yapısı** | Tek bir `main.tf` yerine `versions.tf`, `variables.tf`, `network.tf`, `compute.tf`, `outputs.tf` | Üretim ortamlarında ekip içi çakışmaları (merge conflict) önlemek ve okunabilirliği artırmak için ağ, sunucu ve çıktılar ayrı dosyalara bölünür. |
| **Ağ Güvenliği (Zero Public IP DBs)** | Veritabanı ve Kafka düğümlerine Public IP verilmez; `NAT Gateway` kullanılır | Veritabanları asla internete doğrudan açılmaz. İmaj indirmek için dışarı çıkarken `NAT Gateway` (SNAT) kullanırlar, dışarıdan içeriye doğrudan bağlantı imkansızdır. |
| **SSH Bastion (`ProxyCommand`)** | Ansible özel ağdaki worker'lara `vm-master` üzerinden tünel kurarak girer | `hosts.ini.tftpl` içindeki `ProxyCommand="ssh -W %h:%p ..."` sayesinde tek bir komutla dış IP'si olmayan iç ağ sunucuları yönetilir. |
| **Linux Kernel (`sysctl`)** | `vm.max_map_count=262144` ve `fs.inotify.max_user_watches=524288` | **Apache Kafka** log segmentlerini belleğe `mmap` ile eşler, **Prometheus** ise binlerce zaman serisi dosyasını izler. Bu kernel ayarları yapılmazsa Kafka ve Prometheus yüksek yükte çöker. |
| **Apache Kafka (KRaft)** | ZooKeeper kapalı (`zookeeper.enabled: false`), **KRaft** açık | Kafka 3.x+ ile birlikte ZooKeeper emekliye ayrılmıştır. KRaft protokolü hem yarı yarıya RAM tasarrufu sağlar hem de mimariyi basitleştirir. |
| **Bitnami `resourcesPreset: "none"`** | Tüm Helm chart'larında preset kapatılıp özel `requests/limits` verildi | Bitnami chart'ları varsayılan olarak yüksek CPU (`500m-1000m`) ister. 1 vCPU'luk bulut düğümlerinde `Insufficient cpu` hatası almamak için `resourcesPreset: "none"` zorunludur. |
| **DevSecOps CI/CD** | Rootless `Buildah` -> `Trivy` -> `Docker Hub` -> GitOps `values.yaml` commit | Docker Daemon (`docker.sock`) güvenlik açığı yaratır; Kubernetes içinde **Buildah** ile root yetkisi olmadan imaj derlenir, **Trivy** ile taranır ve **ArgoCD** ile küme güncellenir. |

---

## 📂 2. Proje Dizin Yapısı

```text
Projects/devops-capstone-project-4/
├── README.md                                 # Bu kapsamlı mimari ve uygulama rehberi
├── .gitlab-ci.yml                            # 4 aşamalı DevSecOps hattı (Buildah -> Trivy -> DockerHub -> GitOps)
├── terraform/                                # Modüler Infrastructure-as-Code katmanı
│   ├── versions.tf                           # Terraform ve Azure/Local provider versiyon kilitleri
│   ├── variables.tf                          # Parametrik değişkenler ve kota açıklamaları
│   ├── network.tf                            # VNet, Subnet, NAT Gateway ve NSG güvenlik kuralları
│   ├── compute.tf                            # 1x Master (B2s_v2) + 4x Worker (B1ms - for_each ile)
│   ├── outputs.tf                            # Dinamik Ansible envanter üretimi ve erişim URL'leri
│   └── templates/
│       └── hosts.ini.tftpl                   # SSH Bastion (ProxyCommand) destekli envanter şablonu
├── ansible/                                  # Otomatik Kurulum ve Konfigürasyon Yönetimi
│   ├── ansible.cfg                           # SSH Pipelining ve ControlMaster hızlandırma ayarları
│   ├── site.yml                              # 5 playbook'u sırasıyla çalıştıran ana orkestratör
│   └── playbooks/
│       ├── 01-os-hardening.yml               # Swap kapatma, kernel modülleri ve Kafka/Prometheus sysctl ayarları
│       ├── 02-rke2-master.yml                # RKE2 Server, Ingress Webhook kilidi, Helm ve Local-Path CSI + Toleration
│       ├── 03-rke2-workers.yml               # Token okuma (slurp) ve 4 Worker'ın RKE2 Agent olarak katılımı
│       ├── 04-node-isolation.yml             # 5 sunucuya Label ve Taint basılması + Namespace hazırlığı
│       └── 05-platform-services.yml          # Rancher, ArgoCD, Prometheus/Grafana, Kafka, 3 DB ve App kurulumu
├── helm-values/                              # RAM/CPU ve Taint/Toleration ayarlı Helm Values dosyaları
│   ├── rancher-values.yaml                   # vm-master (8 GB RAM) üzerine sabitlenmiş Rancher UI
│   ├── argocd-values.yaml                    # vm-master üzerine sabitlenmiş ArgoCD + NGINX Ingress
│   ├── monitoring-values.yaml                # kube-prometheus-stack (Prometheus + Grafana + Node Exporter)
│   ├── kafka-values.yaml                     # Bitnami Kafka KRaft (-Xmx400m) -> vm-worker-stream
│   ├── redis-values.yaml                     # Bitnami Redis 7 -> vm-worker-stream
│   ├── postgres-values.yaml                  # Bitnami PostgreSQL 16 -> vm-worker-sql
│   ├── mongo-values.yaml                     # Bitnami MongoDB 7 -> vm-worker-nosql
│   └── gitlab-runner-values.yaml             # Kubernetes Executor GitLab Runner -> vm-worker-app
├── gitops/
│   └── argocd-application.yaml               # ArgoCD'nin Git reposunu izleyip otomatik sync yaptığı CRD
└── app/                                      # Event-Driven Polyglot FastAPI Uygulaması
    ├── Dockerfile                            # Non-root (UID 10001) güvenli Python 3.11 imajı
    ├── requirements.txt                      # FastAPI, Kafka, PostgreSQL, MongoDB, Redis, Prometheus paketleri
    ├── app.py                                # Kafka Producer/Consumer + 3 DB + /metrics + Canlı Terminal UI
    └── omnistream-chart/                     # Uygulamanın Helm Chart'ı (Deployment, Service, Ingress, ServiceMonitor)
```

---

## 🛠️ 3. Adım Adım Kurulum ve Çalıştırma Rehberi

### ADIM 1: Önceki Lab Ortamını Temizle (Kota Açma)
Azure for Students hesabındaki `6 vCPU` ve `3 Public IP` kotasını boşaltmak için (eğer açıkta önceki lab varsa) sil:
```bash
cd ~/k8sfundamentals/Projects/rancher-ui-rke2-project-3/terraform
terraform destroy -auto-approve
```

### ADIM 2: Terraform ile 5 Sunuculu Altyapıyı Kur
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/terraform
terraform init
terraform apply -auto-approve
```
> **Ne Yapar?**
> * `rg-omnistream-capstone-4` kaynak grubunu, VNet/Subnet'i, NAT Gateway'i, NSG'yi ve 5 sunucuyu (`vm-master`, `vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`, `vm-worker-app`) kurar.
> * `../ansible/hosts.ini` dosyasını gerçek IP adresleriyle otomatik üretir ve ekrana **Rancher, ArgoCD, Grafana ve App URL'lerini** basar!

### ADIM 3: Ansible ile Tüm Platformu Tek Komutla Ayağa Kaldır
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/ansible
ansible-playbook -i hosts.ini site.yml
```
> **Bu Playbook Sırasıyla Neleri Kurar?**
> 1. **`01-os-hardening.yml`:** 5 sunucuda Swap'ı kapatır, `overlay`/`br_netfilter` modüllerini yükler, Kafka ve Prometheus için `vm.max_map_count` ve `inotify` kernel ayarlarını yapar.
> 2. **`02-rke2-master.yml`:** `vm-master` üzerinde RKE2 Server'ı kurar, **Ingress NGINX Admission Webhook**'un hazır olmasını bekler, Helm 3'ü ve **Local-Path Provisioner**'ı (tüm Taint'leri aşan `helper-pod` yamasıyla birlikte) varsayılan `StorageClass` olarak kurar.
> 3. **`03-rke2-workers.yml`:** Master'dan join token'ı alıp 4 worker sunucusunu kümeye katar.
> 4. **`04-node-isolation.yml`:** 5 sunucuya mimari şemadaki **Label** ve **Taint** kurallarını basar.
> 5. **`05-platform-services.yml`:**
>    * `vm-master` üzerine: **Cert-Manager**, **Rancher UI**, **ArgoCD** ve **Prometheus + Grafana (`kube-prometheus-stack`)** kurar.
>    * `data` namespace'ine: **Apache Kafka (KRaft)**, **Redis**, **PostgreSQL** ve **MongoDB** kurar.
>    * `app` namespace'ine: **OmniStream FastAPI** uygulamasını kurar ve **ArgoCD Application** tanımını bağlar!

---

## 🖥️ 4. Web Arayüzlerine (UI) Erişim Bilgileri

Kurulum tamamlandığında Terraform çıktısındaki (veya Ansible sonundaki) adreslerden 4 farklı arayüze doğrudan tarayıcıdan girebilirsin:

| Platform | URL | Kullanıcı Adı | Şifre |
| :--- | :--- | :--- | :--- |
| **1. Canlı Uygulama (OmniStream UI)** | `http://app.<APP_IP>.nip.io` | *(Herkese Açık)* | *(Yok)* |
| **2. Rancher Dashboard UI** | `https://rancher.<MASTER_IP>.nip.io` | `admin` | `AdminPassword2026!` |
| **3. Grafana Observability UI** | `http://grafana.<MASTER_IP>.nip.io` | `admin` | `AdminPassword2026!` |
| **4. ArgoCD GitOps UI** | `http://argocd.<MASTER_IP>.nip.io` | `admin` | *(Aşağıdaki komutla alınır)* |

**ArgoCD İlk Giriş Şifresini Almak İçin (`vm-master` üzerinde):**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 🔄 5. Kendi İmajını Derleme, Docker Hub'a Pushlama ve CI/CD + ArgoCD Akışını Deneme

### A) Kendi Bilgisayarından Yeni İmaj Derleyip Docker Hub'a Pushlama:
Uygulama kodunda (`app/app.py`) istediğin bir yazıyı değiştirip kendi Docker Hub hesabına (`yusufk00/omnistream-app:v1`) göndermek için:
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/app

# 1. İmajı derle ve Docker Hub kullanıcı adınla etiketle
docker build -t yusufk00/omnistream-app:v1 .

# 2. Trivy ile yerel güvenlik taraması yap (İsteğe bağlı)
trivy image --severity HIGH,CRITICAL yusufk00/omnistream-app:v1

# 3. Docker Hub'a gönder
docker push yusufk00/omnistream-app:v1
```

### B) GitOps ile ArgoCD'nin Yeni İmajı Otomatik Çekmesini İzleme:
1. `Projects/devops-capstone-project-4/app/omnistream-chart/values.yaml` dosyasını aç:
   ```yaml
   image:
     repository: yusufk00/omnistream-app
     tag: "v1"
   ```
2. Değişikliği GitHub/GitLab'a pushla:
   ```bash
   git add Projects/devops-capstone-project-4/app/omnistream-chart/values.yaml
   git commit -m "feat(app): promote omnistream-app:v1 to production via GitOps"
   git push all main
   ```
3. **ArgoCD Arayüzüne (`http://argocd.<MASTER_IP>.nip.io`) git:** `omnistream-app` kartında **Refresh / Sync** butonuna bas (veya otomatik algılamasını bekle). ArgoCD'nin eski podu kapatıp yeni `yusufk00/omnistream-app:v1` podunu canlıya aldığını ve `http://app.<APP_IP>.nip.io` ekranında **⚡ Kafka Event Gönder (Produce)** butonuyla Kafka + PostgreSQL + MongoDB + Redis dörtlüsünün canlı çalıştığını gör!

### C) Grafana'da Canlı Metrikleri İzleme (`http://grafana.<MASTER_IP>.nip.io`):
1. Sol menüden **Dashboards** kısmına gir:
   * **Node Exporter / Nodes:** 5 sunucunun (`vm-master`, `vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`, `vm-worker-app`) anlık CPU, RAM, Disk I/O ve Ağ trafiğini incele.
   * **Explore (PromQL):** `omnistream_kafka_events_published_total` veya `omnistream_backend_latency_ms` yazarak uygulamanın `/metrics` uç noktasından (`ServiceMonitor` ile) toplanan özel Kafka ve DB metriklerini sorgula!

---

## 🧹 6. Temizlik (Maliyet Kontrolü)

Lab çalışman bittiğinde tüm Azure kaynaklarını tek komutla silmek için:
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/terraform
terraform destroy -auto-approve
```
