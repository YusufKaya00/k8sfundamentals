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

resource "azurerm_public_ip" "vm_public_ip" {
  name                = "pip-k8s-node"
  location            = azurerm_resource_group.k8s_rg.location
  resource_group_name = azurerm_resource_group.k8s_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  
}


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

resource "azurerm_network_interface" "vm_nic" {
  name                = "nic-k8s-node"
  location            = azurerm_resource_group.k8s_rg.location
  resource_group_name = azurerm_resource_group.k8s_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.k8s_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm_public_ip.id
  }


  
}

resource "azurerm_network_interface_security_group_association" "nic_nsg_assoc" {
  network_interface_id      = azurerm_network_interface.vm_nic.id
  network_security_group_id = azurerm_network_security_group.vm_nsg.id
  
}

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
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

}

output "vm_public_ip_address" {
    value = azurerm_public_ip.vm_public_ip.ip_address
    description = "The public IP address of the virtual machine"
  }