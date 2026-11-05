# ==============================================================================
# CHAOS & TROUBLESHOOTING LAB 1 - OUTPUTS & DYNAMIC ANSIBLE INVENTORY
# ==============================================================================
# Bu dosya:
# 1. `../ansible/hosts.ini` envanter dosyasını otomatik üretir.
# 2. `../scripts/.lab-env` dosyasını üretir (setup-lab.sh ve check-system.sh
#    betiklerinin yeni Azure Public IP adreslerini otomatik tanıması için).
# ==============================================================================

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    master_public_ip     = azurerm_public_ip.pip_master.ip_address
    app_public_ip        = azurerm_public_ip.pip_app.ip_address
    app_worker_public_ip = azurerm_public_ip.pip_app.ip_address
    admin_username       = var.admin_username
    workers              = local.workers
  })

  filename        = "${path.module}/../ansible/hosts.ini"
  file_permission = "0644"

  depends_on = [
    azurerm_linux_virtual_machine.vm_master,
    azurerm_linux_virtual_machine.vm_worker
  ]
}

resource "local_file" "lab_env" {
  content         = <<-EOT
    MASTER_IP="${azurerm_public_ip.pip_master.ip_address}"
    APP_IP="${azurerm_public_ip.pip_app.ip_address}"
  EOT
  filename        = "${path.module}/../scripts/.lab-env"
  file_permission = "0644"

  depends_on = [
    azurerm_linux_virtual_machine.vm_master,
    azurerm_linux_virtual_machine.vm_worker
  ]
}

output "master_public_ip" {
  description = "vm-master (RKE2 Control Plane, Chaos Mesh/Grafana Ingress & SSH Bastion) Genel IP adresi."
  value       = azurerm_public_ip.pip_master.ip_address
}

output "app_worker_public_ip" {
  description = "vm-worker-app (ResilienceStream FastAPI, RabbitMQ, Redis) Genel IP adresi."
  value       = azurerm_public_ip.pip_app.ip_address
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway (vm-worker-data özel veri düğümünün güvenli Outbound SNAT çıkış IP'si)."
  value       = azurerm_public_ip.pip_natgw.ip_address
}

output "chaos_mesh_url" {
  description = "Chaos Mesh Kaos Mühendisliği Deney Yönetim Paneli."
  value       = "http://chaos.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "grafana_url" {
  description = "Grafana & Prometheus SLO Gözlemlenebilirlik Panosu."
  value       = "http://grafana.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "app_url" {
  description = "ResilienceStream Canlı Sipariş API ve Durum Uç Noktası."
  value       = "http://app.${azurerm_public_ip.pip_app.ip_address}.nip.io/api/status"
}

output "rabbitmq_url" {
  description = "RabbitMQ Management & Dead-Letter Queue (DLQ) İzleme Paneli."
  value       = "http://rabbitmq.${azurerm_public_ip.pip_app.ip_address}.nip.io"
}
