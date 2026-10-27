"""Konfigürasyon: 12-Factor prensibi gereği TÜM ayarlar ortam değişkenlerinden okunur.

Neden prod'da böyle? Aynı imaj (yusufk00/resiliencestream) dev/stage/prod'da
değişmeden çalışır; farklılık sadece Helm values -> env ile verilir.
"""
import os


def _env(name: str, default: str) -> str:
    return os.getenv(name, default)


# APP_ROLE: tek imaj, üç rol (api | analytics | payment)
APP_ROLE = _env("APP_ROLE", "api")
PORT = int(_env("PORT", "8000"))

# Servis DNS adları sözleşmedeki tabloyla birebir aynı
KAFKA_BOOTSTRAP = _env("KAFKA_BOOTSTRAP", "kafka.data.svc.cluster.local:9092")
KAFKA_TOPIC = _env("KAFKA_TOPIC", "orders.events")
KAFKA_GROUP = _env("KAFKA_GROUP", "analytics-consumer")

CASSANDRA_HOSTS = _env("CASSANDRA_HOSTS", "cassandra.data.svc.cluster.local").split(",")
CASSANDRA_PORT = int(_env("CASSANDRA_PORT", "9042"))
CASSANDRA_USER = _env("CASSANDRA_USER", "resilience")
CASSANDRA_PASSWORD = _env("CASSANDRA_PASSWORD", "AdminPassword2026!")
CASSANDRA_KEYSPACE = _env("CASSANDRA_KEYSPACE", "resilience")

POSTGRES_HOST = _env("POSTGRES_HOST", "postgres-postgresql.data.svc.cluster.local")
POSTGRES_PORT = int(_env("POSTGRES_PORT", "5432"))
POSTGRES_USER = _env("POSTGRES_USER", "resilience")
POSTGRES_PASSWORD = _env("POSTGRES_PASSWORD", "AdminPassword2026!")
POSTGRES_DB = _env("POSTGRES_DB", "resilience")

RABBITMQ_HOST = _env("RABBITMQ_HOST", "rabbitmq.messaging.svc.cluster.local")
RABBITMQ_PORT = int(_env("RABBITMQ_PORT", "5672"))
RABBITMQ_USER = _env("RABBITMQ_USER", "resilience")
RABBITMQ_PASSWORD = _env("RABBITMQ_PASSWORD", "AdminPassword2026!")
RABBITMQ_QUEUE = _env("RABBITMQ_QUEUE", "payments")
RABBITMQ_DLQ = _env("RABBITMQ_DLQ", "payments.dlq")
RABBITMQ_MAX_RETRIES = int(_env("RABBITMQ_MAX_RETRIES", "3"))

REDIS_HOST = _env("REDIS_HOST", "redis-master.messaging.svc.cluster.local")
REDIS_PORT = int(_env("REDIS_PORT", "6379"))
REDIS_PASSWORD = _env("REDIS_PASSWORD", "AdminPassword2026!")

# Zaman aşımı: her dış çağrı için kısa timeout -> thread'ler asılı kalmaz
DEP_TIMEOUT_SECONDS = float(_env("DEP_TIMEOUT_SECONDS", "2"))
HEALTH_PROBE_INTERVAL = float(_env("HEALTH_PROBE_INTERVAL", "5"))
METRICS_PORT = int(_env("METRICS_PORT", "8000"))
# Ödeme simülasyonu: bu oranda ödeme "başarısız" olur -> retry/DLQ yolu gözlenebilir
PAYMENT_FAILURE_RATE = float(_env("PAYMENT_FAILURE_RATE", "0.05"))
