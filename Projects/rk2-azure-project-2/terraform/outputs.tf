output "master_public_ip" {
  value       = azurerm_public_ip.pip_master.ip_address
  description = "RKE2 Master Public IP (SSH Bastion & Yönetim)"
}

output "app_worker_public_ip" {
  value       = azurerm_public_ip.pip_app.ip_address
  description = "Web App ve Rancher Dashboard Ingress Public IP'si"
}

# Ansible Inventory Dosyasını Otomatik Üret
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<EOF
[master]
vm-master ansible_host=${azurerm_public_ip.pip_master.ip_address} private_ip=10.10.1.4

[workers]
vm-worker-infra ansible_host=10.10.1.5 private_ip=10.10.1.5 tier=infra taint=dedicated=infra:NoSchedule
vm-worker-pg    ansible_host=10.10.1.6 private_ip=10.10.1.6 tier=db-sql taint=dedicated=db-sql:NoSchedule
vm-worker-mongo ansible_host=10.10.1.7 private_ip=10.10.1.7 tier=db-nosql taint=dedicated=db-nosql:NoSchedule
vm-worker-app   ansible_host=10.10.1.8 private_ip=10.10.1.8 tier=app taint=none

[k8s_cluster:children]
master
workers

[all:vars]
ansible_user=${var.admin_username}
ansible_ssh_private_key_file=../terraform/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
master_private_ip=10.10.1.4
master_public_ip=${azurerm_public_ip.pip_master.ip_address}
app_worker_public_ip=${azurerm_public_ip.pip_app.ip_address}

# Private Worker'lara Master (Bastion) Üzerinden ProxyJump ile Bağlan
[workers:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ProxyJump=${var.admin_username}@${azurerm_public_ip.pip_master.ip_address}'
EOF
}
