# 1. TERRAFORM & PROVIDER AYARLARI
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

# 2. RESOURCE GROUP: Tüm kaynaklarımızın çatısı
resource "azurerm_resource_group" "k8s_rg" {
  name     = "rg-k8s-lab"
  location = "denmarkeast"
}

# 3. SANAL AĞ (VNet) & SUBNET
resource "azurerm_virtual_network" "k8s_vnet" {
  name                = "vnet-k8s"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.k8s_rg.location
  resource_group_name = azurerm_resource_group.k8s_rg.name
}

resource "azurerm_subnet" "k8s_subnet" {
  name                 = "subnet-nodes"
  resource_group_name  = azurerm_resource_group.k8s_rg.name
  virtual_network_name = azurerm_virtual_network.k8s_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 4. PUBLIC IP: İnternetten SSH ile bağlanabilmek için
resource "azurerm_public_ip" "vm_pip" {
  name                = "pip-k8s-node"
  resource_group_name = azurerm_resource_group.k8s_rg.name
  location            = azurerm_resource_group.k8s_rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# 5. NSG (GÜVENLİK DUVARI): SSH (Port 22) açık
resource "azurerm_network_security_group" "vm_nsg" {
  name                = "nsg-k8s-node"
  location            = azurerm_resource_group.k8s_rg.location
  resource_group_name = azurerm_resource_group.k8s_rg.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# 6. SANAL AĞ KARTI (NIC) & GÜVENLİK DUVARI EŞLEŞTİRMESİ
resource "azurerm_network_interface" "vm_nic" {
  name                = "nic-k8s-node"
  location            = azurerm_resource_group.k8s_rg.location
  resource_group_name = azurerm_resource_group.k8s_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k8s_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.vm_nic.id
  network_security_group_id = azurerm_network_security_group.vm_nsg.id
}

# 7. LINUX SANAL MAKİNE (VM)
resource "azurerm_linux_virtual_machine" "k8s_vm" {
  name                = "vm-k8s-node"
  resource_group_name = azurerm_resource_group.k8s_rg.name
  location            = azurerm_resource_group.k8s_rg.location
  size                = "Standard_B2s"
  admin_username      = "azureuser"

  network_interface_ids = [
    azurerm_network_interface.vm_nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file("${path.module}/user.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# 8. OUTPUT: Sunucu IP'sini ekrana yazdırsın
output "public_ip_address" {
  value       = azurerm_public_ip.vm_pip.ip_address
  description = "Sunucunun Dis IP Adresi"
}