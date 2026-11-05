#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS LAB 4 — SECRET ROTATION SENARYO YARDIMCISI (rotate-secret.sh)
# ==============================================================================
# SENARYO T8: Secret Rotation Desenkronizasyonu Simülatörü
# Bu betik:
# 1. `resiliencestream-credentials` Secret'ındaki şifreleri döndürür (rotate).
# 2. Pod'ların yeniden başlamadığını (çünkü checksum/secret annotation'ı eksiktir)
#    ve dolayısıyla eski bellekteki şifreyle çalışmaya devam ettiğini gösterir.
# 3. Bir pod restart edildiğinde veya scale edildiğinde ortaya çıkan kimlik doğrulama
#    hatasını (ACCESS_REFUSED / Split-Brain) kanıtlar.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
elif [[ -f "${LAB_DIR}/ansible/hosts.ini" ]]; then
  MASTER_IP="$(awk -F'master_public_ip=' '/^master_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | head -n1 | tr -d '[:space:]')"
fi
MASTER_IP="${MASTER_IP:-9.205.250.156}"

run_k8s() {
  if [[ "$(hostname)" == "vm-master" ]]; then
    sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:$PATH" bash -c "$1"
  else
    ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=/var/lib/rancher/rke2/bin:/usr/local/bin:\$PATH $1"
  fi
}

ACTION="${1:-rotate}"

case "${ACTION}" in
  rotate)
    NEW_PASS="RotatedSecret$(date +%s)"
    echo "-> resiliencestream-credentials Secret'ı yeni şifreyle güncelleniyor: ${NEW_PASS}..."
    run_k8s "kubectl create secret generic resiliencestream-credentials \
      --namespace app \
      --from-literal=POSTGRES_PASSWORD=${NEW_PASS} \
      --from-literal=RABBITMQ_PASSWORD=${NEW_PASS} \
      --from-literal=REDIS_PASSWORD=${NEW_PASS} \
      --from-literal=CASSANDRA_PASSWORD=${NEW_PASS} \
      --dry-run=client -o yaml | kubectl apply -f -"
    
    echo "✅ Secret başarıyla güncellendi!"
    echo "⚠️  DİKKAT EDİN: Pod'ların yaşını (AGE) ve restart sayısını kontrol edin:"
    run_k8s "kubectl get pods -n app -l app.kubernetes.io/component=order-api"
    echo ""
    echo "Gördüğünüz gibi Pod'lar YENİDEN BAŞLAMADI! Eski şifreyle çalışmaya devam ediyorlar."
    echo "Şimdi bir pod'u manuel öldürün veya scale edin:"
    echo "  kubectl delete pod -n app -l app.kubernetes.io/component=order-api --wait=false"
    echo "Yeni başlayan pod yeni şifreyi alacak ve eski çalışan podlarla split-brain yaşanacaktır!"
    ;;
  restore)
    ORIG_PASS="AdminPassword2026!"
    echo "-> resiliencestream-credentials Secret'ı orijinal şifreye döndürülüyor: ${ORIG_PASS}..."
    run_k8s "kubectl create secret generic resiliencestream-credentials \
      --namespace app \
      --from-literal=POSTGRES_PASSWORD=${ORIG_PASS} \
      --from-literal=RABBITMQ_PASSWORD=${ORIG_PASS} \
      --from-literal=REDIS_PASSWORD=${ORIG_PASS} \
      --from-literal=CASSANDRA_PASSWORD=${ORIG_PASS} \
      --dry-run=client -o yaml | kubectl apply -f -"
    run_k8s "kubectl rollout restart deployment order-api analytics-consumer payment-worker -n app"
    echo "✅ Orijinal şifre yüklendi ve podlar yeniden başlatıldı."
    ;;
  *)
    echo "Kullanım: $0 [rotate|restore]"
    exit 1
    ;;
esac
