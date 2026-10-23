variable "resource_group_name" {
  type        = string
  default     = "rg-rke2-prod"
  description = "Azure Resource Group adı"
}

variable "location" {
  type        = string
  default     = "denmarkeast"
  description = "Azure Bölgesi (Student kotasına uygun)"
}

variable "admin_username" {
  type        = string
  default     = "ysf"
  description = "VM admin kullanıcı adı"
}

variable "vnet_cidr" {
  type        = string
  default     = "10.10.0.0/16"
  description = "VNet IP bloğu"
}

variable "subnet_cidr" {
  type        = string
  default     = "10.10.1.0/24"
  description = "Subnet IP bloğu"
}
