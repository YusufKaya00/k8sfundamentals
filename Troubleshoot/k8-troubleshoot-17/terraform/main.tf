terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

# 1. Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    Environment = "Troubleshoot"
    Lab         = "k8-troubleshoot-17"
    ManagedBy   = "Terraform"
  }
}

# 2. Managed AKS Cluster (Free Control Plane Tier)
resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix
  sku_tier            = "Free"

  # Web Tier Node Pool: 2 Nodes (tier=web, Untainted)
  default_node_pool {
    name       = "webpool"
    node_count = 2
    vm_size    = var.vm_size
    node_labels = {
      tier = "web"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = {
    Environment = "Troubleshoot"
    Lab         = "k8-troubleshoot-17"
  }
}

# 3. Dedicated Database Node Pool: 1 Node (tier=database, Taint: workload=database:NoSchedule)
resource "azurerm_kubernetes_cluster_node_pool" "database" {
  name                  = "dbpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = var.vm_size
  node_count            = 1

  node_labels = {
    tier = "database"
  }

  node_taints = [
    "workload=database:NoSchedule"
  ]

  tags = {
    Environment = "Troubleshoot"
    Tier        = "Database"
  }
}
