#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS LAB 4 — YÜK VE STRES TESTİ BAŞLATICI (load-test.sh)
# ==============================================================================
# Bu betik, küme içinde k6 yük testlerini parametrik olarak başlatır.
# Desteklenen senaryolar:
#   - Normal yük (baseline SLO doğrulaması)
#   - Concurrency yükü (T2 Postgres 20 connection limitini aşma)
#   - CPU stres yükü (T4 HPA tetikleme denemesi)
#   - Retry storm yükü (T6 timeout < delay ve agresif retry)
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

PROFILE="${1:-baseline}"

case "${PROFILE}" in
  baseline)
    echo "-> Baseline yük testi başlatılıyor (10 VU, 2 dakika)..."
    VUS=10
    DURATION="2m"
    RETRIES=0
    TIMEOUT=2
    ;;
  concurrency|t2)
    echo "-> T2 Concurrency stres testi başlatılıyor (50 VU, 3 dakika, PG limit: 20)..."
    VUS=50
    DURATION="3m"
    RETRIES=0
    TIMEOUT=2
    ;;
  retry-storm|t6)
    echo "-> T6 Retry Storm stres testi başlatılıyor (30 VU, retries=5, timeout=2s)..."
    VUS=30
    DURATION="3m"
    RETRIES=5
    TIMEOUT=2
    ;;
  stop)
    echo "-> Çalışan k6 yük testleri durduruluyor..."
    run_k8s "kubectl delete job -l app.kubernetes.io/component=load-tester -n app --ignore-not-found=true"
    echo "✅ Yük testleri durduruldu."
    exit 0
    ;;
  *)
    echo "Kullanım: $0 [baseline|concurrency|retry-storm|stop]"
    exit 1
    ;;
esac

run_k8s "kubectl delete job resiliencestream-k6-load -n app --ignore-not-found=true"

echo "-> Helm ile k6 yük testi Job'ı dağıtılıyor..."
run_k8s "helm upgrade resiliencestream ${LAB_DIR}/helm-chart \
  --namespace app \
  --reuse-values \
  --set loadTest.enabled=true \
  --set loadTest.vus=${VUS} \
  --set loadTest.duration=${DURATION} \
  --set loadTest.retries=${RETRIES} \
  --set loadTest.timeoutSeconds=${TIMEOUT}"

echo "✅ k6 Yük Testi Job'ı başlatıldı!"
echo "Logları takip etmek için:"
echo "  kubectl logs -n app -l app.kubernetes.io/component=load-tester -f"
echo "Durdurmak için:"
echo "  $0 stop"
