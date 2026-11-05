#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 4 — SENARYO YÖNETİCİSİ (trigger-scenario.sh)
# ==============================================================================
# Bu betik, Lab 4'teki 14 deneyin (A1-A4 kontrol, T1-T9 troubleshoot, C2 gameday)
# canlı kümede uygulanmasını (apply), silinmesini (delete) ve incelenmesini sağlar.
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

copy_manifest() {
  local src="$1"
  local dst="$2"
  if [[ "$(hostname)" == "vm-master" ]]; then
    cp "$src" "$dst"
  else
    scp -o StrictHostKeyChecking=no "$src" ysf@"${MASTER_IP}":"$dst"
  fi
}

usage() {
  cat << 'EOF'
==============================================================================
K8S CHAOS LAB 4 — SENARYO YÖNETİM KOMUTLARI
==============================================================================
Kullanım:
  ./scripts/trigger-scenario.sh <SENARYO_NO> [apply|delete|status]
  ./scripts/trigger-scenario.sh --clean-chaos
  ./scripts/trigger-scenario.sh --status
  ./scripts/trigger-scenario.sh --list

BÖLÜM A: KONTROL DENEYLERİ (Sistem Dayanmalı)
  1  (A1) - IOChaos 200ms disk latency (PostgreSQL data volume)
  2  (A2) - TimeChaos +10m clock skew (payment-worker NTP drift)
  3  (A3) - PodChaos pod-kill (Kafka KRaft controller/broker restart)
  4  (A4) - HTTPChaos abort 30% on /api/status (L7 upstream degradation)

BÖLÜM B: TROUBLESHOOT DENEYLERİ (Gizli DevOps Zafiyetleri)
  5  (T1) - Liveness Cascade: 1500ms delay to PG triggers CrashLoop storm
  6  (T2) - Postgres Concurrency: 40 VU exhausts max_connections (limit 20)
  7  (T3) - PDB Drain Deadlock: minAvailable:2 blocks node drain indefinitely
  8  (T4) - HPA CPU Requests Omission: StressChaos CPU exposes missing requests
  9  (T5) - Redis Noeviction OOM: Memory saturation triggers write rejections
  10 (T6) - Retry Storm: 3s delay with 5 immediate retries multiplies traffic
  11 (T7) - NetworkPolicy Silent Drop: Hardening drops Cassandra 9042 & DNS 53
  12 (T8) - Secret Rotation Desync: Secret updated without pod checksum rollout
  13 (T9) - DNS ndots:5 Query Amplification: Short-name queries storm CoreDNS

BÖLÜM C: GAMEDAY ORKESTRASYONU
  14 (C2) - Automated GameDay Workflow with StatusCheck auto-abort

Örnekler:
  ./scripts/trigger-scenario.sh 5 apply      # T1 Liveness kaskad hatasını başlat
  ./scripts/trigger-scenario.sh 5 delete     # T1 deneyini kaldır / sistemi normale döndür
  ./scripts/trigger-scenario.sh --clean-chaos # Tüm aktif kaos deneylerini temizle
==============================================================================
EOF
}

SCENARIO="${1:-help}"
ACTION="${2:-apply}"

get_manifest_for_scenario() {
  case "$1" in
    1|a1|A1) echo "01-kontrol-io-postgres-latency.yaml" ;;
    2|a2|A2) echo "02-kontrol-time-skew-payment.yaml" ;;
    3|a3|A3) echo "03-kontrol-kafka-broker-kill.yaml" ;;
    4|a4|A4) echo "04-kontrol-http-abort-status.yaml" ;;
    5|t1|T1) echo "05-troubleshoot-liveness-cascade.yaml" ;;
    6|t2|T2) echo "06-troubleshoot-postgres-connections.yaml" ;;
    7|t3|T3) echo "07-troubleshoot-pdb-drain-deadlock.yaml" ;;
    8|t4|T4) echo "08-troubleshoot-hpa-cpu-requests.yaml" ;;
    9|t5|T5) echo "09-troubleshoot-redis-noeviction-oom.yaml" ;;
    10|t6|T6) echo "10-troubleshoot-retry-storm.yaml" ;;
    11|t7|T7) echo "11-troubleshoot-networkpolicy-silent-drop.yaml" ;;
    12|t8|T8) echo "12-troubleshoot-secret-rotation-desync.yaml" ;;
    13|t9|T9) echo "13-troubleshoot-dns-ndots-exhaustion.yaml" ;;
    14|c2|C2) echo "14-troubleshoot-game-day-workflow.yaml" ;;
    *) echo "" ;;
  esac
}

case "${SCENARIO}" in
  --clean-chaos)
    echo "-> Aktif tüm Chaos Mesh deneyleri ve test jobları temizleniyor..."
    run_k8s "kubectl delete podchaos,networkchaos,dnschaos,stresschaos,iochaos,timechaos,httpchaos,workflow --all -n chaos-mesh --ignore-not-found=true"
    run_k8s "kubectl delete job troubleshoot-06-postgres-connections troubleshoot-09-redis-noeviction-oom -n app --ignore-not-found=true"
    run_k8s "kubectl delete netpol security-team-hardening-flawed -n app --ignore-not-found=true"
    echo "✅ Tüm kaos kaynakları başarıyla temizlendi."
    ;;
  --status)
    echo "=== AKTİF KAOS VE TEST DURUMU ==="
    run_k8s "kubectl get podchaos,networkchaos,dnschaos,stresschaos,iochaos,timechaos,httpchaos,workflow -n chaos-mesh" || true
    echo "=== APP PODLARI VE RESTARLAR ==="
    run_k8s "kubectl get pods -n app -o wide"
    ;;
  --list|help|-h|--help)
    usage
    ;;
  *)
    MANIFEST="$(get_manifest_for_scenario "${SCENARIO}")"
    if [[ -z "${MANIFEST}" ]]; then
      echo "❌ Geçersiz senaryo numarası: ${SCENARIO}"
      usage
      exit 1
    fi

    LOCAL_FILE="${LAB_DIR}/chaos-workflows/${MANIFEST}"
    REMOTE_FILE="/tmp/${MANIFEST}"

    if [[ ! -f "${LOCAL_FILE}" ]]; then
      echo "❌ Manifesto dosyası bulunamadı: ${LOCAL_FILE}"
      exit 1
    fi

    echo "-> Senaryo ${SCENARIO} (${MANIFEST}) için işlem: ${ACTION}..."
    copy_manifest "${LOCAL_FILE}" "${REMOTE_FILE}"

    case "${ACTION}" in
      apply)
        run_k8s "kubectl apply -f ${REMOTE_FILE}"
        echo "✅ Senaryo ${SCENARIO} uygulandı!"
        echo "Gözlem için:"
        echo "  - Grafana: 04. DevOps Failure Modes & Game Day dashboard"
        echo "  - CLI:     kubectl get pods -n app -w"
        ;;
      delete)
        run_k8s "kubectl delete -f ${REMOTE_FILE} --ignore-not-found=true"
        echo "✅ Senaryo ${SCENARIO} kaldırıldı / temizlendi."
        ;;
      status)
        run_k8s "kubectl describe -f ${REMOTE_FILE}"
        ;;
      *)
        echo "❌ Geçersiz eylem: ${ACTION}. (Desteklenenler: apply, delete, status)"
        exit 1
        ;;
    esac
    ;;
esac
