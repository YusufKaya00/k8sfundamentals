output "master_public_ip" {
  value       = azurerm_public_ip.pip_master.ip_address
  description = "RKE2 Master Public IP (Rancher Dashboard ve SSH)"
}

output "worker_public_ips" {
  value = { for k, v in azurerm_public_ip.pip_worker : k => v.ip_address }
  description = "Worker Node Public IP'leri"
}

output "app_worker_public_ip" {
  value       = azurerm_public_ip.pip_worker["vm-worker-app"].ip_address
  description = "Web App ve Ingress Public IP'si"
}

# Ansible Inventory Dosyasını Otomatik Üret
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<EOF
[master]
vm-master ansible_host=${azurerm_public_ip.pip_master.ip_address} private_ip=10.10.1.4

[workers]
vm-worker-infra ansible_host=${azurerm_public_ip.pip_worker["vm-worker-infra"].ip_address} private_ip=10.10.1.5 tier=infra taint=dedicated=infra:NoSchedule
vm-worker-pg    ansible_host=${azurerm_public_ip.pip_worker["vm-worker-pg"].ip_address} private_ip=10.10.1.6 tier=db-sql taint=dedicated=db-sql:NoSchedule
vm-worker-mongo ansible_host=${azurerm_public_ip.pip_worker["vm-worker-mongo"].ip_address} private_ip=10.10.1.7 tier=db-nosql taint=dedicated=db-nosql:NoSchedule
vm-worker-app   ansible_host=${azurerm_public_ip.pip_worker["vm-worker-app"].ip_address} private_ip=10.10.1.8 tier=app taint=none

[k8s_cluster:children]
master
workers

[all:vars]
ansible_user=${var.admin_username}
ansible_ssh_private_key_file=../terraform/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
master_private_ip=10.10.1.4
master_public_ip=${azurerm_public_ip.pip_master.ip_address}
app_worker_public_ip=${azurerm_public_ip.pip_worker["vm-worker-app"].ip_address}
EOF
}
