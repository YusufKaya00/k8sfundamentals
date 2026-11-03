#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB — ORTAM HAZIRLAMA BETİĞİ (setup-lab.sh)
# ==============================================================================
# Kullanım:
#   ./scripts/setup-lab.sh           -> Lab'ı "Troubleshoot Modunda" (3 kasıtlı hatayla) başlatır/sıfırlar
#   ./scripts/setup-lab.sh --fixed   -> Lab'ı tüm hatalar çözülmüş ("Fixed") modda günceller
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
fi
MASTER_IP="${MASTER_IP:-9.205.90.183}"
APP_IP="${APP_IP:-9.205.90.176}"
MODE="${1:-troubleshoot}"

VALUES_FILE="values.yaml"
if [[ "${MODE}" == "--fixed" ]]; then
  VALUES_FILE="values-fixed.yaml"
  echo "======================================================================"
  echo " [MOD: ÇÖZÜLMÜŞ / FIXED] Tüm Troubleshoot hataları düzeltilmiş uygulanıyor"
  echo "======================================================================"
else
  echo "======================================================================"
  echo " [MOD: TROUBLESHOOT LAB] 3 Kasıtlı Yapılandırma Hatasıyla Başlatılıyor"
  echo "======================================================================"
fi

# Eğer yerel makinedeysek dosyaları vm-master üzerine kopyala ve orada çalıştır
if [[ "$(hostname)" != "vm-master" ]]; then
  echo "-> [1/4] Lab dosyaları vm-master (${MASTER_IP}) sunucusuna aktarılıyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "mkdir -p ~/chaos-troubleshooting-1"
  scp -o StrictHostKeyChecking=no -r "${LAB_DIR}/helm-chart" "${LAB_DIR}/chaos-workflows" "${LAB_DIR}/scripts" ysf@"${MASTER_IP}":~/chaos-troubleshooting-1/ >/dev/null

  echo "-> [2/4] ArgoCD otomatik senkronizasyonu (auto-sync) devre dışı bırakılıyor (varsa)..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "kubectl patch application resiliencestream -n argocd --type merge -p '{\"spec\":{\"syncPolicy\":null}}' 2>/dev/null || true"

  echo "-> [3/4] Önceki aktif Chaos Mesh deneyleri temizleniyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "kubectl delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow --all -n chaos-mesh --ignore-not-found=true >/dev/null 2>&1 || true"

  echo "-> [4/4] Helm Chart (${VALUES_FILE}) 'app' namespace'ine uygulanıyor..."
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "helm upgrade --install resiliencestream ~/chaos-troubleshooting-1/helm-chart -n app -f ~/chaos-troubleshooting-1/helm-chart/${VALUES_FILE} --set ingress.host=app.${APP_IP}.nip.io --wait --timeout 120s"
  ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "kubectl get pods -n app -o wide"
else
  echo "-> [1/3] ArgoCD otomatik senkronizasyonu devre dışı bırakılıyor (varsa)..."
  kubectl patch application resiliencestream -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || true

  echo "-> [2/3] Önceki aktif Chaos Mesh deneyleri temizleniyor..."
  kubectl delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow --all -n chaos-mesh --ignore-not-found=true >/dev/null 2>&1 || true

  echo "-> [3/3] Helm Chart (${VALUES_FILE}) 'app' namespace'ine uygulanıyor..."
  helm upgrade --install resiliencestream "${LAB_DIR}/helm-chart" -n app -f "${LAB_DIR}/helm-chart/${VALUES_FILE}" --set ingress.host=app.${APP_IP}.nip.io --wait --timeout 120s
  kubectl get pods -n app -o wide
fi

echo ""
echo "======================================================================"
echo " ✅ LAB HAZIR! ERİŞİM ADRESLERİ:"
echo "  - Chaos Mesh Web UI : http://chaos.${MASTER_IP}.nip.io"
echo "  - Grafana Dashboard : http://grafana.${MASTER_IP}.nip.io (admin / AdminPassword2026!)"
echo "  - Sipariş API Durum : http://app.${APP_IP}.nip.io/api/status"
echo "  - Sistem Kontrolü   : ./scripts/check-system.sh"
echo "======================================================================"
