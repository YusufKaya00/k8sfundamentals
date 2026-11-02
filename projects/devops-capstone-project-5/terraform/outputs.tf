# ==============================================================================
# RESILIENCESTREAM ENTERPRISE PLATFORM - OUTPUTS & DYNAMIC ANSIBLE INVENTORY
# ==============================================================================
# Bu dosya (outputs.tf), iki kritik görevi yerine getirir:
# 1. Zero-Touch IaC -> Configuration Management Köprüsü:
#    Azure üzerinde dinamik olarak tahsis edilen Public IP adreslerini ve yerel
#    Worker topolojisini (`local.workers`) alarak `templates/hosts.ini.tftpl`
#    şablonunu işler ve doğrudan `../ansible/hosts.ini` dosyasını üretir.
#    Böylece `terraform apply` biter bitmez hiçbir IP kopyala-yapıştır işlemine
#    gerek kalmadan `ansible-playbook site.yml` çalıştırılabilir!
# 2. Platform Erişim Çıktıları (Outputs):
#    Rancher UI, ArgoCD, Grafana, Chaos Mesh, RabbitMQ Management ve
#    ResilienceStream Canlı Uygulama adreslerini `nip.io` wildcard DNS
#    formatında terminale yazdırır.
#
# NEDEN PROD ORTAMINDA BÖYLEDİR VS LAB ORTAMI?
# - Prod'da: Terraform çıktılarını ExternalDNS + Cloudflare / Azure DNS Zone
#   ile gerçek kurumsal alan adlarına (`chaos.sirket.com`) bağlarız.
# - Lab'da: Ücretsiz ve anında çalışan `nip.io` wildcard DNS kullanarak gerçek
#   Host-tabanlı NGINX Ingress yönlendirmesini DNS satın almadan simüle ediyoruz.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Dinamik Ansible Envanter Dosyası Üretimi (`../ansible/hosts.ini`)
# ------------------------------------------------------------------------------
resource "local_file" "ansible_inventory" {
  # `templatefile(path, vars)` fonksiyonu, `.tftpl` şablon dosyasını okur ve
  # ikinci argümandaki değişken haritasını şablonun içine enjekte eder.
  content = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    master_public_ip     = azurerm_public_ip.pip_master.ip_address
    app_public_ip        = azurerm_public_ip.pip_app.ip_address
    app_worker_public_ip = azurerm_public_ip.pip_app.ip_address
    admin_username       = var.admin_username
    workers              = local.workers
  })

  # Terraform dizininden bir üst dizine çıkıp `ansible/hosts.ini` konumuna yazar.
  filename        = "${path.module}/../ansible/hosts.ini"
  file_permission = "0644"

  # Envanter dosyasının yalnızca tüm sanal makineler hazır olduğunda yazılmasını garanti eder.
  depends_on = [
    azurerm_linux_virtual_machine.vm_master,
    azurerm_linux_virtual_machine.vm_worker
  ]
}

# ------------------------------------------------------------------------------
# 2. Altyapı Genel IP Çıktıları (Public IP Outputs)
# ------------------------------------------------------------------------------
output "master_public_ip" {
  description = "vm-master (RKE2 Control Plane, Management Ingress & SSH Bastion) Genel IP adresi (Public IP #1)."
  value       = azurerm_public_ip.pip_master.ip_address
}

output "app_worker_public_ip" {
  description = "vm-worker-app (ResilienceStream FastAPI, RabbitMQ, Redis & GitLab Runner) Genel IP adresi (Public IP #2)."
  value       = azurerm_public_ip.pip_app.ip_address
}

output "nat_gateway_public_ip" {
  description = "NAT Gateway (vm-worker-data özel veri düğümünün güvenli Outbound SNAT çıkış IP'si - Public IP #3)."
  value       = azurerm_public_ip.pip_natgw.ip_address
}

# ------------------------------------------------------------------------------
# 3. Kurumsal Yönetim, Kaos ve Gözlemlenebilirlik URL Çıktıları (`nip.io`)
# ------------------------------------------------------------------------------
output "rancher_url" {
  description = "Rancher Çoklu Küme Yönetim Arayüzü (cattle-system) erişim adresi."
  value       = "https://rancher.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "argocd_url" {
  description = "ArgoCD GitOps Sürekli Teslimat (Continuous Delivery) Arayüzü erişim adresi."
  value       = "http://argocd.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "grafana_url" {
  description = "Grafana & Prometheus SLO Gözlemlenebilirlik Panosu erişim adresi."
  value       = "http://grafana.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "chaos_mesh_url" {
  description = "Chaos Mesh Kaos Mühendisliği Deney ve Game Day Yönetim Paneli erişim adresi."
  value       = "http://chaos.${azurerm_public_ip.pip_master.ip_address}.nip.io"
}

output "app_url" {
  description = "ResilienceStream Canlı Sipariş API ve Kaos Gözlem Arayüzü."
  value       = "http://app.${azurerm_public_ip.pip_app.ip_address}.nip.io"
}

output "rabbitmq_url" {
  description = "RabbitMQ Management & Dead-Letter Queue (DLQ) İzleme Paneli erişim adresi."
  value       = "http://rabbitmq.${azurerm_public_ip.pip_app.ip_address}.nip.io"
}
