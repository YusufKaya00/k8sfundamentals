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
  subscription_id = "671cc34b-e462-449f-b81f-d58b6c056acc"
}

# 3. KAYNAK (RESOURCE): Azure'da ne oluşturmak istiyoruz?
# Format: resource "<KAYNAK_TIPI>" "<TERRAFORM_ICINDEKI_TAKMA_ADI>"
resource "azurerm_resource_group" "k8s_rg" {
  name     = "rg-k8s-lab"          # Azure Portal'da görünecek gerçek adı
  location = "germanywestcentral"  # Almanya (Frankfurt) veri merkezi
}
