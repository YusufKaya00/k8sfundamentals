# ==============================================================================
# CHAOS & TROUBLESHOOTING LAB 1 - INPUT VARIABLES (GİRDİ DEĞİŞKENLERİ)
# ==============================================================================
# 3 Sunucu / 6 vCPU (Azure for Students Kotası ile %100 Uyumlu Topoloji):
#   * 1x Master Node (`Standard_B2s_v2`) = 2 vCPU, 8 GB RAM
#   * 2x Worker Node (`Standard_B2s`)    = 2 x 2 vCPU = 4 vCPU, 2 x 4 GB = 8 GB RAM
#   ---------------------------------------------------------------------------
#   TOPLAM HESAPLAMA                     = 2 + (2 * 2) = 6 vCPU (3 Public IP)
# ==============================================================================

variable "resource_group_name" {
  description = "Chaos & Troubleshooting Lab 2 kaynaklarını (VNet, NSG, NAT GW, 3 VM) barındıracak Azure Resource Group adı."
  type        = string
  default     = "rg-chaos-troubleshoot-2"
}

variable "location" {
  description = "Kaynakların oluşturulacağı Azure veri merkezi bölgesi."
  type        = string
  default     = "denmarkeast"
}

variable "admin_username" {
  description = "Tüm Ubuntu 24.04 LTS sunucularında oluşturulacak yetkili (sudo) Linux kullanıcı adı."
  type        = string
  default     = "ysf"
}

variable "ssh_public_key_path" {
  description = "Sunuculara parolasız erişim için kullanılacak SSH açık anahtarının (Public Key) yerel yolu."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "master_vm_size" {
  description = "RKE2 Control Plane, Prometheus/Grafana ve Chaos Mesh Controller yığınını taşıyacak ana sunucunun Azure SKU boyutu (2 vCPU, 8 GB RAM)."
  type        = string
  default     = "Standard_B2s_v2"
}

variable "worker_vm_size" {
  description = "Veri katmanı (vm-worker-data: Kafka, Cassandra, PostgreSQL) ve Uygulama/Mesajlaşma katmanını (vm-worker-app: FastAPI, RabbitMQ, Redis) çalıştıracak 2 adet Worker sunucusunun Azure SKU boyutu (2 vCPU, 4 GB RAM)."
  type        = string
  default     = "Standard_B2s"
}
