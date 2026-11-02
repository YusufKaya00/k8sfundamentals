# ==============================================================================
# OMNISTREAM ENTERPRISE PLATFORM - INPUT VARIABLES (GİRDİ DEĞİŞKENLERİ)
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
# AZURE FOR STUDENTS KOTA MATEMATİĞİ (NEDEN BU BÖLGE VE BU VM BOYUTLARI?):
# Azure for Students aboneliklerinde bölge başına (Regional Quota) çok sıkı bir
# "Toplam 6 vCPU" ve "Toplam 3 Public IP" sınırı uygulanmaktadır:
#   - 1x Master Node (`Standard_B2s_v2`) = 2 vCPU, 8 GB RAM
#   - 4x Worker Node (`Standard_B1ms`)   = 4 x 1 vCPU = 4 vCPU, 4 x 2 GB = 8 GB RAM
#   ---------------------------------------------------------------------------
#   TOPLAM HESAPLAMA                     = 2 + (4 * 1) = 6 vCPU (Kotanın %100'ü!)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Kaynak Grubu Adı (Resource Group Name)
# ------------------------------------------------------------------------------
variable "resource_group_name" {
  description = "OmniStream platformunun tüm Azure kaynaklarını (VNet, NSG, NAT GW, 5 VM) barındıracak mantıksal konteynerin (Resource Group) adı."
  type        = string
  default     = "rg-omnistream-capstone-4"
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
  description = "RKE2 Control Plane, etcd, Rancher UI, ArgoCD ve Prometheus/Grafana yığınını taşıyacak ana sunucunun Azure SKU boyutu (2 vCPU, 8 GB RAM)."
  type        = string
  # Standard_B2s_v2: 2 vCPU ve 8 GB RAM sunar.
  # Kubernetes API Server, etcd veritabanı, Rancher yönetim paneli, ArgoCD ve
  # Prometheus zaman serisi veritabanı (TSDB) yüksek bellek tükettiği için
  # OOM (Out-Of-Memory) çökmesi yaşamamak adına 8 GB RAM kritik bir gereksinimdir.
  default = "Standard_B2s_v2"
}

# ------------------------------------------------------------------------------
# 6. Kubernetes Worker (İşçi) Sunucuları Boyutu (SKU)
# ------------------------------------------------------------------------------
variable "worker_vm_size" {
  description = "Veri katmanı (Kafka+Redis, PostgreSQL, MongoDB) ve Uygulama/CI katmanını izole olarak çalıştıracak 4 adet Worker sunucusunun Azure SKU boyutu (1 vCPU, 2 GB RAM)."
  type        = string
  # Standard_B1ms: Her biri 1 vCPU ve 2 GB RAM sunar.
  # 4 adet Worker (4 * 1 vCPU = 4 vCPU) ile Master (2 vCPU) birleştiğinde
  # Azure for Students 6 vCPU bölgesel kotasına tam olarak (2 + 4*1 = 6 vCPU) uyar.
  # İş yükleri Taint/Toleration ve NodeSelector ile her düğüme özel (Dedicated)
  # dağıtıldığı için 2 GB RAM her bir veritabanı/servis için fazlasıyla yeterlidir.
  default = "Standard_B1ms"
}
