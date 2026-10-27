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

## 🔄 5. GitLab Kredisi Kullanmadan Kendi Kümemizde CI/CD + Trivy + Docker Hub + ArgoCD Akışı (Self-Hosted Kubernetes Runner)

GitLab'ın ücretsiz paylaşımlı (Shared/Instance) runner dakikaları dolduğunda (veya gerçek kurumsal şirket ortamlarında iç ağdaki kümeye erişmek gerektiğinde), **GitLab Runner'ı doğrudan RKE2 kümemizin içine (`vm-worker-app` düğümüne) bir Pod olarak kurarız.** Pipeline tetiklendiğinde kümede geçici bir Pod açar, Buildah ile imajı derler, Trivy ile tarar, Docker Hub'a pushlar, `values.yaml` dosyasını günceller ve işi bitince Pod'u siler!

### ADIM 1: GitLab Arayüzünden Runner Token (`glrt-...`) Al ve Paylaşımlı Runner'ı Kapat
1. GitLab projenin sol menüsünden **Settings -> CI/CD -> Runners** kısmına git.
2. Sağ taraftaki **Instance runners** (Paylaşımlı runner'lar) bölümündeki **"Enable instance runners for this project"** şalterini **KAPAT** *(Böylece GitLab kota/kredi hatası verip bekletmez, doğrudan senin RKE2 kümendeki runner'ı kullanır!)*.
3. Üstteki **New project runner** butonuna tıkla:
   * **Run untagged jobs** kutucuğunu **İŞARETLE** (Çok önemli!).
   * **Create runner** butonuna tıkla ve ekranda çıkan **`glrt-...`** ile başlayan Token'ı kopyala.

### ADIM 2: GitLab CI/CD Değişkenlerini Tanımla (`Settings -> CI/CD -> Variables`)
Pipeline'ın Docker Hub'a imaj atabilmesi ve GitOps commit'i yapabilmesi için **Settings -> CI/CD -> Variables** ekranından şu 3 değişkeni ekle (*Mask variable* kutucuğunu işaretleyebilirsin, *Protect variable* kutucuğunu işaretleme):
* **`DOCKERHUB_USERNAME`**: Docker Hub kullanıcı adın (Örn: `yusufk00`)
* **`DOCKERHUB_TOKEN`**: Docker Hub şifren veya Access Token'ın
* **`GIT_PUSH_TOKEN`**: GitLab Personal Access Token (`write_repository` yetkili)

### ADIM 3: `vm-master` Üzerinden Helm ile GitLab Runner'ı Kümeye Kur
Ansible zaten `gitlab` Helm reposunu ve `/home/ysf/helm-values/gitlab-runner-values.yaml` dosyasını (`vm-worker-app` üzerine yerleşecek ve `rbac.create=true` olacak şekilde) hazırladı. Tek yapman gereken `vm-master` sunucusunda şu komutu çalıştırmak:

```bash
helm upgrade --install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner --create-namespace \
  -f /home/ysf/helm-values/gitlab-runner-values.yaml \
  --set runnerToken="BURAYA_GLRT_TOKEN_YAPISTIR"
```

Kontrol et:
```bash
kubectl get pods -n gitlab-runner -o wide
```
Pod **`Running` (`1/1`)** olduğunda GitLab **Settings -> CI/CD -> Runners** ekranında runner'ının yanında **yeşil daire (Online)** yandığını göreceksin!

---

### ADIM 4: Pipeline'ı Tetikle ve 4 Aşamalı DevSecOps + ArgoCD Şovunu İzle!
Şimdi repo kök dizininde [`.gitlab-ci.yml`](file:///home/ysf/k8sfundamentals/Projects/devops-capstone-project-4/.gitlab-ci.yml) dosyasını aktif edip (veya `app/app.py` içinde ufak bir metin değiştirip) GitLab'a pushladığında:

1. **`build_image` (Buildah):** `vm-worker-app` üzerinde geçici bir pod açılır, Docker Daemon olmadan (`vfs` + `chroot` ile) `app/Dockerfile` derlenir.
2. **`trivy_security_scan` (Aqua Trivy):** Derlenen imaj `HIGH` ve `CRITICAL` zafiyetlere karşı taranır ve JSON güvenlik raporu üretilir.
3. **`push_to_dockerhub`:** Doğrulanan imaj `docker.io/yusufk00/omnistream-app:<COMMIT_SHA>` ve `:latest` olarak Docker Hub'a yüklenir.
4. **`gitops_promote`:** Pipeline otomatik olarak `app/omnistream-chart/values.yaml` içindeki `tag:` satırını yeni `<COMMIT_SHA>` ile günceller ve `[skip ci]` mesajıyla Git'e pushlar.
5. **ArgoCD (`http://argocd.<MASTER_IP>.nip.io`):** Git'teki değişikliği yakalar ve `omnistream-app` podunu sıfır kesintiyle (RollingUpdate) günceller!

---

### C) Grafana'da Canlı Metrikleri İzleme (`http://grafana.<MASTER_IP>.nip.io`):
1. Sol menüden **Dashboards** kısmına gir:
   * **Node Exporter / Nodes:** 5 sunucunun (`vm-master`, `vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`, `vm-worker-app`) anlık CPU, RAM, Disk I/O ve Ağ trafiğini incele.
   * **Explore (PromQL):** `omnistream_kafka_events_published_total` veya `omnistream_db_health_status` yazarak uygulamanın `/metrics` uç noktasından (`ServiceMonitor` ile) toplanan özel Kafka ve DB metriklerini sorgula!

---

## 🧹 6. Temizlik (Maliyet Kontrolü)

Lab çalışman bittiğinde tüm Azure kaynaklarını tek komutla silmek için:
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/terraform
terraform destroy -auto-approve
```
