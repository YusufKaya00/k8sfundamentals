

#!/bin/bash
set -e
echo "=== 1. Terraform ile Altyapı Ayağa Kaldırılıyor ==="
terraform apply -auto-approve
echo "=== 2. Sunucunun SSH Servisinin Oturması İçin 15 Saniye Bekleniyor ==="
sleep 15
echo "=== 3. Ansible ile Kubernetes Kurulumu Başlatılıyor ==="
ansible-playbook setup.yml
echo "=== Kurulum Tamamlandı! Sunucuya Bağlanmak İçin: ==="
echo "ssh -i user azureuser@$(terraform output -raw public_ip_address)"