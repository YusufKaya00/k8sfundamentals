# 🚀 Proje 4: OmniStream — Kurumsal DevSecOps, GitOps (ArgoCD), Event-Driven (Kafka + 3 DB), Rancher UI ve Gözlemlenebilirlik (Prometheus & Grafana) Platformu

Bu proje; gerçek dünyadaki kurumsal bir **Platform / DevSecOps Mühendisliği** mimarisinin uçtan uca tüm katmanlarını (**Terraform IaC**, **Ansible Konfigürasyon Yönetimi**, **RKE2 Kubernetes**, **Rancher UI**, **Apache Kafka (KRaft) + PostgreSQL + MongoDB + Redis**, **Self-Hosted GitLab CI + Buildah + Trivy + Docker Hub**, **ArgoCD GitOps** ve **Prometheus + Grafana**) tek bir 5 sunuculu kümede birleştiren kapsamlı bir bitirme (capstone) projesidir.

> [!TIP]
> **Öğretici Kod Mimarisi:** Bu projedeki **tüm Terraform (`.tf`), Ansible (`.yml`), Helm (`values.yaml`), Uygulama (`app.py`, `Dockerfile`) ve CI/CD (`.gitlab-ci.yml`) dosyalarının içinde satır satır Türkçe mimari yorumlar** yer alır. Her bir parametrenin sektörde *neden* öyle yazıldığını dosyaları okurken doğrudan öğrenebilirsin.

---

## 🏛️ 1. Sistem Mimarisi ve 5-Node Donanım İzolasyonu

Azure for Students kısıtlarına (**`denmarkeast`** bölgesi, toplam **`6 vCPU`** ve maksimum **`3 Public IP`**) %100 uyumlu olacak şekilde, hiçbir sunucuda `OOMKilled` (`137`) veya `Insufficient cpu` yaşanmaması için iş yükleri **Taint & Toleration** ve **NodeSelector** kurallarıyla 5 sunucuya matematiksel olarak dağıtılmıştır:

```text
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

### 🧠 Neyi Neden Böyle Tasarladık ve Canlıda Hangi Mühendislik Düzeltmelerini Yaptık?

| Katman | Mimari Karar / Düzeltme | Sektörde Neden Böyle Yapılır? |
| :--- | :--- | :--- |
| **Terraform Yapısı** | Tek bir `main.tf` yerine `versions.tf`, `variables.tf`, `network.tf`, `compute.tf`, `outputs.tf` | Üretim ortamlarında ekip içi çakışmaları (merge conflict) önlemek ve okunabilirliği artırmak için ağ, sunucu ve çıktılar ayrı dosyalara bölünür. |
| **Ağ Güvenliği (Zero Public IP DBs)** | Veritabanı ve Kafka düğümlerine Public IP verilmez; `NAT Gateway` kullanılır | Veritabanları asla internete doğrudan açılmaz. İmaj indirmek için dışarı çıkarken `NAT Gateway` (SNAT) kullanırlar, dışarıdan içeriye doğrudan bağlantı imkansızdır. |
| **SSH Bastion (`ProxyCommand`)** | Ansible özel ağdaki worker'lara `vm-master` üzerinden tünel kurarak girer | `hosts.ini.tftpl` içindeki `ProxyCommand="ssh -W %h:%p ..."` sayesinde tek bir komutla dış IP'si olmayan iç ağ sunucuları yönetilir. |
| **Master CPU Bütçesi (`2000m`)** | `rancher`, `argocd` ve `monitoring` CPU `requests` değerleri `10m-25m` seviyesine çekildi | RKE2 sistem bileşenleri (`etcd`, `apiserver`, `canal`, `ingress-nginx`) `2000m` CPU'nun `1675m`'ini rezerve eder. Geriye kalan `325m` içine Rancher + ArgoCD + Prometheus + Grafana'nın sığması ve `Pending (Insufficient cpu)` olmaması için CPU request optimizasyonu şarttır. |
| **Apache Kafka (KRaft & Bitnami Legacy)** | ZooKeeper kapalı (`zookeeper.enabled: false`), imaj deposu `bitnamilegacy/kafka` | Bitnami sürüm etiketli imajları `docker.io/bitnamilegacy/kafka` deposuna taşıdığı için `ImagePullBackOff` yaşanmaması adına `allowInsecureImages: true` ile birlikte legacy repo kullanıldı. |
| **DevSecOps CI/CD** | Rootless `Buildah` (`vfs` + `chroot`) -> `Trivy` -> `Docker Hub` -> `yq` ile GitOps `values.yaml` commit | Docker Daemon (`docker.sock`) güvenlik açığı yaratır; Kubernetes içinde **Buildah** ile ayrıcalıksız (unprivileged) pod içinde imaj derlenir, **Trivy** ile taranır, **yq** ile `values.yaml` güncellenir ve **ArgoCD** ile küme güncellenir. |

---

## 📂 2. Proje Dizin Yapısı

```text
Projects/devops-capstone-project-4/
├── README.md                                 # Bu kapsamlı mimari, kurulum ve canlı test rehberi
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

## 🛠️ 3. Adım Adım Kurulum Rehberi

### ADIM 1: Terraform ile 5 Sunuculu Altyapıyı Kur
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/terraform
terraform init
terraform apply -auto-approve
```
* `rg-omnistream-capstone-4` kaynak grubunu, VNet/Subnet'i, NAT Gateway'i, NSG'yi ve 5 sunucuyu (`vm-master`, `vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`, `vm-worker-app`) kurar.
* `../ansible/hosts.ini` dosyasını gerçek IP adresleriyle otomatik üretir ve ekrana **Rancher, ArgoCD, Grafana ve App URL'lerini** basar!

### ADIM 2: Ansible ile Tüm Platformu Tek Komutla Ayağa Kaldır
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/ansible
ansible-playbook -i hosts.ini site.yml
```

---

## 🖥️ 4. Web Arayüzlerine (UI) Erişim Bilgileri

| Platform | URL | Kullanıcı Adı | Şifre |
| :--- | :--- | :--- | :--- |
| **1. Canlı Uygulama (OmniStream UI)** | `http://app.<APP_IP>.nip.io` | *(Herkese Açık)* | *(Yok)* |
| **2. Grafana Özel OmniStream Dashboard** | `http://grafana.<MASTER_IP>.nip.io/d/omnistream-command-center` | `admin` | `AdminPassword2026!` |
| **3. Rancher Dashboard UI** | `https://rancher.<MASTER_IP>.nip.io` | `admin` | `AdminPassword2026!` |
| **4. ArgoCD GitOps UI** | `http://argocd.<MASTER_IP>.nip.io` | `admin` | *(Aşağıdaki komutla alınır)* |

**ArgoCD İlk Giriş Şifresini Almak İçin (`vm-master` üzerinde):**
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## 🔄 5. Self-Hosted GitLab Runner + Buildah + Trivy + Docker Hub + ArgoCD Akışı

GitLab'ın ücretsiz paylaşımlı (Instance) runner dakikalarına bağımlı kalmadan, **GitLab Runner doğrudan RKE2 kümemizin içine (`vm-worker-app` düğümüne) kurulur.**

### 1. GitLab'da CI/CD Dosya Yolunu Tanımla (Alt Klasör İçin)
Depoda birden fazla proje bulunduğu ve `.gitlab-ci.yml` dosyası bu projenin klasörü içinde yer aldığı için:
* **Settings -> CI/CD -> General pipelines -> CI/CD configuration file** kutusuna şunu yazıp kaydet:
  ```text
  Projects/devops-capstone-project-4/.gitlab-ci.yml
  ```

### 2. GitLab CI/CD Değişkenlerini Tanımla (`Settings -> CI/CD -> Variables`)
* **`DOCKERHUB_USERNAME`**: Docker Hub kullanıcı adın (`yusufk00`)
* **`DOCKERHUB_TOKEN`**: Docker Hub şifren veya Access Token'ın
* **`GITLAB_ACCESS_TOKEN`** *(veya `GIT_PUSH_TOKEN`)*: GitLab **Personal Access Token (`glpat-...`)** — oluşturulurken **`write_repository`** ve **`api`** kutucukları mutlaka işaretlenmeli ve Variable eklenirken **"Protect variable" işareti kaldırılmalıdır**.

### 3. `vm-master` Üzerinden Helm ile GitLab Runner'ı Kümeye Kur
```bash
helm upgrade --install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner --create-namespace \
  -f /home/ysf/helm-values/gitlab-runner-values.yaml \
  --set runnerToken="BURAYA_GLRT_TOKEN_YAPISTIR"
```

### 4. GitOps Bot Commit'inden Sonra Yerel Bilgisayardan Push Atma Kuralı
Pipeline'daki 4. aşama (`gitops_promote`) çalıştığında `OmniStream GitOps Bot` senin adına GitLab deposuna yeni bir commit (`chore(gitops) promote omnistream-app image to <SHA> [skip ci]`) atar. Bu yüzden kendi bilgisayarından yeni bir değişiklik pushlamadan önce botun attığı commit'i bilgisayarına çekmelisin:
```bash
git pull --rebase gitlab main
git push all main
```

---

## 🧪 6. Kurulan Platformu Uçtan Uca Test Etme ve Deney Senaryoları (Grafana, Prometheus, ArgoCD, Rancher, Kafka)

Bu bölümde kurduğumuz her bir bileşeni (Grafana, Prometheus, ArgoCD Self-Heal, Rancher ve Kafka) bizzat test edebileceğin **5 gerçek dünya SRE / DevSecOps senaryosu** yer almaktadır:

### Senaryo 1: Canlı Uygulamadan Kafka Yük Testi Yapıp Grafana'da İzleme 📊
Sana özel olarak Grafana içine **"🚀 OmniStream — Kafka KRaft, Polyglot DBs & 5-Node RKE2 Command Center"** adında özel bir Dashboard kuruldu!

1. Tarayıcıdan doğrudan şu adresi aç (`admin` / `AdminPassword2026!`):
   👉 **`http://grafana.<MASTER_IP>.nip.io/d/omnistream-command-center`**
2. Şimdi kendi bilgisayarının terminalinden aşağıdaki komutla canlı uygulamaya **20 adet ardışık Kafka + 3 Veritabanı işlemi** gönder (veya `http://app.<APP_IP>.nip.io` arayüzündeki **"⚡ PRODUCE KAFKA EVENT"** butonuna art arda bas):
   ```bash
   for i in {1..20}; do
     curl -s -X POST http://app.<APP_IP>.nip.io/api/publish \
       -H "Content-Type: application/json" \
       -d "{\"event_type\":\"LOAD_TEST_$i\",\"amount\":$((RANDOM % 500)),\"user_id\":\"sre-tester\"}" > /dev/null
     echo "Event #$i gonderildi!"
   done
   ```
3. Grafana ekranına (`omnistream-command-center`) bak (her 5 saniyede bir otomatik yenilenir):
   * **🟢 Polyglot Data & Streaming Health:** `kafka`, `redis`, `postgresql`, `mongodb` kutularının 4'ünün de yemyeşil **`UP ✅`** olduğunu,
   * **📨 Kafka KRaft Toplam Yayınlanan Event Sayısı:** Sayacın anlık olarak yukarı fırladığını,
   * **⏱️ Veritabanı & Kafka Gecikmesi (Latency):** Hangi veritabanının kaç milisaniyede yanıt verdiğini,
   * **⚡ Namespace Bazlı Pod Bellek Kullanımı:** `data`, `app`, `monitoring`, `argocd` ve `cattle-system` katmanlarının ne kadar RAM tükettiğini canlı grafiklerde göreceksin!

---

### Senaryo 2: Kaos Mühendisliği (Chaos Engineering) — Veritabanını Çökertip Grafana'da "DOWN ❌" Alarmını Görmek 💥
Bir veritabanı çöktüğünde uygulamanın ve Grafana'nın nasıl tepki verdiğini test edelim:

1. `vm-master` sunucusunda Redis veya MongoDB'yi geçici olarak `0` kopyaya düşür (durdur):
   ```bash
   kubectl scale statefulset mongodb -n data --replicas=0
   ```
2. Uygulama sayfasını (`http://app.<APP_IP>.nip.io`) yenile veya 15 saniye sonra Grafana Dashboard'una bak:
   * Uygulama çökmez (**Graceful Degradation**); Kafka, Redis ve PostgreSQL çalışmaya devam ederken sadece MongoDB kartı kırmızıya döner.
   * Grafana'daki **`omnistream_db_health_status`** panelinde `mongodb` kutusu anında kırmızı **`DOWN ❌ (0)`** olur!
3. Şimdi MongoDB'yi tekrar ayağa kaldır:
   ```bash
   kubectl scale statefulset mongodb -n data --replicas=1
   ```
   Saniyeler içinde hem uygulama arayüzünün hem de Grafana'nın tekrar **`4/4 Systems Operational (UP ✅)`** durumuna geçtiğini göreceksin!

---

### Senaryo 3: ArgoCD "Self-Heal" (Kendi Kendini İyileştirme / Drift Önleme) Testi 🛡️
Bir kişinin kümeye `kubectl` ile girip yetkisiz bir değişiklik (Configuration Drift) yaptığında ArgoCD'nin bunu nasıl otomatik geri aldığını test et:

1. ArgoCD arayüzünü (`http://argocd.<MASTER_IP>.nip.io`) aç ve `omnistream-app` kartına tıkla.
2. `vm-master` terminalinden uygulamayı elle **3 kopyaya (replica)** çıkarmayı dene:
   ```bash
   kubectl scale deployment omnistream-app -n app --replicas=3
   ```
3. ArgoCD ekranını izle:
   * ArgoCD Git deposundaki `values.yaml` dosyasında `replicaCount: 1` yazdığını bildiği için, senin elle yaptığın değişikliği **saniyeler içinde tespit eder (`OutOfSync`)** ve `selfHeal: true` politikası sayesinde fazla açılan 2 pod'u otomatik silip kümeyi tekrar Git'teki gerçek duruma (`1` pod) döndürür!

---

### Senaryo 4: Rancher UI Üzerinden 5-Node Taint/Toleration ve Canlı Pod Loglarını İnceleme 🐄
1. Tarayıcıdan `https://rancher.<MASTER_IP>.nip.io` adresine gir (`admin` / `AdminPassword2026!`).
2. **`local` kümesine -> Cluster -> Nodes** menüsüne tıkla:
   * 5 sunucunun (`vm-master`, `vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`, `vm-worker-app`) her birinin üzerindeki **Taint** ve **Label** etiketlerini görsel olarak incele.
3. **Workloads -> Pods** menüsüne girip `omnistream-app` podunun sağındaki **`⋮` -> View Logs** veya **Execute Shell** butonuna tıklayarak tarayıcı içinden doğrudan pod'un içine terminal aç!

---

## 🧹 7. Temizlik (Maliyet Kontrolü)

Lab çalışman bittiğinde tüm Azure kaynaklarını tek komutla silmek için:
```bash
cd ~/k8sfundamentals/Projects/devops-capstone-project-4/terraform
terraform destroy -auto-approve
```
