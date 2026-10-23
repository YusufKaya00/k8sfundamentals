output "master_public_ip" {
  description = "Rancher Dashboard & Master Sunucusu Public IP"
  value       = azurerm_public_ip.pip_master.ip_address
}

output "app_worker_public_ip" {
  description = "Kullanıcı Web Uygulaması (Ingress) Public IP"
  value       = azurerm_public_ip.pip_app.ip_address
}

output "nat_gateway_public_ip" {
  description = "Worker Sunucularının Dışarı Çıkış Public IP (NAT Gateway)"
  value       = azurerm_public_ip.pip_natgw.ip_address
}

output "rancher_url" {
  description = "Rancher Dashboard Web Arayüz Linki"
  value       = "https://rancher.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "app_url" {
  description = "Multi-Tier Web Uygulama Linki"
  value       = "http://app.${azurerm_public_ip.pip_app.ip_address}.nip.io"
}

# 1. Otomatik Ansible Inventory (hosts.ini) Üretimi
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/hosts.tpl", {
    master_ip          = azurerm_public_ip.pip_master.ip_address
    app_worker_ip      = azurerm_public_ip.pip_app.ip_address
    admin_user         = var.admin_username
    ssh_key_path       = pathexpand(var.ssh_public_key_path)
  })
  filename = "${path.module}/../ansible/hosts.ini"
}

# 2. Otomatik ~/.ssh/config İçeriği
resource "local_file" "ssh_config_snippet" {
  content = <<-EOT
# ==========================================
# Proje 3 (Rancher UI Lab) SSH Konfigürasyonu
# ==========================================
Host vm-master ${azurerm_public_ip.pip_master.ip_address}
    HostName ${azurerm_public_ip.pip_master.ip_address}
    User ${var.admin_username}
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new

Host vm-worker-app ${azurerm_public_ip.pip_app.ip_address}
    HostName ${azurerm_public_ip.pip_app.ip_address}
    User ${var.admin_username}
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new

Host vm-worker-infra 10.10.1.5
    HostName 10.10.1.5
    User ${var.admin_username}
    ProxyJump vm-master
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new

Host vm-worker-pg 10.10.1.6
    HostName 10.10.1.6
    User ${var.admin_username}
    ProxyJump vm-master
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new

Host vm-worker-mongo 10.10.1.7
    HostName 10.10.1.7
    User ${var.admin_username}
    ProxyJump vm-master
    IdentityFile ~/.ssh/id_rsa
    StrictHostKeyChecking accept-new
EOT
  filename = "${path.module}/../ssh-config.txt"
}
