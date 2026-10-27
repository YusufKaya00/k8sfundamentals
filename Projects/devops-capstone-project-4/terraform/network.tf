# ==============================================================================
# OMNISTREAM ENTERPRISE PLATFORM - NETWORKING & SECURITY (AĞ VE GÜVENLİK)
# ==============================================================================
# Bu dosya (network.tf), 5 düğümlü RKE2 Kubernetes kümemizin üzerinde çalışacağı
# izole bulut ağını (VNet), alt ağını (Subnet), dış dünyaya güvenli çıkış kapısını
# (NAT Gateway) ve durum bilgili güvenlik duvarı kurallarını (NSG) tanımlar.
#
# NEDEN DATABASE VE KAFKA DÜĞÜMLERİNİN PUBLIC IP'Sİ YOK? (ZERO-TRUST & QUOTA):
# 1. Güvenlik (Zero-Trust Architecture): Gerçek dünya üretim (Production) ortamlarında
#    PostgreSQL, MongoDB, Redis ve Apache Kafka çalıştıran veri düğümlerine ASLA
#    Public IP verilmez. Bu düğümler doğrudan internete açılırsa saniyeler içinde
#    botnet taramalarına ve brute-force saldırılarına hedef olurlar.
# 2. Kota Sınırı (Azure for Students 3 Public IP Limit): Öğrenci aboneliğinde bölge
#    başına yalnızca 3 adet Public IP hakkımız vardır:
#      - Public IP #1 -> NAT Gateway (Tüm özel düğümlerin internete çıkış kapısı)
#      - Public IP #2 -> vm-master (Rancher, ArgoCD, Grafana Ingress & SSH Bastion)
#      - Public IP #3 -> vm-worker-app (Canlı Uygulama Trafiği)
#    Geriye kalan 3 veri düğümü (`vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`)
#    tamamen Private IP ile çalışır ve dış dünyadan izoledir.
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
    project     = "omnistream-capstone-4"
    environment = "production"
    managed_by  = "terraform"
  }
}

# ------------------------------------------------------------------------------
# 2. Sanal Ağ (Virtual Network - VNet) ve CIDR Matematiği (/16)
# ------------------------------------------------------------------------------
# CIDR (Classless Inter-Domain Routing) Matematiği:
# `10.20.0.0/16` -> IPv4 adresi 32 bitten oluşur. `/16` maskesi ilk 16 bitin (`10.20`)
# ağ kimliği (Network Prefix) olarak sabitlendiğini, kalan `32 - 16 = 16` bitin ise
# ev sahibi (Host) adresleri için serbest olduğunu gösterir.
# Toplam IP Kapasitesi: 2^16 = 65.536 adet özel (RFC 1918) IP adresi (`10.20.0.0` - `10.20.255.255`).
# Bu geniş adres uzayı, gelecekte yeni alt ağlar (Subnets) eklemek için esneklik sağlar.
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-omnistream"
  address_space       = ["10.20.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  tags = {
    project = "omnistream-capstone-4"
  }
}

# ------------------------------------------------------------------------------
# 3. Alt Ağ (Subnet) ve CIDR Matematiği (/24)
# ------------------------------------------------------------------------------
# `10.20.1.0/24` -> VNet'imizin `/16` uzayından daha küçük bir dilim kesiyoruz.
# İlk 24 bit (`10.20.1`) sabitlenir, geriye `32 - 24 = 8` bit kalır.
# Toplam IP Kapasitesi: 2^8 = 256 adet IP adresi (`10.20.1.0` - `10.20.1.255`).
# ÖNEMLİ AZURE KURALI: Azure her alt ağda ilk 4 IP adresini ve son 1 IP adresini
# (toplam 5 IP) kendi iç altyapı servisleri için rezerve eder:
#   - `10.20.1.0`   : Ağ adresi (Network Address)
#   - `10.20.1.1`   : Varsayılan Ağ Geçidi (Default Gateway / Azure Router)
#   - `10.20.1.2`   : Azure DNS IP haritalaması
#   - `10.20.1.3`   : Azure DNS IP haritalaması
#   - `10.20.1.255` : Ağ yayın adresi (Broadcast Address)
# Bu yüzden sanal makinelerimize verebileceğimiz İLK kullanılabilir statik IP `10.20.1.4`'tür!
resource "azurerm_subnet" "subnet" {
  name                 = "snet-k8s-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.20.1.0/24"]
}

# ------------------------------------------------------------------------------
# 4. NAT Gateway İçin Genel IP (Public IP #1 of 3)
# ------------------------------------------------------------------------------
# NAT Gateway'in çalışabilmesi için "Standard" SKU ve "Static" (sabit) bir Public IP
# zorunludur ("Basic" SKU veya "Dynamic" IP desteklenmez).
resource "azurerm_public_ip" "pip_natgw" {
  name                = "pip-omnistream-natgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "omnistream-capstone-4"
    quota_slot = "1-of-3-natgw"
  }
}

# ------------------------------------------------------------------------------
# 5. Azure NAT Gateway (Outbound SNAT İnternet Çıkış Kapısı)
# ------------------------------------------------------------------------------
# Neden NAT Gateway kullanıyoruz?
# Azure'da Public IP'si olmayan sanal makineler (`vm-worker-stream`, `vm-worker-sql`,
# `vm-worker-nosql`) varsayılan olarak internete çıkamazlar. Ancak bu sunucuların:
#   - Ubuntu `apt-get update` paketlerini indirmesi,
#   - RKE2 sistem bileşenlerini kurması,
#   - Docker Hub / Bitnami / Quay.io kayıt defterlerinden Kafka, Redis, PostgreSQL
#     ve MongoDB konteyner imajlarını (Container Images) çekmesi (pull) gerekir!
# NAT Gateway, SNAT (Source Network Address Translation) teknolojisini kullanarak
# alt ağdaki tüm özel sunucuların tek bir statik Public IP (`pip_natgw`) üzerinden
# güvenli ve tek yönlü (sadece içeriden dışarıya - Outbound) internete çıkmasını sağlar.
# Dışarıdan içeriye (Inbound) ise hiçbir bağlantı kabul etmez!
resource "azurerm_nat_gateway" "natgw" {
  name                    = "natgw-omnistream"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10

  tags = {
    project = "omnistream-capstone-4"
  }
}

# NAT Gateway ile Public IP #1'i birbirine bağlıyoruz.
resource "azurerm_nat_gateway_public_ip_association" "natgw_pip_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.natgw.id
  public_ip_address_id = azurerm_public_ip.pip_natgw.id
}

# NAT Gateway'i `snet-k8s-nodes` alt ağına bağlıyoruz. Böylece bu alt ağdaki
# Public IP'si olmayan tüm sunucular otomatik olarak NAT Gateway üzerinden internete çıkar.
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
  name                = "nsg-omnistream-k8s"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # KURAL 1: SSH Erişimi (Port 22)
  # Sistem yöneticisinin ve Ansible otomasyonunun `vm-master` (Bastion/Jump Host)
  # üzerinden kümeyi yapılandırabilmesi için TCP 22 portuna izin veriyoruz.
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
  # Grafana ve OmniStream FastAPI uygulamasına tarayıcıdan erişebilmek için gereklidir.
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
  #   (Pod, Deployment, Service vb.) sorgulamak ve yönetmek için konuştuğu ana kapıdır.
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
    project = "omnistream-capstone-4"
  }
}

# NSG güvenlik duvarını doğrudan alt ağımıza (`snet-k8s-nodes`) bağlıyoruz.
# Tek tek her NIC (ağ kartı) için NSG oluşturmak yerine alt ağ seviyesinde bağlamak
# merkezi güvenlik yönetimi sağlar.
resource "azurerm_subnet_network_security_group_association" "subnet_nsg_assoc" {
  subnet_id                 = azurerm_subnet.subnet.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}
