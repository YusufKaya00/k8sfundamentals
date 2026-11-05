# ==============================================================================
# CHAOS & TROUBLESHOOTING LAB 1 - NETWORKING & SECURITY (AĞ VE GÜVENLİK)
# ==============================================================================
# 3 Public IP Kotası Dağılımı:
#   * Public IP #1 -> `vm-master` (10.30.1.4 - Control Plane, Chaos Mesh/Grafana Ingress & SSH Bastion)
#   * Public IP #2 -> `vm-worker-app` (10.30.1.6 - Canlı Uygulama & RabbitMQ UI Ingress)
#   * Public IP #3 -> `NAT Gateway` (`vm-worker-data` 10.30.1.5 özel düğümünün
#     dışarıdan erişilemez şekilde konteyner imajlarını çekebilmesi için çıkış kapısı)
# ==============================================================================

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project     = "chaos-troubleshooting-1"
    environment = "chaos-lab"
    managed_by  = "terraform"
  }
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-chaos-lab"
  address_space       = ["10.30.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    project = "chaos-troubleshooting-1"
  }
}

resource "azurerm_subnet" "subnet" {
  name                 = "snet-k8s-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.30.1.0/24"]
}

resource "azurerm_public_ip" "pip_natgw" {
  name                = "pip-chaos-lab-natgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "chaos-troubleshooting-1"
    quota_slot = "3-of-3-natgw"
  }
}

resource "azurerm_nat_gateway" "natgw" {
  name                    = "natgw-chaos-lab"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = {
    project = "chaos-troubleshooting-1"
  }
}

resource "azurerm_nat_gateway_public_ip_association" "natgw_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.natgw.id
  public_ip_address_id = azurerm_public_ip.pip_natgw.id
}

resource "azurerm_subnet_nat_gateway_association" "subnet_natgw_assoc" {
  subnet_id      = azurerm_subnet.subnet.id
  nat_gateway_id = azurerm_nat_gateway.natgw.id
}

resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-chaos-lab-k8s"
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
    name                       = "Allow-HTTP-HTTPS"
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
    name                       = "Allow-RKE2-Supervisor"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9345"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  tags = {
    project = "chaos-troubleshooting-1"
  }
}

resource "azurerm_subnet_network_security_group_association" "subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
