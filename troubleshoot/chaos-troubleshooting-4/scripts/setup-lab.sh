#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 4 — ORTAM HAZIRLAMA BETİĞİ (setup-lab.sh)
# ==============================================================================
# Kullanım:
#   ./scripts/setup-lab.sh              -> Lab'ı kararlı baseline modda başlatır/sıfırlar
#   ./scripts/setup-lab.sh --hardened   -> Lab'ı tüm senaryolar için güçlendirilmiş modda günceller
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
elif [[ -f "${LAB_DIR}/ansible/hosts.ini" ]]; then
  MASTER_IP="$(awk -F'master_public_ip=' '/^master_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | tr -d '[:space:]')"
  APP_IP="$(awk -F'app_worker_public_ip=' '/^app_worker_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | tr -d '[:space:]')"
fi
MASTER_IP="${MASTER_IP:-9.205.30.199}"
APP_IP="${APP_IP:-9.205.30.202}"
MODE="${1:-baseline}"

VALUES_FILE="values.yaml"
if [[ "${MODE}" == "--hardened" ]]; then
  VALUES_FILE="values-hardened.yaml"
  echo "======================================================================"
  echo " [MOD: HARDENED / GÜÇLENDİRİLMİŞ] Tüm senaryolar için güçlendirilmiş referans uygulanıyor"
  echo "======================================================================"
else
  echo "======================================================================"
  echo " [MOD: BASELINE / KARARLI] %100 Sağlıklı ve Kararlı Başlangıç Durumu Yükleniyor"
  echo "======================================================================"
fi

if [[ "$(hostname)" != "vm-master" ]]; then
  echo "-> [1/4] Lab dosyaları vm-master (${MASTER_IP}) sunucusuna aktarılıyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "mkdir -p ~/chaos-troubleshooting-4"
  scp -o StrictHostKeyChecking=no -r "${LAB_DIR}/helm-chart" "${LAB_DIR}/chaos-workflows" "${LAB_DIR}/scripts" ysf@"${MASTER_IP}":~/chaos-troubleshooting-4/ >/dev/null

  echo "-> [2/4] ArgoCD otomatik senkronizasyonu devre dışı bırakılıyor (varsa)..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch application resiliencestream -n argocd --type merge -p '{\"spec\":{\"syncPolicy\":null}}' 2>/dev/null || true"

  echo "-> [3/4] Önceki aktif Chaos Mesh deneyleri temizleniyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow --all -n chaos-mesh --ignore-not-found=true >/dev/null 2>&1 || true"

  echo "-> [4/4] Helm Chart (${VALUES_FILE}) 'app' namespace'ine uygulanıyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /usr/local/bin/helm upgrade --install resiliencestream /home/ysf/chaos-troubleshooting-4/helm-chart -n app --create-namespace -f /home/ysf/chaos-troubleshooting-4/helm-chart/${VALUES_FILE} --set ingress.host=app.${APP_IP}.nip.io --wait --timeout 180s"
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods,hpa -n app -o wide"
else
  echo "-> [1/3] ArgoCD otomatik senkronizasyonu devre dışı bırakılıyor (varsa)..."
  sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml patch application resiliencestream -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true

  echo "-> [2/3] Önceki aktif Chaos Mesh deneyleri temizleniyor..."
  sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow --all -n chaos-mesh --ignore-not-found=true >/dev/null 2>&1 || true

  echo "-> [3/3] Helm Chart (${VALUES_FILE}) 'app' namespace'ine uygulanıyor..."
  sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml /usr/local/bin/helm upgrade --install resiliencestream "${LAB_DIR}/helm-chart" -n app --create-namespace -f "${LAB_DIR}/helm-chart/${VALUES_FILE}" --set ingress.host=app.${APP_IP}.nip.io --wait --timeout 180s
  sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods,hpa -n app -o wide
fi

echo ""
echo "======================================================================"
echo " ✅ Lab 4 Başarıyla Hazırlandı! Tüm podlar 1/1 Running ve Yeşil."
echo " Sistem durumunu kontrol etmek için: ./scripts/check-system.sh"
echo "======================================================================"
