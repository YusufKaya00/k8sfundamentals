#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB 2 — TEK KOMUTLA SİSTEM TEŞHİS ARACI (check-system.sh)
# ==============================================================================
# Bu betik, Kaos Mühendisliği deneyleri sırasında sistemin 7 kritik katmanını
# (Podlar, HPA & CPU Throttling, Aktif Kaos Deneyleri, API Durumu, RabbitMQ/DLQ,
# Kafka Consumer Group/Lag ve Veritabanı Kayıtları) tek seferde sorgular.
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

run_k8s() {
  if [[ "$(hostname)" == "vm-master" ]]; then
    sudo env PATH="/var/lib/rancher/rke2/bin:/usr/local/bin:$PATH" KUBECONFIG="/etc/rancher/rke2/rke2.yaml" bash -c "$1"
  else
    ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "sudo env PATH=\"/var/lib/rancher/rke2/bin:/usr/local/bin:\$PATH\" KUBECONFIG=\"/etc/rancher/rke2/rke2.yaml\" bash -c '$1'"
  fi
}

echo "======================================================================"
echo " 1. KUBERNETES UYGULAMA PODLARI VE RESTART SAYILARI (namespace: app)"
echo "======================================================================"
run_k8s "kubectl get pods -n app -o wide"

echo ""
echo "======================================================================"
echo " 2. HORIZONTAL POD AUTOSCALER (HPA) & KAYNAK KULLANIMI (namespace: app)"
echo "======================================================================"
run_k8s "kubectl get hpa -n app"
run_k8s "kubectl top pods -n app 2>/dev/null || echo 'Metrics-server verisi bekleniyor...'"

echo ""
echo "======================================================================"
echo " 3. AKTİF CHAOS MESH DENEYLERİ (namespace: chaos-mesh)"
echo "======================================================================"
run_k8s "kubectl get podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow -n chaos-mesh 2>/dev/null || echo 'Aktif deney yok.'"

echo ""
echo "======================================================================"
echo " 4. UYGULAMA SAĞLIK VE BAĞIMLILIK DURUMU (/api/status)"
echo "======================================================================"
curl -s --max-time 10 "http://app.${APP_IP}.nip.io/api/status" | jq '{overall_health, pod, dependencies}' || echo "❌ API Yanıt Vermiyor (502/503 veya Timeout)!"

echo ""
echo "======================================================================"
echo " 5. RABBITMQ KUYRUK, CONSUMER & DLQ KONTROLÜ (payments & payments.dlq)"
echo "======================================================================"
run_k8s "kubectl exec -n messaging rabbitmq-0 -- rabbitmqctl -q list_queues name messages_ready messages_unacknowledged consumers"

echo ""
echo "======================================================================"
echo " 6. APACHE KAFKA CONSUMER GROUP & LAG KONTROLÜ (analytics-consumer)"
echo "======================================================================"
run_k8s "kubectl exec -n app deploy/order-api -- python3 -c '
from kafka import KafkaAdminClient, KafkaConsumer, TopicPartition
c = KafkaConsumer(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\")
tp = TopicPartition(\"orders.events\", 0)
end = c.end_offsets([tp])[tp]
a = KafkaAdminClient(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\")
offs = a.list_consumer_group_offsets(\"analytics-consumer\")
cur = offs.get(tp).offset if tp in offs and offs.get(tp).offset is not None else 0
print(f\"GROUP: analytics-consumer | TOPIC: orders.events | PARTITION: 0 | CURRENT-OFFSET: {cur} | LOG-END-OFFSET: {end} | LAG: {max(0, end - cur)}\")
'"

echo ""
echo "======================================================================"
echo " 7. POSTGRESQL, CASSANDRA VE REDIS KAYIT SAYILARI"
echo "======================================================================"
run_k8s "kubectl exec -n data postgres-postgresql-0 -- env PGPASSWORD='AdminPassword2026!' psql -U resilience -d resilience -t -c \"SELECT 'Postgres Siparis : ' || count(*) FROM orders UNION ALL SELECT 'Postgres Odeme   : ' || count(*) FROM payments;\""
run_k8s "kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning DBSIZE | awk '{print \"Redis Anahtar    : \" \$1}'"
echo "======================================================================"
