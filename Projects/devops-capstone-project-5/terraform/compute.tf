# ==============================================================================
# RESILIENCESTREAM ENTERPRISE PLATFORM - COMPUTE LAYER (3-NODE RKE2 CLUSTER)
# ==============================================================================
# Bu dosya (compute.tf), 3 düğümlü RKE2 Kubernetes kümemizi oluşturan sanal
# makineleri (1x Master `Standard_B2s_v2` + 2x Worker `Standard_B2s`), ağ
# kartlarını (NIC) ve genel IP (Public IP) atamalarını tanımlar.
#
# NEDEN PROD ORTAMINDA BÖYLEDİR VS LAB ORTAMI?
# 1. Düğüm Boyutlandırması (Right-Sizing):
#    - `vm-master` (`Standard_B2s_v2`: 2 vCPU / 8 GB RAM - `10.30.1.4` - Public IP #1):
#      RKE2 Control Plane (etcd, kube-apiserver, NGINX Ingress) + Rancher UI + ArgoCD +
#      Prometheus/Grafana/Alertmanager + Chaos Mesh Controller/Dashboard bileşenlerini
#      taşır. 8 GB RAM sayesinde yönetim düzlemi kaos deneyleri sırasında asla çökmez.
#    - `vm-worker-data` (`Standard_B2s`: 2 vCPU / 4 GB RAM - `10.30.1.5` - Özel IP, NAT GW):
#      Durum bilgili (stateful) veri katmanını (Kafka KRaft, Apache Cassandra, PostgreSQL)
#      taşır. `dedicated=data:NoSchedule` Taint'i ile uygulama pod'larından izole edilir.
#      Prod'da bu katman çoklu AZ'ye yayılmış ayrı sunucu havuzlarında çalışır.
#    - `vm-worker-app` (`Standard_B2s`: 2 vCPU / 4 GB RAM - `10.30.1.6` - Public IP #2):
#      Durumsuz (stateless) mikroservisleri (`order-api` x2, `analytics-consumer`,
#      `payment-worker`), mesajlaşma/önbellek katmanını (RabbitMQ, Redis) ve
#      Self-Hosted GitLab Runner'ı taşır.
# 2. `for_each` Kullanımı:
#    `count` yerine `for_each` kullanarak durum dosyasında (state) kaynakları
#    `vm_worker["vm-worker-data"]` ve `vm_worker["vm-worker-app"]` anahtarlarıyla
#    saklıyoruz; böylece indeks kayması olmadan güvenli topoloji yönetimi yapılır.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Yerel Değişkenler (Locals) - 2 Worker Düğümünün Topoloji Haritası
# ------------------------------------------------------------------------------
locals {
  workers = {
    # Düğüm 1: Veri Katmanı (Kafka KRaft + Apache Cassandra + PostgreSQL 16)
    # Public IP YOK -> NAT Gateway (Public IP #3) üzerinden güvenli çıkış yapar.
    "vm-worker-data" = {
      private_ip = "10.30.1.5"
      role       = "data"
    }
    # Düğüm 2: Uygulama, Mesajlaşma ve CI/CD Katmanı (FastAPI, RabbitMQ, Redis, GitLab Runner)
    # Public IP #2 -> Canlı uygulama ve RabbitMQ Management Ingress trafiğini karşılar.
    "vm-worker-app" = {
      private_ip = "10.30.1.6"
      role       = "app"
    }
  }
}

# ==============================================================================
# BÖLÜM A: KUBERNETES CONTROL PLANE (MASTER & BASTION NODE)
# ==============================================================================

# ------------------------------------------------------------------------------
# 2. Master Düğümü Genel IP Adresi (Public IP #1 of 3)
# ------------------------------------------------------------------------------
# Bu IP adresi iki kritik görev üstlenir:
#   a) SSH Bastion / Jump Host: Özel alt ağdaki `vm-worker-data` (10.30.1.5) düğümüne
#      Ansible ile SSH ProxyCommand üzerinden güvenli tünel açmak.
#   b) Yönetim Ingress Kapısı: Rancher, ArgoCD, Grafana ve Chaos Mesh Dashboard
#      arayüzlerini `*.<MASTER_IP>.nip.io` wildcard DNS üzerinden dış dünyaya sunmak.
resource "azurerm_public_ip" "pip_master" {
  name                = "pip-resiliencestream-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "resiliencestream-5"
    quota_slot = "1-of-3-master"
  }
}

# ------------------------------------------------------------------------------
# 3. Master Düğümü Ağ Kartı (Network Interface - NIC)
# ------------------------------------------------------------------------------
# Alt ağdaki ilk kullanılabilir IP olan `10.30.1.4` adresini Statik olarak atıyoruz.
# Control Plane IP'sinin değişmemesi, etcd küme sağlığı ve TLS sertifikalarının
# (SAN - Subject Alternative Name) geçerliliği için hayati önem taşır.
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
    project = "resiliencestream-5"
    role    = "control-plane"
  }
}

# ------------------------------------------------------------------------------
# 4. Master Sanal Makinesi (`vm-master` - Standard_B2s_v2 / 2 vCPU / 8 GB RAM)
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vm_master" {
  name                = "vm-master"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.master_vm_size
  admin_username      = var.admin_username

  # Güvenlik Sertleştirmesi: Parola ile girişi tamamen kapatıp yalnızca SSH anahtarı kabul ediyoruz.
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.nic_master.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  # etcd veritabanının düşük gecikmeli (Low Latency fsync/wal) yazma performansı ve
  # konteyner imajlarının hızlı açılması için 40 GB StandardSSD_LRS kullanıyoruz.
  os_disk {
    name                 = "osdisk-vm-master"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 40
  }

  # Ubuntu Server 24.04 LTS (Noble Numbat) - En güncel LTS Linux çekirdeği (Kernel 6.8).
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = {
    project = "resiliencestream-5"
    role    = "control-plane"
  }
}

# ==============================================================================
# BÖLÜM B: KUBERNETES WORKER NODES (2x İŞÇİ DÜĞÜMÜ - DATA & APP)
# ==============================================================================

# ------------------------------------------------------------------------------
# 5. Uygulama İşçi Düğümü Genel IP Adresi (Public IP #2 of 3)
# ------------------------------------------------------------------------------
# Öğrenci aboneliğimizdeki 2. Public IP hakkımızı `vm-worker-app` düğümüne
# veriyoruz. Böylece son kullanıcıların canlı uygulama trafiği (`app.<APP_IP>.nip.io`)
# ve RabbitMQ yönetim arayüzü (`rabbitmq.<APP_IP>.nip.io`) doğrudan uygulama
# düğümüne gelebilirken, `vm-worker-data` veritabanı düğümü tamamen gizli kalır.
resource "azurerm_public_ip" "pip_app" {
  name                = "pip-resiliencestream-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "resiliencestream-5"
    quota_slot = "2-of-3-app-worker"
  }
}

# ------------------------------------------------------------------------------
# 6. Worker Düğümleri Ağ Kartları (2x NIC - `for_each` & Ternary Operatörü)
# ------------------------------------------------------------------------------
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

    # KOŞULLU ÜÇLÜ İFADE (Conditional Ternary Expression):
    # Eğer şu an oluşturulan ağ kartı "vm-worker-app" düğümüne aitse `pip_app.id`
    # genel IP'sini bağla; "vm-worker-data" düğümüyse `null` ata (Public IP verme,
    # çıkışlarını NAT Gateway üzerinden yap!).
    public_ip_address_id = each.key == "vm-worker-app" ? azurerm_public_ip.pip_app.id : null
  }

  tags = {
    project = "resiliencestream-5"
    role    = each.value.role
  }
}

# ------------------------------------------------------------------------------
# 7. Worker Sanal Makineleri (2x `Standard_B2s` / 2 vCPU / 4 GB RAM)
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vm_worker" {
  for_each = local.workers

  name                = each.key
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.worker_vm_size
  admin_username      = var.admin_username

  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.nic_worker[each.key].id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  # Kafka log segmentleri, Cassandra SSTable/CommitLog dosyaları, PostgreSQL WAL
  # dosyaları ve RabbitMQ quorum kuyrukları için 40 GB StandardSSD_LRS disk tahsis ediyoruz.
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
    project = "resiliencestream-5"
    role    = each.value.role
  }
}
