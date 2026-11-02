terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = "671cc34b-e462-449f-b81f-d58b6c056acc"
  resource_provider_registrations = "none"
}

# 1. RESOURCE GROUP
resource "azurerm_resource_group" "rg" {
  name     = "rg-k8s-multi"
  location = "denmarkeast"
}

# 2. SANAL AĞ (VNet & Subnet)
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-k8s-multi"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "subnet-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 3. GÜVENLİK DUVARI (NSG) - SSH (22), K8s API (6443), HTTP (80)
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-k8s-multi"
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
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-K8s-API"
    priority                   = 1010
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-HTTP"
    priority                   = 1020
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# ==================== MASTER NODE ====================

resource "azurerm_public_ip" "master_pip" {
  name                = "pip-k8s-master"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "master_nic" {
  name                = "nic-k8s-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.master_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "master_assoc" {
  network_interface_id      = azurerm_network_interface.master_nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "master_vm" {
  name                = "vm-k8s-master"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s"
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.master_nic.id]

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

# ==================== WORKER NODE ====================

resource "azurerm_public_ip" "worker_pip" {
  name                = "pip-k8s-worker-1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "worker_nic" {
  name                = "nic-k8s-worker-1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.worker_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "worker_assoc" {
  network_interface_id      = azurerm_network_interface.worker_nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "worker_vm" {
  name                = "vm-k8s-worker-1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s"
  admin_username      = "azureuser"

  network_interface_ids = [azurerm_network_interface.worker_nic.id]

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

# ==================== OTOMASYON (INVENTORY DOSYASI) ====================

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<-EOT
[master]
master1 ansible_host=${azurerm_public_ip.master_pip.ip_address} private_ip=${azurerm_network_interface.master_nic.private_ip_address}

[workers]
worker1 ansible_host=${azurerm_public_ip.worker_pip.ip_address} private_ip=${azurerm_network_interface.worker_nic.private_ip_address}

[k8s_cluster:children]
master
workers
EOT

  depends_on = [
    azurerm_linux_virtual_machine.master_vm,
    azurerm_linux_virtual_machine.worker_vm
  ]
}

# ÇIKTILAR
output "master_public_ip" {
  value = azurerm_public_ip.master_pip.ip_address
}

output "worker_public_ip" {
  value = azurerm_public_ip.worker_pip.ip_address
}