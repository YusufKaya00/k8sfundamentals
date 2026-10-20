# 1. TERRAFORM AYARLARI: Hangi bulut eklentisini (provider) indireceğini söylüyoruz
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# 2. PROVIDER AYARLARI: Azure'a hangi abonelikle bağlanacağını söylüyoruz
provider "azurerm" {
  features {}
  subscription_id                 = "671cc34b-e462-449f-b81f-d58b6c056acc"
  resource_provider_registrations = "none"
}

# 3. KAYNAK (RESOURCE): Azure'da ne oluşturmak istiyoruz?
# Format: resource "<KAYNAK_TIPI>" "<TERRAFORM_ICINDEKI_TAKMA_ADI>"
resource "azurerm_resource_group" "k8s_rg" {
  name     = "rg-k8s-lab"          # Azure Portal'da görünecek gerçek adı
  location = "germanywestcentral"  # Almanya (Frankfurt) veri merkezi
}


resource "azurerm_virtual_network" "k8s_vnet" {
  name                = "vnet-k8s-lab"
  address_space       = ["10.0.0.0/16"]
  resource_group_name = azurerm_resource_group.k8s_rg.name
  location = azurerm_resource_group.k8s_rg.location
}

resource "azurerm_subnet" "k8s_subnet" {
  name                 = "subnet-k8s-lab"
  resource_group_name  = azurerm_resource_group.k8s_rg.name
  virtual_network_name = azurerm_virtual_network.k8s_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}