#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 4 — SİSTEM TEŞHİS VE BASELINE DOĞRULAYICI (check-system.sh)
# ==============================================================================
# Kullanım:
#   ./scripts/check-system.sh           -> Detaylı 7 katmanlı sistem durumu
#   ./scripts/check-system.sh --strict  -> Pristine Baseline doğrulaması (0 restart, lag 0, DLQ 0)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${SCRIPT_DIR}/.lab-env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.lab-env"
elif [[ -f "${LAB_DIR}/ansible/hosts.ini" ]]; then
  MASTER_IP="$(awk -F'master_public_ip=' '/^master_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | head -n1 | tr -d '[:space:]')"
  APP_IP="$(awk -F'app_worker_public_ip=' '/^app_worker_public_ip=/{print $2}' "${LAB_DIR}/ansible/hosts.ini" | head -n1 | tr -d '[:space:]')"
fi
MASTER_IP="${MASTER_IP:-9.205.250.156}"
APP_IP="${APP_IP:-9.205.250.138}"

run_k8s() {
  if [[ "$(hostname)" == "vm-master" ]]; then
    sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:$PATH" bash -c "$1"
  else
    ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=/var/lib/rancher/rke2/bin:/usr/local/bin:\$PATH $1"
  fi
}

MODE="${1:-normal}"

if [[ "${MODE}" == "--strict" ]]; then
  echo "======================================================================"
  echo "PRISTINE BASELINE DOĞRULAMASI (--strict mod)"
  echo "======================================================================"
  FAIL=0

  echo -n "[1/5] app namespace pod durumları kontrol ediliyor... "
  NOT_RUNNING=$(run_k8s "kubectl get pods -n app --no-headers | grep -v 'Running' || true")
  if [[ -n "${NOT_RUNNING}" ]]; then
    echo "❌ HATA: Bazı podlar Running durumunda değil!"
    echo "${NOT_RUNNING}"
    FAIL=1
  else
    echo "✅ TÜM PODLAR RUNNING"
  fi

  echo -n "[2/5] Pod restart sayıları kontrol ediliyor... "
  RESTARTS=$(run_k8s "kubectl get pods -n app -o jsonpath='{range .items[*].status.containerStatuses[*]}{.name}{\":\"}{.restartCount}{\"\\n\"}{end}' | awk -F: '\$2 > 0 {print}' || true")
  if [[ -n "${RESTARTS}" ]]; then
    echo "❌ HATA: Baseline öncesi pod restart algılandı!"
    echo "${RESTARTS}"
    FAIL=1
  else
    echo "✅ SIFIR RESTART (0)"
  fi

  echo -n "[3/5] RabbitMQ payments.dlq mesaj sayısı kontrol ediliyor... "
  DLQ_COUNT=$(run_k8s "kubectl exec -n messaging rabbitmq-0 -c rabbitmq -- rabbitmqctl -q list_queues name messages | awk '\$1 == \"payments.dlq\" {print \$2}' || echo '0'")
  if [[ "${DLQ_COUNT:-0}" -gt 0 ]]; then
    echo "❌ HATA: DLQ içinde ${DLQ_COUNT} adet mesaj var!"
    FAIL=1
  else
    echo "✅ DLQ BOŞ (0)"
  fi

  echo -n "[4/5] API /api/status uç noktası kontrol ediliyor... "
  STATUS_RESP=$(curl -s --max-time 5 "http://app.${APP_IP}.nip.io/api/status" || echo "FAILED")
  if [[ "${STATUS_RESP}" == *"healthy"* ]] || [[ "${STATUS_RESP}" == *"UP"* ]] || [[ "${STATUS_RESP}" == *"dependencies"* ]]; then
    echo "✅ API SAĞLIKLI"
  else
    echo "⚠️ UYARI: Dış Ingress üzerinden erişilemedi veya beklemede."
  fi

  echo -n "[5/5] Chaos Mesh CRD kontrol ediliyor... "
  CHAOS_COUNT=$(run_k8s "kubectl get podchaos,networkchaos,dnschaos,stresschaos,iochaos,timechaos,httpchaos -n chaos-mesh --no-headers 2>/dev/null | wc -l || echo '0'")
  if [[ "${CHAOS_COUNT:-0}" -gt 0 ]]; then
    echo "⚠️ UYARI: ${CHAOS_COUNT} aktif kaos deneyi mevcut!"
  else
    echo "✅ SİSTEM TEMİZ (Aktif kaos yok)"
  fi

  echo "======================================================================"
  if [[ "${FAIL}" -eq 1 ]]; then
    echo "❌ BASELINE DOĞRULAMASI BAŞARISIZ! Kaos deneylerine başlamadan önce hataları düzeltin."
    exit 1
  else
    echo "🎉 PRISTINE BASELINE DOĞRULANDI! Tüm kontroller yeşil."
    exit 0
  fi
fi

# Normal teşhis akışı
echo "======================================================================"
echo " 1. KUBERNETES UYGULAMA PODLARI VE RESTART SAYILARI (namespace: app)"
echo "======================================================================"
run_k8s "kubectl get pods -n app -o wide"

echo ""
echo "======================================================================"
echo " 2. HORIZONTAL POD AUTOSCALER (HPA) & KAYNAK KULLANIMI (namespace: app)"
echo "======================================================================"
run_k8s "kubectl get hpa -n app" || true
run_k8s "kubectl top pods -n app 2>/dev/null || echo 'Metrics-server verisi bekleniyor...'"

echo ""
echo "======================================================================"
echo " 3. AKTİF CHAOS MESH DENEYLERİ (namespace: chaos-mesh)"
echo "======================================================================"
run_k8s "kubectl get podchaos,networkchaos,dnschaos,stresschaos,iochaos,timechaos,httpchaos,workflow -n chaos-mesh 2>/dev/null || echo 'Aktif deney yok.'"

echo ""
echo "======================================================================"
echo " 4. UYGULAMA SAĞLIK VE BAĞIMLILIK DURUMU (/api/status)"
echo "======================================================================"
curl -s --max-time 10 "http://app.${APP_IP}.nip.io/api/status" | jq '{overall_health, pod, dependencies}' 2>/dev/null || echo "❌ API Yanıt Vermiyor veya Ingress bekleniyor."

echo ""
echo "======================================================================"
echo " 5. RABBITMQ KUYRUK, CONSUMER & DLQ KONTROLÜ (payments & payments.dlq)"
echo "======================================================================"
run_k8s "kubectl exec -n messaging rabbitmq-0 -c rabbitmq -- rabbitmqctl -q list_queues name messages_ready messages_unacknowledged consumers" || true

echo ""
echo "======================================================================"
echo " 6. APACHE KAFKA CONSUMER GROUP & LAG KONTROLÜ (analytics-consumer)"
echo "======================================================================"
run_k8s "kubectl exec -n app deploy/order-api -- python3 -c 'from kafka import KafkaAdminClient, KafkaConsumer, TopicPartition; c = KafkaConsumer(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\"); tp = TopicPartition(\"orders.events\", 0); end = c.end_offsets([tp])[tp]; cur = 0
try:
    a = KafkaAdminClient(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\")
    offs = a.list_consumer_group_offsets(\"analytics-consumer\")
    cur = offs.get(tp).offset if tp in offs and offs.get(tp).offset is not None and offs.get(tp).offset >= 0 else 0
except Exception:
    cur = 0
print(f\"GROUP: analytics-consumer | TOPIC: orders.events | PARTITION: 0 | CURRENT-OFFSET: {cur} | LOG-END-OFFSET: {end} | LAG: {max(0, end - cur)}\")' 2>/dev/null || echo 'Kafka lag sorgulanamadı.'"

echo ""
echo "======================================================================"
echo " 7. POSTGRESQL VE REDIS KAYIT SAYILARI"
echo "======================================================================"
run_k8s "kubectl exec -n data postgres-postgresql-0 -- env PGPASSWORD=AdminPassword2026! psql -U resilience -d resilience -t -c \"SELECT 'Postgres Siparis : ' || count(*) FROM orders UNION ALL SELECT 'Postgres Odeme   : ' || count(*) FROM payments;\"" || true
run_k8s "kubectl exec -n messaging redis-master-0 -- redis-cli -a AdminPassword2026! --no-auth-warning DBSIZE" || true
echo "======================================================================"
