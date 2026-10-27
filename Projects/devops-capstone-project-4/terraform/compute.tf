# ==============================================================================
# OMNISTREAM ENTERPRISE PLATFORM - COMPUTE LAYER (5-NODE RKE2 CLUSTER)
# ==============================================================================
# Bu dosya (compute.tf), 5 düğümlü RKE2 Kubernetes kümemizi oluşturan sanal
# makineleri (1x Master + 4x Worker), ağ kartlarını (NIC) ve genel IP (Public IP)
# atamalarını tanımlar.
#
# MİMARİ TASARIM KARARLARI:
# 1. Neden `vm-master` 8 GB RAM (`Standard_B2s_v2`) alırken Worker'lar 2 GB RAM (`Standard_B1ms`) alıyor?
#    - `vm-master` düğümü üzerinde hem RKE2 Control Plane (etcd, kube-apiserver,
#      kube-controller-manager, kube-scheduler, NGINX Ingress) hem de kurumsal yönetim
#      araçlarımız (Rancher UI, ArgoCD, Prometheus TSDB ve Grafana) çalışmaktadır.
#      Bu bileşenlerin toplam bellek ayak izi ~4.5 - 5.5 GB civarındadır; 8 GB RAM ile
#      sıfır OOM (Out-Of-Memory) riskiyle kararlı çalışır.
#    - 4 adet Worker düğümümüz (`vm-worker-stream`, `vm-worker-sql`, `vm-worker-nosql`,
#      `vm-worker-app`) ise Kubernetes Taint/Toleration ve NodeSelector mekanizmalarıyla
#      birbirinden tamamen izole edilmiştir. Her bir Worker yalnızca kendi uzmanlık
#      alanındaki tekil veri/uygulama katmanını çalıştırdığı için 2 GB RAM (1 vCPU)
#      üretim yükünü rahatlıkla taşır ve 6 vCPU öğrenci kotasına (%100) tam uyum sağlar.
#
# 2. Neden `count` yerine `for_each` ve `locals` kullanıyoruz?
#    - `count` kullanıldığında kaynaklar dizi indeksiyle (`vm_worker[0]`, `vm_worker[1]`)
#      tutulur. Ortadaki bir sunucuyu listeden silerseniz indeksler kayar ve Terraform
#      sağlam çalışan veritabanı sunucularınızı bile silip baştan oluşturmaya çalışır!
#    - `for_each` ise kaynakları anlamlı anahtar isimleriyle (`vm_worker["vm-worker-sql"]`)
#      Durum Dosyasında (State File) saklar. İstediğiniz düğümü diğerlerine dokunmadan
#      güvenle güncelleyebilir veya kaldırabilirsiniz.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Yerel Değişkenler (Locals) - 4 Worker Düğümünün Topoloji Haritası
# ------------------------------------------------------------------------------
# `locals` bloğu, dışarıdan parametre olarak değiştirilmesi gerekmeyen ancak kod
# içinde tekrar tekrar başvurulan sabit veri yapılarını (Map/Object) merkezi olarak
# tanımlamamıza olanak tanır (DRY - Don't Repeat Yourself prensibi).
locals {
  workers = {
    # Düğüm 1: Olay Akışı ve Önbellek Katmanı (Apache Kafka KRaft + Redis 7)
    "vm-worker-stream" = {
      private_ip = "10.20.1.5"
      role       = "stream"
    }
    # Düğüm 2: İlişkisel Veritabanı Katmanı (PostgreSQL 16)
    "vm-worker-sql" = {
      private_ip = "10.20.1.6"
      role       = "db-sql"
    }
    # Düğüm 3: Doküman Tabanlı NoSQL Veritabanı Katmanı (MongoDB 7)
    "vm-worker-nosql" = {
      private_ip = "10.20.1.7"
      role       = "db-nosql"
    }
    # Düğüm 4: Uygulama ve DevSecOps CI/CD Katmanı (FastAPI App + GitLab Runner)
    "vm-worker-app" = {
      private_ip = "10.20.1.8"
      role       = "app"
    }
  }
}

# ==============================================================================
# BÖLÜM A: KUBERNETES CONTROL PLANE (MASTER & BASTION NODE)
# ==============================================================================

# ------------------------------------------------------------------------------
# 2. Master Düğümü Genel IP Adresi (Public IP #2 of 3)
# ------------------------------------------------------------------------------
# Bu IP adresi iki kritik görev üstlenir:
#   a) SSH Bastion / Jump Host: Özel alt ağdaki 4 Worker düğümüne Ansible ile
#      SSH ProxyCommand üzerinden güvenli tünel açmak.
#   b) Yönetim Ingress Kapısı: Rancher, ArgoCD ve Grafana arayüzlerini `nip.io`
#      wildcard DNS üzerinden dış dünyaya sunmak.
resource "azurerm_public_ip" "pip_master" {
  name                = "pip-omnistream-master"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "omnistream-capstone-4"
    quota_slot = "2-of-3-master"
  }
}

# ------------------------------------------------------------------------------
# 3. Master Düğümü Ağ Kartı (Network Interface - NIC)
# ------------------------------------------------------------------------------
# Alt ağdaki ilk kullanılabilir IP olan `10.20.1.4` adresini Statik olarak atıyoruz.
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
    private_ip_address            = "10.20.1.4"
    public_ip_address_id          = azurerm_public_ip.pip_master.id
  }

  tags = {
    project = "omnistream-capstone-4"
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

  # `pathexpand()` fonksiyonu "~/.ssh/id_rsa.pub" içindeki "~" karakterini yerel kullanıcı
  # ev dizinine (/home/ysf/.ssh/id_rsa.pub) genişletir, `file()` ise anahtar içeriğini okur.
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
    project = "omnistream-capstone-4"
    role    = "control-plane"
  }
}

# ==============================================================================
# BÖLÜM B: KUBERNETES WORKER NODES (4x IZOLASYONLU İŞÇİ DÜĞÜMÜ)
# ==============================================================================

# ------------------------------------------------------------------------------
# 5. Uygulama İşçi Düğümü Genel IP Adresi (Public IP #3 of 3)
# ------------------------------------------------------------------------------
# Öğrenci aboneliğimizdeki 3. ve SON Public IP hakkımızı `vm-worker-app` düğümüne
# veriyoruz. Böylece son kullanıcıların canlı uygulama trafiği (`app.<APP_IP>.nip.io`)
# doğrudan uygulama düğümüne gelebilirken, veritabanı düğümleri gizli kalır.
resource "azurerm_public_ip" "pip_app" {
  name                = "pip-omnistream-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    project    = "omnistream-capstone-4"
    quota_slot = "3-of-3-app-worker"
  }
}

# ------------------------------------------------------------------------------
# 6. Worker Düğümleri Ağ Kartları (4x NIC - `for_each` & Ternary Operatörü)
# ------------------------------------------------------------------------------
resource "azurerm_network_interface" "nic_worker" {
  # `local.workers` haritasındaki 4 eleman için döngü kurar.
  # `each.key`   -> Düğüm adı (ör. "vm-worker-stream", "vm-worker-app")
  # `each.value` -> Özellik nesnesi (`{ private_ip = "10.20.1.x", role = "..." }`)
  for_each = local.workers

  name                = "nic-${each.key}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip

    # KOŞULLU ÜÇLÜ İFADE (Conditional Ternary Expression: `KOŞUL ? DOĞRUYSA : YANLIŞSA`):
    # Eğer şu an oluşturulan ağ kartı "vm-worker-app" düğümüne aitse `pip_app.id`
    # genel IP'sini bağla; diğer 3 veri düğümünden biriyse (`stream`, `sql`, `nosql`)
    # `null` ata (yani hiçbir Public IP bağlama, tamamen Private bırak!).
    public_ip_address_id = each.key == "vm-worker-app" ? azurerm_public_ip.pip_app.id : null
  }

  tags = {
    project = "omnistream-capstone-4"
    role    = each.value.role
  }
}

# ------------------------------------------------------------------------------
# 7. Worker Sanal Makineleri (4x `Standard_B1ms` / 1 vCPU / 2 GB RAM)
# ------------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vm_worker" {
  for_each = local.workers

  name                = each.key
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.worker_vm_size
  admin_username      = var.admin_username

  disable_password_authentication = true

  # İlgili Worker'ın kendi NIC'ini (`azurerm_network_interface.nic_worker[each.key]`) bağlıyoruz.
  network_interface_ids = [
    azurerm_network_interface.nic_worker[each.key].id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  # Kafka log segmentleri, PostgreSQL WAL dosyaları ve MongoDB WiredTiger depolama
  # motoru için 30 GB StandardSSD_LRS disk tahsis ediyoruz.
  os_disk {
    name                 = "osdisk-${each.key}"
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

  tags = {
    project = "omnistream-capstone-4"
    role    = each.value.role
  }
}
