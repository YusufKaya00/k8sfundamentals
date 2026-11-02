variable "resource_group_name" {
  description = "Azure Kaynak Grubu Adı"
  type        = string
  default     = "rg-rke2-ui-lab"
}

variable "location" {
  description = "Azure Bölgesi (Azure for Students kotalarına tam uyumlu)"
  type        = string
  default     = "denmarkeast"
}

variable "admin_username" {
  description = "Linux VM Yönetici Kullanıcı Adı"
  type        = string
  default     = "ysf"
}

variable "ssh_public_key_path" {
  description = "Yerel makinedeki sabit SSH public key yolu (Kalıcı ve hatasız giriş için)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}
