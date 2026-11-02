#!/usr/bin/env bash
# ==============================================================================
# K8S CHAOS & TROUBLESHOOTING LAB — TEK KOMUTLA SİSTEM TEŞHİS ARACI (check-system.sh)
# ==============================================================================
# Bu betik, bir Kaos Mühendisi / SRE'nin deney sırasında kontrol etmesi gereken
# 6 katmanı (K8s Podları, API Durumu, RabbitMQ Kuyruğu, Kafka Lag, Postgres ve Redis)
# tek seferde sorgular.
# ==============================================================================
set -euo pipefail

MASTER_IP="${MASTER_IP:-9.205.90.183}"
APP_IP="${APP_IP:-9.205.90.176}"

run_k8s() {
  if [[ "$(hostname)" == "vm-master" ]]; then
    bash -c "$1"
  else
    ssh -o StrictHostKeyChecking=no ysf@"${MASTER_IP}" "$1"
  fi
}

echo "======================================================================"
echo " 1. KUBERNETES UYGULAMA PODLARI VE RESTART SAYILARI (namespace: app)"
echo "======================================================================"
run_k8s "kubectl get pods -n app -o wide"

echo ""
echo "======================================================================"
echo " 2. AKTİF CHAOS MESH DENEYLERİ (namespace: chaos-mesh)"
echo "======================================================================"
run_k8s "kubectl get podchaos,networkchaos,dnschaos,stresschaos,iochaos,workflow -n chaos-mesh 2>/dev/null || echo 'Aktif deney yok.'"

echo ""
echo "======================================================================"
echo " 3. UYGULAMA SAĞLIK VE BAĞIMLILIK DURUMU (/api/status)"
echo "======================================================================"
curl -s --max-time 5 "http://app.${APP_IP}.nip.io/api/status" | jq '{overall_health, pod, dependencies}' || echo "❌ API Yanıt Vermiyor (502/503 veya Timeout)!"

echo ""
echo "======================================================================"
echo " 4. RABBITMQ KUYRUK & CONSUMER KONTROLÜ (payments & payments.dlq)"
echo "======================================================================"
run_k8s "kubectl exec -n messaging rabbitmq-0 -- rabbitmqctl -q list_queues name messages_ready messages_unacknowledged consumers"

echo ""
echo "======================================================================"
echo " 5. APACHE KAFKA CONSUMER GROUP & LAG KONTROLÜ (analytics-consumer)"
echo "======================================================================"
run_k8s "kubectl exec -n app deploy/order-api -- python3 -c '
from kafka import KafkaAdminClient, KafkaConsumer, TopicPartition
c = KafkaConsumer(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\")
tp = TopicPartition(\"orders.events\", 0)
end = c.end_offsets([tp])[tp]
a = KafkaAdminClient(bootstrap_servers=\"kafka.data.svc.cluster.local:9092\")
offs = a.list_consumer_group_offsets(\"analytics-consumer\")
cur = offs.get(tp).offset if tp in offs else 0
print(f\"GROUP: analytics-consumer | TOPIC: orders.events | PARTITION: 0 | CURRENT-OFFSET: {cur} | LOG-END-OFFSET: {end} | LAG: {max(0, end - cur)}\")
'"

echo ""
echo "======================================================================"
echo " 6. POSTGRESQL KAYIT SAYILARI & REDIS ÖNBELLEK KONTROLÜ"
echo "======================================================================"
run_k8s "kubectl exec -n data postgres-postgresql-0 -- env PGPASSWORD='AdminPassword2026!' psql -U resilience -d resilience -t -c \"SELECT 'Toplam Siparis: ' || count(*) FROM orders UNION ALL SELECT 'Toplam Odeme  : ' || count(*) FROM payments;\""
run_k8s "kubectl exec -n messaging redis-master-0 -- redis-cli -a 'AdminPassword2026!' --no-auth-warning DBSIZE | awk '{print \"Redis Anahtar Sayisi: \" \$1}'"
echo "======================================================================"
