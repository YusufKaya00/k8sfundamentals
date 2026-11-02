terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# 1. Kaynak Grubu
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# 2. Ağ Yapısı (VNet & Subnet)
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-rke2-ui-lab"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "snet-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

# 3. NAT Gateway (Dış IP'si Olmayan Worker'ların Güvenli İnternet Çıkışı İçin - Kota: 1/3 IP)
resource "azurerm_public_ip" "pip_natgw" {
  name                = "pip-natgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "natgw" {
  name                = "nat-gw-rke2"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "natgw_ip" {
  nat_gateway_id       = azurerm_nat_gateway.natgw.id
  public_ip_address_id = azurerm_public_ip.pip_natgw.id
}

resource "azurerm_subnet_nat_gateway_association" "subnet_natgw" {
  subnet_id      = azurerm_subnet.subnet.id
  nat_gateway_id = azurerm_nat_gateway.natgw.id
}

# 4. Ağ Güvenlik Grubu (NSG)
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-rke2-ui-lab"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Web"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-K8s-API"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-RKE2-Join"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9345"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

# 5. MASTER SUNUCU (Standard_B2s_v2 - 2 vCPU, 8 GB RAM - Kota: 2/3 IP)
resource "azurerm_public_ip" "pip_master" {
  name                = "pip-vm-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic_master" {
  name                = "nic-vm-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.10.1.4"
    public_ip_address_id          = azurerm_public_ip.pip_master.id
  }
}

resource "azurerm_linux_virtual_machine" "vm_master" {
  name                  = "vm-master"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = "Standard_B2s_v2" # 2 vCPU, 8 GB RAM (Bsv2 Kotası)
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_master.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# 6. DÖRT ADET WORKER SUNUCU (Standard_B1ms - 1 vCPU, 2 GB RAM - BS Kotası: 4/4 vCPU)
locals {
  workers = {
    "vm-worker-infra" = { private_ip = "10.10.1.5", role = "infra" }
    "vm-worker-pg"    = { private_ip = "10.10.1.6", role = "db-sql" }
    "vm-worker-mongo" = { private_ip = "10.10.1.7", role = "db-nosql" }
    "vm-worker-app"   = { private_ip = "10.10.1.8", role = "app" }
  }
}

# 3/3 IP Kotası: Sadece vm-worker-app sunucusuna Public IP atanır!
resource "azurerm_public_ip" "pip_app" {
  name                = "pip-vm-worker-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic_worker" {
  for_each            = local.workers
  name                = "nic-${each.key}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = each.key == "vm-worker-app" ? azurerm_public_ip.pip_app.id : null
  }
}

resource "azurerm_linux_virtual_machine" "vm_worker" {
  for_each              = local.workers
  name                  = each.key
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = "Standard_B1ms" # 1 vCPU, 2 GB RAM (BS Kotası)
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nic_worker[each.key].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
