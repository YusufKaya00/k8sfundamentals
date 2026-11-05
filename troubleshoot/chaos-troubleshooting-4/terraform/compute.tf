# ==============================================================================
# CHAOS & TROUBLESHOOTING LAB 1 - COMPUTE LAYER (3-NODE RKE2 CLUSTER)
# ==============================================================================
# Sanal Makineler:
#   - `vm-master`      (Standard_B2s_v2: 2 vCPU / 8 GB RAM - 10.30.1.4 - Public IP #1)
#   - `vm-worker-data` (Standard_B2s:    2 vCPU / 4 GB RAM - 10.30.1.5 - Özel IP, NAT GW)
#   - `vm-worker-app`  (Standard_B2s:    2 vCPU / 4 GB RAM - 10.30.1.6 - Public IP #2)
# ==============================================================================

locals {
  workers = {
    "vm-worker-data" = {
      private_ip = "10.30.1.5"
      role       = "data"
    }
    "vm-worker-app" = {
      private_ip = "10.30.1.6"
      role       = "app"
    }
  }
}

# ==============================================================================
# BÖLÜM A: KUBERNETES CONTROL PLANE (MASTER & BASTION NODE)
# ==============================================================================

resource "azurerm_public_ip" "pip_master" {
  name                = "pip-chaos-lab-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "chaos-troubleshooting-1"
    quota_slot = "1-of-3-master"
  }
}

resource "azurerm_network_interface" "nic_master" {
  name                = "nic-vm-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.30.1.4"
    public_ip_address_id          = azurerm_public_ip.pip_master.id
  }

  tags = {
    project = "chaos-troubleshooting-1"
    role    = "control-plane"
  }
}

resource "azurerm_linux_virtual_machine" "vm_master" {
  name                            = "vm-master"
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = var.master_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.nic_master.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-vm-master"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 40
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    project = "chaos-troubleshooting-1"
    role    = "control-plane"
  }
}

# ==============================================================================
# BÖLÜM B: KUBERNETES WORKER NODES (2x İŞÇİ DÜĞÜMÜ - DATA & APP)
# ==============================================================================

resource "azurerm_public_ip" "pip_app" {
  name                = "pip-chaos-lab-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "chaos-troubleshooting-1"
    quota_slot = "2-of-3-app-worker"
  }
}

resource "azurerm_network_interface" "nic_worker" {
  for_each = local.workers

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

  tags = {
    project = "chaos-troubleshooting-1"
    role    = each.value.role
  }
}

resource "azurerm_linux_virtual_machine" "vm_worker" {
  for_each = local.workers

  name                            = each.key
  resource_group_name             = azurerm_resource_group.rg.name
  location                        = azurerm_resource_group.rg.location
  size                            = var.worker_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.nic_worker[each.key].id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    name                 = "osdisk-${each.key}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 40
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    project = "chaos-troubleshooting-1"
    role    = each.value.role
  }
}
