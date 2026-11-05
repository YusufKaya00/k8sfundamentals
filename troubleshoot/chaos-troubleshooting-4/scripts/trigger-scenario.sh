#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 4 — SENARYO TETİKLEYİCİ BETİK (trigger-scenario.sh)
# ==============================================================================
# Bu betik, kullanıcının belirli kaos/arıza senaryolarını canlı kümede
# kontrollü bir şekilde tetiklemesini veya sistemi iyileştirmesini sağlar.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
elif [[ -f "${LAB_DIR}/ansible/hosts.ini" ]]; then
  MASTER_IP="$(awk -F'master_public_ip=' '/^master_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | tr -d '[:space:]')"
fi
MASTER_IP="${MASTER_IP:-9.205.30.199}"

run_k8s() {
  if [[ "$(hostname)" == "vm-master" ]]; then
    sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:$PATH" bash -c "$1"
  else
    ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=/var/lib/rancher/rke2/bin:/usr/local/bin:\$PATH $1"
  fi
}

ACTION="${1:-help}"

case "${ACTION}" in
  --gateway-decline)
    RATE="${2:-0.85}"
    echo "-> Payment Gateway hata oranı %$(( $(echo "${RATE} * 100" | bc | cut -d. -f1) )) seviyesine ayarlanıyor..."
    run_k8s "kubectl set env deployment/payment-worker -n app PAYMENT_FAILURE_RATE=${RATE}"
    echo "✅ Gateway arızası tetiklendi. Logları izleyin: kubectl logs -n app -l app.kubernetes.io/component=payment-worker -f"
    ;;
  --gateway-heal)
    echo "-> Payment Gateway normale döndürülüyor (%0 hata)..."
    run_k8s "kubectl set env deployment/payment-worker -n app PAYMENT_FAILURE_RATE=0.0"
    echo "✅ Gateway iyileştirildi. Ödemeler başarıyla işleniyor."
    ;;
  --tight-db-timeout)
    echo "-> order-api için veritabanı zaman aşımı 0.8s (800ms) seviyesine düşürülüyor (Deney 4)..."
    run_k8s "kubectl set env deployment/order-api -n app DEP_TIMEOUT_SECONDS=0.8"
    echo "✅ DB zaman aşımı daraltıldı. Şimdi Postgres gecikme kaosunu uygulayabilirsiniz."
    ;;
  --heal-db-timeout)
    echo "-> order-api için veritabanı zaman aşımı 4.0s seviyesine genişletiliyor..."
    run_k8s "kubectl set env deployment/order-api -n app DEP_TIMEOUT_SECONDS=4.0"
    echo "✅ DB zaman aşımı iyileştirildi."
    ;;
  --clean-chaos)
    echo "-> Aktif tüm Chaos Mesh deneyleri siliniyor..."
    run_k8s "kubectl delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow --all -n chaos-mesh --ignore-not-found=true"
    echo "✅ Tüm kaos deneyleri temizlendi."
    ;;
  *)
    echo "Kullanım:"
    echo "  $0 --gateway-decline [0.85]  -> Ödeme gateway'inde yapay %85 hata simüle et (Deney 5)"
    echo "  $0 --gateway-heal            -> Gateway hatasını sıfırla (%0 hata)"
    echo "  $0 --tight-db-timeout        -> DB timeout süresini daralt (Deney 4 RCA için)"
    echo "  $0 --heal-db-timeout         -> DB timeout süresini normale döndür"
    echo "  $0 --clean-chaos             -> Tüm aktif kaos deneylerini temizle"
    ;;
esac
