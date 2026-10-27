# ==============================================================================
# RESILIENCESTREAM ENTERPRISE PLATFORM - NETWORKING & SECURITY (AĞ VE GÜVENLİK)
# ==============================================================================
# Bu dosya (network.tf), 3 düğümlü RKE2 Kubernetes kümemizin üzerinde çalışacağı
# izole bulut ağını (`10.30.0.0/16` VNet), alt ağını (`10.30.1.0/24` Subnet),
# dış dünyaya güvenli çıkış kapısını (NAT Gateway) ve durum bilgili güvenlik
# duvarı kurallarını (NSG) tanımlar.
#
# NEDEN PROD ORTAMINDA BÖYLEDİR VS LAB ORTAMI (ZERO-TRUST & 3 PUBLIC IP KOTASI)?
# - Prod'da: Ağ; Public Subnet (Load Balancer / Bastion), Private App Subnet
#   (Kubernetes Worker'lar) ve Private Data Subnet (Veritabanları) olarak en az
#   3 katmana ayrılır. Veritabanı sunucularına (`vm-worker-data`) ASLA Public IP
#   verilmez; internete çıkışları yalnızca merkezi bir NAT Gateway ve Firewall
#   üzerinden tek yönlü (Outbound SNAT) yapılır.
# - Lab'da: Azure for Students aboneliğindeki 3 Public IP kotasını prod mimarisine
#   birebir sadık kalarak kullanıyoruz:
#     * Public IP #1 -> `vm-master` (10.30.1.4 - Control Plane, Ingress & SSH Bastion)
#     * Public IP #2 -> `vm-worker-app` (10.30.1.6 - Canlı Uygulama & RabbitMQ UI Ingress)
#     * Public IP #3 -> `NAT Gateway` (`vm-worker-data` 10.30.1.5 özel düğümünün
#       dışarıdan erişilemez şekilde konteyner imajlarını çekebilmesi için çıkış kapısı)
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Azure Kaynak Grubu (Resource Group)
# ------------------------------------------------------------------------------
# Azure'daki tüm kaynakların yaşam döngüsünü (oluşturma, etiketleme, yetkilendirme
# ve tek komutla silme) birlikte yönetmek için kullanılan mantıksal kapsayıcı.
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    project     = "resiliencestream-5"
    environment = "production-lab"
    managed_by  = "terraform"
  }
}

# ------------------------------------------------------------------------------
# 2. Sanal Ağ (Virtual Network - VNet) ve CIDR Matematiği (/16)
# ------------------------------------------------------------------------------
# CIDR (Classless Inter-Domain Routing) Matematiği:
# `10.30.0.0/16` -> IPv4 adresi 32 bitten oluşur. `/16` maskesi ilk 16 bitin (`10.30`)
# ağ kimliği (Network Prefix) olarak sabitlendiğini, kalan `32 - 16 = 16` bitin ise
# ev sahibi (Host) adresleri için serbest olduğunu gösterir.
# Toplam IP Kapasitesi: 2^16 = 65.536 adet özel (RFC 1918) IP adresi (`10.30.0.0` - `10.30.255.255`).
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-resiliencestream"
  address_space       = ["10.30.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    project = "resiliencestream-5"
  }
}

# ------------------------------------------------------------------------------
# 3. Alt Ağ (Subnet) ve CIDR Matematiği (/24)
# ------------------------------------------------------------------------------
# `10.30.1.0/24` -> VNet'imizin `/16` uzayından 256 IP'lik bir alt ağ kesiyoruz.
# ÖNEMLİ AZURE KURALI: Azure her alt ağda ilk 4 IP adresini ve son 1 IP adresini
# (toplam 5 IP) kendi iç altyapı servisleri için rezerve eder:
#   - `10.30.1.0`   : Ağ adresi (Network Address)
#   - `10.30.1.1`   : Varsayılan Ağ Geçidi (Default Gateway / Azure Router)
#   - `10.30.1.2`   : Azure DNS IP haritalaması
#   - `10.30.1.3`   : Azure DNS IP haritalaması
#   - `10.30.1.255` : Ağ yayın adresi (Broadcast Address)
# Bu yüzden sanal makinelerimize verebileceğimiz İLK kullanılabilir statik IP `10.30.1.4`'tür:
#   - `10.30.1.4` -> `vm-master`
#   - `10.30.1.5` -> `vm-worker-data`
#   - `10.30.1.6` -> `vm-worker-app`
resource "azurerm_subnet" "subnet" {
  name                 = "snet-k8s-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.30.1.0/24"]
}

# ------------------------------------------------------------------------------
# 4. NAT Gateway İçin Genel IP (Public IP #3 of 3)
# ------------------------------------------------------------------------------
# NAT Gateway'in çalışabilmesi için "Standard" SKU ve "Static" (sabit) bir Public IP
# zorunludur ("Basic" SKU veya "Dynamic" IP desteklenmez).
resource "azurerm_public_ip" "pip_natgw" {
  name                = "pip-resiliencestream-natgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "resiliencestream-5"
    quota_slot = "3-of-3-natgw"
  }
}

# ------------------------------------------------------------------------------
# 5. Azure NAT Gateway (Outbound SNAT İnternet Çıkış Kapısı)
# ------------------------------------------------------------------------------
# Neden NAT Gateway kullanıyoruz?
# Azure'da Public IP'si olmayan `vm-worker-data` (`10.30.1.5`) sanal makinesi
# varsayılan olarak internete çıkamaz. Ancak bu sunucunun:
#   - Ubuntu `apt-get update` paketlerini indirmesi,
#   - RKE2 sistem bileşenlerini kurması,
#   - Docker Hub (`bitnamilegacy/*`) kayıt defterinden Kafka, Cassandra ve PostgreSQL
#     konteyner imajlarını (Container Images) çekmesi (pull) gerekir!
# NAT Gateway, SNAT (Source Network Address Translation) teknolojisini kullanarak
# alt ağdaki özel veri sunucusunun `pip_natgw` üzerinden güvenli ve tek yönlü
# (sadece içeriden dışarıya - Outbound) internete çıkmasını sağlar.
resource "azurerm_nat_gateway" "natgw" {
  name                    = "natgw-resiliencestream"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = {
    project = "resiliencestream-5"
  }
}

# NAT Gateway ile Public IP #3'ü birbirine bağlıyoruz.
resource "azurerm_nat_gateway_public_ip_association" "natgw_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.natgw.id
  public_ip_address_id = azurerm_public_ip.pip_natgw.id
}

# NAT Gateway'i `snet-k8s-nodes` alt ağına bağlıyoruz. Böylece bu alt ağdaki
# Public IP'si olmayan `vm-worker-data` otomatik olarak NAT Gateway üzerinden internete çıkar.
resource "azurerm_subnet_nat_gateway_association" "subnet_natgw_assoc" {
  subnet_id      = azurerm_subnet.subnet.id
  nat_gateway_id = azurerm_nat_gateway.natgw.id
}

# ------------------------------------------------------------------------------
# 6. Ağ Güvenlik Grubu (Network Security Group - NSG / L4 Firewall)
# ------------------------------------------------------------------------------
# Alt ağımıza gelen ve giden trafiği OSI Katman 4 (TCP/UDP) seviyesinde filtreleyen
# durum bilgili (Stateful) güvenlik duvarı.
resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-resiliencestream-k8s"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # KURAL 1: SSH Erişimi (Port 22)
  # Sistem yöneticisinin ve Ansible otomasyonunun `vm-master` (Bastion/Jump Host)
  # üzerinden kümeyi yapılandırabilmesi için TCP 22 portuna izin veriyoruz.
  # Prod'da source_address_prefix yalnızca kurumsal VPN IP'si ile sınırlandırılır.
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

  # KURAL 2: Web / Ingress Trafiği (Port 80 HTTP & Port 443 HTTPS)
  # RKE2'nin yerleşik NGINX Ingress Controller'ı üzerinden Rancher UI, ArgoCD,
  # Grafana, Chaos Mesh Dashboard, RabbitMQ Management UI ve ResilienceStream
  # FastAPI uygulamasına tarayıcıdan erişebilmek için gereklidir.
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

  # KURAL 3: Kubernetes API Server (Port 6443)
  # RKE2'de Port 6443 vs Port 9345 Farkı Nedir?
  # - Port 6443 (Kubernetes API Server): Standart `kube-apiserver` portudur.
  #   `kubectl`, Helm, ArgoCD ve küme içi Kubelet ajanlarının Kubernetes nesnelerini
  #   (Pod, Deployment, Service, Chaos CRD vb.) sorgulamak ve yönetmek için konuştuğu ana kapıdır.
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

  # KURAL 4: RKE2 Supervisor API (Port 9345)
  # - Port 9345 (RKE2 Supervisor / Node Registration API): RKE2 mimarisine özgü çok
  #   kritik bir yönetim portudur. Yeni bir Worker düğümü (`rke2-agent`) kümeye ilk kez
  #   katılırken (Bootstrap), `/var/lib/rancher/rke2/server/node-token` içindeki gizli
  #   anahtarı kullanarak önce Master düğümün 9345 portuna bağlanır. Buradan TLS
  #   sertifikalarını ve küme yapılandırmasını aldıktan sonra 6443 portundaki API Server
  #   ile konuşmaya başlar. 9345 kapalıysa Worker düğümleri kümeye katılamaz!
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
    project = "resiliencestream-5"
  }
}

# NSG güvenlik duvarını doğrudan alt ağımıza (`snet-k8s-nodes`) bağlıyoruz.
resource "azurerm_subnet_network_security_group_association" "subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
