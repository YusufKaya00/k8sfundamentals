"""Sözleşmedeki TÜM Prometheus metrikleri tek yerde tanımlanır (prefix `rs_`).
Neden? Alarm kuralları ve dashboard'lar bu adlara bağlı; tek kaynak = isim kayması yok."""
from prometheus_client import Counter, Gauge, Histogram

DEPENDENCIES = ("kafka", "rabbitmq", "cassandra", "postgres", "redis")

HTTP_REQUESTS = Counter("rs_http_requests_total", "HTTP istek sayısı",
                        ["method", "endpoint", "status"])
HTTP_DURATION = Histogram("rs_http_request_duration_seconds", "HTTP istek süresi",
                          ["endpoint"],
                          buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5))
DEP_UP = Gauge("rs_dependency_up", "Bağımlılık erişilebilir mi (1/0)", ["dependency"])
DEP_LATENCY = Histogram("rs_dependency_latency_seconds", "Bağımlılık probe gecikmesi",
                        ["dependency"],
                        buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2))
CB_STATE = Gauge("rs_circuit_breaker_state", "0=closed,1=half-open,2=open", ["dependency"])
ORDERS_CREATED = Counter("rs_orders_created_total", "Oluşturulan sipariş", ["result"])
KAFKA_CONSUMED = Counter("rs_kafka_events_consumed_total", "Tüketilen Kafka event sayısı")
KAFKA_LAG = Gauge("rs_kafka_consumer_lag", "Kafka consumer lag (mesaj)")
RABBIT_PROCESSED = Counter("rs_rabbitmq_messages_processed_total",
                           "RabbitMQ işlenen mesaj", ["result"])

# Başlangıç değerleri: seri hiç oluşmazsa alarm 'absent' kalır, dashboard boş görünür
for _d in DEPENDENCIES:
    DEP_UP.labels(_d).set(0)
    CB_STATE.labels(_d).set(0)
for _r in ("success", "degraded", "failed"):
    ORDERS_CREATED.labels(_r)
for _r in ("success", "retry", "dlq"):
    RABBIT_PROCESSED.labels(_r)


def cb_state_changed(name: str, state: int) -> None:
    CB_STATE.labels(name).set(state)
