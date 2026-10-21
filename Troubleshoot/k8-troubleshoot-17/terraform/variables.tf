variable "subscription_id" {
  description = "Azure Subscription ID for Azure for Students"
  type        = string
  default     = "671cc34b-e462-449f-b81f-d58b6c056acc"
}

variable "resource_group_name" {
  description = "Name of the resource group for the AKS cluster"
  type        = string
  default     = "rg-aether-aks"
}

variable "location" {
  description = "Azure region permitted by student policy"
  type        = string
  default     = "denmarkeast"
}

variable "cluster_name" {
  description = "Name of the managed AKS cluster"
  type        = string
  default     = "aks-aether-prod"
}

variable "dns_prefix" {
  description = "DNS prefix for the AKS API server"
  type        = string
  default     = "aether-k8s"
}

variable "vm_size" {
  description = "Virtual machine size for worker nodes (2 vCPUs, 4GB RAM)"
  type        = string
  default     = "Standard_B2s"
}
