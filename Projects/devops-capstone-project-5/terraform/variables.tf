# ==============================================================================
# RESILIENCESTREAM ENTERPRISE PLATFORM - INPUT VARIABLES (GİRDİ DEĞİŞKENLERİ)
# ==============================================================================
# Neden değişkenleri (variables.tf) ana koddan ayırıyoruz?
# Endüstri standardı DevOps/Cloud mühendisliğinde "Hardcoding" (değerleri doğrudan
# kaynak kodunun içine gömmek) en büyük anti-pattern'dir. Değişkenleri ayırmak:
# 1. Kodun tekrar kullanılabilirliğini (Reusability) sağlar: Aynı kodu Dev, Staging ve
#    Production ortamlarında sadece değişkenleri değiştirerek çalıştırabilirsiniz.
# 2. Güvenlik ve Bakım Kolaylığı: Bölge, VM boyutu veya SSH anahtarı değiştiğinde
#    yüzlerce satırlık compute/network dosyalarında arama yapmak yerine tek bir
#    noktadan (Single Source of Truth) yönetim yapılır.
#
# NEDEN PROD ORTAMINDA BÖYLEDİR VS LAB ORTAMI (SEÇENEK A: 3 SUNUCU / 6 vCPU)?
# - Prod'da: Kontrol düzlemi (Master) en az 3 sunuculu HA (High Availability)
#   olarak `Standard_D4s_v5` (4 vCPU / 16 GB RAM) üzerinde, Cassandra ve Kafka ise
#   en az 3'er fiziksel düğümde (`Standard_E8s_v5` - 64 GB RAM + NVMe disk) çalışır.
# - Lab'da (Azure for Students Kotası): Bölge başına "Toplam 6 vCPU" ve "Toplam 3 Public IP"
#   sınırımız vardır. Proje 4'te 4x B1ms (2 GB RAM) kullanmıştık; ancak Proje 5'te
#   JVM tabanlı **Apache Cassandra** + **Kafka KRaft** + **RabbitMQ** + **Chaos Mesh**
#   birlikte çalışacağı için 2 GB RAM'li düğümler OOMKilled riski taşır.
#   Bu yüzden **Seçenek A** topolojisiyle:
#     * 1x Master Node (`Standard_B2s_v2`) = 2 vCPU, 8 GB RAM
#     * 2x Worker Node (`Standard_B2s`)    = 2 x 2 vCPU = 4 vCPU, 2 x 4 GB = 8 GB RAM
#     -------------------------------------------------------------------------
#     TOPLAM HESAPLAMA                     = 2 + (2 * 2) = 6 vCPU (Kotanın %100'ü!)
#   Her bir worker sunucusuna 4 GB RAM vererek Cassandra (768M Heap), Kafka ve
#   RabbitMQ'nun kaos deneyleri (StressChaos/NetworkChaos) altında bile OOM olmadan
#   stabil çalışmasını garanti altına alıyoruz.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Kaynak Grubu Adı (Resource Group Name)
# ------------------------------------------------------------------------------
variable "resource_group_name" {
  description = "ResilienceStream platformunun tüm Azure kaynaklarını (VNet, NSG, NAT GW, 3 VM) barındıracak mantıksal konteynerin (Resource Group) adı."
  type        = string
  default     = "rg-resiliencestream-5"
}

# ------------------------------------------------------------------------------
# 2. Bulut Bölgesi (Azure Region / Location)
# ------------------------------------------------------------------------------
variable "location" {
  description = "Kaynakların fiziksel olarak oluşturulacağı Azure veri merkezi bölgesi. Azure for Students aboneliklerinde B-serisi (Burstable) VM kapasite kısıtlamalarına takılmamak için 'denmarkeast' seçilmiştir."
  type        = string
  default     = "denmarkeast"
}

# ------------------------------------------------------------------------------
# 3. Sunucu Yönetici Kullanıcı Adı (Linux Admin Username)
# ------------------------------------------------------------------------------
variable "admin_username" {
  description = "Tüm Ubuntu 24.04 LTS sunucularında oluşturulacak yetkili (sudo) Linux sistem yöneticisi kullanıcı adı. Ansible bu kullanıcı ile SSH bağlantısı kurar."
  type        = string
  default     = "ysf"
}

# ------------------------------------------------------------------------------
# 4. SSH Açık Anahtar Dosya Yolu (SSH Public Key Path)
# ------------------------------------------------------------------------------
variable "ssh_public_key_path" {
  description = "Sunuculara parolasız ve kriptografik olarak güvenli erişim sağlamak için kullanılacak SSH açık anahtarının (Public Key) yerel bilgisayardaki yolu."
  type        = string
  # Neden "~/.ssh/id_rsa.pub" kullanıyoruz ve compute.tf içinde neden pathexpand() ile sarıyoruz?
  # "~" (Tilde) karakteri Linux/macOS kabuklarında (Bash/Zsh) kullanıcının ev dizinini
  # (ör. /home/ysf) temsil eder. Ancak Terraform'un yerleşik `file()` fonksiyonu bir
  # kabuk (shell) olmadığı için "~" karakterini tek başına anlayamaz ve "dosya bulunamadı"
  # hatası verir. `pathexpand(var.ssh_public_key_path)` fonksiyonu, çalışma zamanında "~"
  # işaretini işletim sistemindeki gerçek mutlak yola (/home/ysf/.ssh/id_rsa.pub) çevirerek
  # kodun her geliştiricinin bilgisayarında taşınabilir (portable) çalışmasını sağlar.
  default = "~/.ssh/id_rsa.pub"
}

# ------------------------------------------------------------------------------
# 5. Kubernetes Control Plane (Master) Sunucu Boyutu (SKU)
# ------------------------------------------------------------------------------
variable "master_vm_size" {
  description = "RKE2 Control Plane, etcd, Rancher UI, ArgoCD, Prometheus/Grafana/Alertmanager ve Chaos Mesh Controller yığınını taşıyacak ana sunucunun Azure SKU boyutu (2 vCPU, 8 GB RAM)."
  type        = string
  # Standard_B2s_v2: 2 vCPU ve 8 GB RAM sunar.
  # Kubernetes API Server, etcd veritabanı, Rancher yönetim paneli, ArgoCD,
  # Prometheus TSDB, Alertmanager ve Chaos Mesh Controller yüksek bellek tükettiği için
  # OOM (Out-Of-Memory) çökmesi yaşamamak adına 8 GB RAM kritik bir gereksinimdir.
  default = "Standard_B2s_v2"
}

# ------------------------------------------------------------------------------
# 6. Kubernetes Worker (İşçi) Sunucuları Boyutu (SKU)
# ------------------------------------------------------------------------------
variable "worker_vm_size" {
  description = "Veri katmanı (vm-worker-data: Kafka KRaft, Cassandra, PostgreSQL) ve Uygulama/Mesajlaşma katmanını (vm-worker-app: FastAPI, RabbitMQ, Redis, GitLab Runner) çalıştıracak 2 adet Worker sunucusunun Azure SKU boyutu (2 vCPU, 4 GB RAM)."
  type        = string
  # Standard_B2s: Her biri 2 vCPU ve 4 GB RAM sunar.
  # 2 adet Worker (2 * 2 vCPU = 4 vCPU) ile Master (2 vCPU) birleştiğinde
  # Azure for Students 6 vCPU bölgesel kotasına tam olarak (2 + 2*2 = 6 vCPU) uyar.
  # 4 GB RAM sayesinde vm-worker-data üzerinde hem Cassandra (768M Heap) hem Kafka KRaft
  # hem de PostgreSQL bellek sıkışması olmadan kararlı biçimde çalışır.
  default = "Standard_B2s"
}
