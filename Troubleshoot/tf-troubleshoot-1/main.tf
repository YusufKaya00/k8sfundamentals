terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = "671cc34b-e462-449f-b81f-d58b6c056acc"
  resource_provider_registrations = "none"
}

# Bu labdaki kaynakların HEPSİ ücretsizdir (VM / Public IP yok).

resource "azurerm_resource_group" "rg" {
  name     = "rg-tf-troubleshoot-1"
  location = "denmarkeast"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-tf-lab"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Kritik kaynak: kazara silinmesin
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_subnet" "app" {
  name                 = "subnet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-tf-lab"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.0.0/8"
    destination_address_prefix = "*"
  }

  tags = {
    env = "lab"
  }
}

# ---------------------------------------------------------------
# ADIM 3'te (break.sh çalıştıktan SONRA) aşağıdaki bloğun yorumunu kaldır.
# Senaryo: Ekipten biri "subnet-db"yi portaldan elle açtı, sen de koda ekliyorsun.
# ---------------------------------------------------------------
# resource "azurerm_subnet" "db" {
#   name                 = "subnet-db"
#   resource_group_name  = azurerm_resource_group.rg.name
#   virtual_network_name = azurerm_virtual_network.vnet.name
#   address_prefixes     = ["10.10.2.0/24"]
# }
