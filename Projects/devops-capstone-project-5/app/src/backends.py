"""Arka uç (backend) istemcileri, devre kesiciler ve arka plan sağlık kontrolü (health probe).

Neden prod'da böyle tasarlanır?
1. Her dış bağımlılık (PostgreSQL, Kafka, RabbitMQ, Cassandra, Redis) kendi
   `CircuitBreaker` nesnesiyle korunur. Bir bağımlılık çöktüğünde (ör. Chaos Mesh
   ağ bölünmesi) devre açılır (`OPEN=2`) ve sistem thread havuzunu tüketmeden
   hızlıca hata döndürür veya "degraded" modda çalışmaya devam eder.
2. Tüm dış çağrılar `DEP_TIMEOUT_SECONDS` (varsayılan 2 sn) ile sınırlandırılmıştır.
   Timeout olmayan ağ çağrıları prod ortamlarında en yaygın kilitlenme (cascading failure)
   sebebidir.
3. Proje 4 Dersi #6: Bağımlılık sağlık metrikleri (`rs_dependency_up`) Prometheus'un
   `/metrics` kazıma (scrape) anında DEĞİL, arka planda çalışan bir daemon thread
   tarafından her `HEALTH_PROBE_INTERVAL` (5 sn) içinde bir güncellenir. Böylece
   bağımlılıklardan biri yavaşladığında `/metrics` uç noktası zaman aşımına uğramaz!
"""
import json
import logging
import random
import socket
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import pika
import psycopg2
import redis
from kafka import KafkaConsumer, KafkaProducer, TopicPartition

from . import config
from .metrics import (
    DEPENDENCIES,
    DEP_LATENCY,
    DEP_UP,
    KAFKA_CONSUMED,
    KAFKA_LAG,
    RABBIT_PROCESSED,
    cb_state_changed,
)
from .resilience import CircuitBreaker, CircuitOpenError, retry

logger = logging.getLogger("resiliencestream.backends")

# ==============================================================================
# 1. BAĞIMLILIK BAZLI DEVRE KESİCİLER (CIRCUIT BREAKERS)
# ==============================================================================
# Her bağımlılık için ayrı bir CircuitBreaker tutulur. Durum değiştiğinde
# (`CLOSED=0`, `HALF_OPEN=1`, `OPEN=2`) `cb_state_changed` callback'i ile
# `rs_circuit_breaker_state{dependency=...}` Prometheus metriği anında güncellenir.
BREAKERS: Dict[str, CircuitBreaker] = {
    dep: CircuitBreaker(
        name=dep,
        failure_threshold=3,
        reset_timeout=15.0,
        on_state_change=cb_state_changed,
    )
    for dep in DEPENDENCIES
}

# Son arka plan probe sonuçlarını bellekte tutarak `/api/status` ve `/`
# çağrılarının da hızlı yanıt vermesini sağlarız.
_LAST_PROBE_STATUS: Dict[str, Dict[str, Any]] = {
    dep: {"status": "DOWN", "latency_ms": 0.0, "detail": "Not probed yet"}
    for dep in DEPENDENCIES
}
_PROBE_LOCK = threading.Lock()
_PROBE_THREAD_STARTED = False


# ==============================================================================
# 2. POSTGRESQL İSTEMCİSİ (KRİTİK BAĞIMLILIK: ORDERS & PAYMENTS TABLOLARI)
# ==============================================================================
# Neden PostgreSQL kritik bağımlılıktır?
# Siparişin finansal/ilişkisel kaydı ACID garantisiyle PostgreSQL'de tutulur.
# `/readyz` (Readiness Probe) yalnızca PostgreSQL erişilebilir olduğunda 200 döner.
def _pg_connect():
    return psycopg2.connect(
        host=config.POSTGRES_HOST,
        port=config.POSTGRES_PORT,
        user=config.POSTGRES_USER,
        password=config.POSTGRES_PASSWORD,
        dbname=config.POSTGRES_DB,
        connect_timeout=int(max(1, config.DEP_TIMEOUT_SECONDS)),
    )


def ensure_postgres_schema() -> None:
    """Sipariş (`orders`) ve ödeme (`payments`) tablolarını idempotent olarak oluşturur."""
    conn = _pg_connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS orders (
                    order_id VARCHAR(64) PRIMARY KEY,
                    customer_id VARCHAR(64) NOT NULL,
                    product_id VARCHAR(64) NOT NULL,
                    quantity INTEGER NOT NULL,
                    amount NUMERIC(12, 2) NOT NULL,
                    status VARCHAR(32) NOT NULL DEFAULT 'CREATED',
                    pod_name VARCHAR(128) NOT NULL,
                    created_at TIMESTAMPTZ DEFAULT NOW()
                );
                CREATE TABLE IF NOT EXISTS payments (
                    payment_id VARCHAR(64) PRIMARY KEY,
                    order_id VARCHAR(64) UNIQUE NOT NULL,
                    amount NUMERIC(12, 2) NOT NULL,
                    status VARCHAR(32) NOT NULL,
                    retries INTEGER NOT NULL DEFAULT 0,
                    processed_by VARCHAR(128) NOT NULL,
                    processed_at TIMESTAMPTZ DEFAULT NOW()
                );
                """
            )
        conn.commit()
    finally:
        conn.close()


def check_postgres_ready() -> bool:
    """Readiness probe (`/readyz`) için hızlı PostgreSQL bağlantı kontrolü."""
    try:
        conn = _pg_connect()
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
                cur.fetchone()
            return True
        finally:
            conn.close()
    except Exception:
        return False


def write_order_to_postgres(order: Dict[str, Any]) -> Dict[str, Any]:
    """Siparişi PostgreSQL `orders` tablosuna retry + circuit breaker korumasıyla yazar."""
    def _op() -> Dict[str, Any]:
        start_ts = time.perf_counter()
        conn = _pg_connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS orders (
                        order_id VARCHAR(64) PRIMARY KEY,
                        customer_id VARCHAR(64) NOT NULL,
                        product_id VARCHAR(64) NOT NULL,
                        quantity INTEGER NOT NULL,
                        amount NUMERIC(12, 2) NOT NULL,
                        status VARCHAR(32) NOT NULL DEFAULT 'CREATED',
                        pod_name VARCHAR(128) NOT NULL,
                        created_at TIMESTAMPTZ DEFAULT NOW()
                    );
                    INSERT INTO orders (order_id, customer_id, product_id, quantity, amount, status, pod_name)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (order_id) DO NOTHING;
                    SELECT COUNT(*) FROM orders;
                    """,
                    (
                        order["order_id"],
                        order["customer_id"],
                        order["product_id"],
                        int(order["quantity"]),
                        float(order["amount"]),
                        "CREATED",
                        socket.gethostname(),
                    ),
                )
                total_orders = cur.fetchone()[0]
            conn.commit()
            latency = time.perf_counter() - start_ts
            DEP_LATENCY.labels("postgres").observe(latency)
            return {"status": "UP", "total_orders": total_orders, "latency_ms": round(latency * 1000, 2)}
        finally:
            conn.close()

    return BREAKERS["postgres"].call(lambda: retry(_op, attempts=3, base=0.05, cap=0.5))


def write_payment_to_postgres(order_id: str, amount: float, retries: int = 0) -> None:
    """RabbitMQ `payment-worker` tarafından tüketilen ödemeyi `payments` tablosuna idempotent yazar.

    Neden `ON CONFLICT (order_id) DO NOTHING`?
    Mesaj kuyrukları (RabbitMQ/Kafka) çoğunlukla 'At-Least-Once' (en az bir kez)
    teslimat garantisi verir. Worker mesajı işleyip ACK göndermeden hemen önce
    PodChaos ile öldürülürse mesaj başka bir worker'a tekrar gelir. `order_id`
    üzerindeki UNIQUE kısıtı sayesinde müşteriden iki kez para çekilmez (Idempotent Consumer)!
    """
    def _op() -> None:
        start_ts = time.perf_counter()
        conn = _pg_connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    CREATE TABLE IF NOT EXISTS payments (
                        payment_id VARCHAR(64) PRIMARY KEY,
                        order_id VARCHAR(64) UNIQUE NOT NULL,
                        amount NUMERIC(12, 2) NOT NULL,
                        status VARCHAR(32) NOT NULL,
                        retries INTEGER NOT NULL DEFAULT 0,
                        processed_by VARCHAR(128) NOT NULL,
                        processed_at TIMESTAMPTZ DEFAULT NOW()
                    );
                    INSERT INTO payments (payment_id, order_id, amount, status, retries, processed_by)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    ON CONFLICT (order_id) DO NOTHING;
                    """,
                    (
                        f"PAY-{uuid.uuid4().hex[:10].upper()}",
                        order_id,
                        float(amount),
                        "PAID",
                        int(retries),
                        socket.gethostname(),
                    ),
                )
            conn.commit()
            DEP_LATENCY.labels("postgres").observe(time.perf_counter() - start_ts)
        finally:
            conn.close()

    BREAKERS["postgres"].call(lambda: retry(_op, attempts=3, base=0.05, cap=0.5))


# ==============================================================================
# 3. APACHE KAFKA (KRAFT MODE) PRODUCER & ANALYTICS CONSUMER
# ==============================================================================
def publish_order_event_kafka(order: Dict[str, Any]) -> Dict[str, Any]:
    """Sipariş olayını Kafka `orders.events` topic'ine yayınlar."""
    timeout_ms = int(config.DEP_TIMEOUT_SECONDS * 1000)

    def _op() -> Dict[str, Any]:
        start_ts = time.perf_counter()
        producer = KafkaProducer(
            bootstrap_servers=[config.KAFKA_BOOTSTRAP],
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            request_timeout_ms=timeout_ms,
            max_block_ms=timeout_ms,
            api_version_auto_timeout_ms=timeout_ms,
            acks=1,
        )
        try:
            future = producer.send(config.KAFKA_TOPIC, value=order)
            meta = future.get(timeout=config.DEP_TIMEOUT_SECONDS)
            producer.flush(timeout=config.DEP_TIMEOUT_SECONDS)
            latency = time.perf_counter() - start_ts
            DEP_LATENCY.labels("kafka").observe(latency)
            return {
                "status": "UP",
                "topic": config.KAFKA_TOPIC,
                "partition": meta.partition,
                "offset": meta.offset,
                "latency_ms": round(latency * 1000, 2),
            }
        finally:
            producer.close(timeout=config.DEP_TIMEOUT_SECONDS)

    return BREAKERS["kafka"].call(lambda: retry(_op, attempts=2, base=0.05, cap=0.3))


# ==============================================================================
# 4. RABBITMQ PRODUCER & PAYMENT WORKER (RETRY + DLQ MİMARİSİ)
# ==============================================================================
# Neden RabbitMQ'da `x-retry` başlığı ve `payments.dlq` (Dead-Letter Queue) var?
# Bir ödeme mesajı geçici bir hata nedeniyle işlenemezse hemen çöpe atılmaz;
# `x-retry` sayacı artırılarak `RABBITMQ_MAX_RETRIES` (3) defaya kadar yeniden
# kuyruklanır. 3 deneme sonunda hâlâ başarısızsa (zehirli mesaj / poison pill),
# ana kuyruğu tıkamaması için `payments.dlq` kuyruğuna taşınır ve Prometheus
# `rs_rabbitmq_messages_processed_total{result="dlq"}` sayacı artırılır.
def _rabbit_parameters() -> pika.ConnectionParameters:
    credentials = pika.PlainCredentials(config.RABBITMQ_USER, config.RABBITMQ_PASSWORD)
    return pika.ConnectionParameters(
        host=config.RABBITMQ_HOST,
        port=config.RABBITMQ_PORT,
        credentials=credentials,
        socket_timeout=config.DEP_TIMEOUT_SECONDS,
        blocked_connection_timeout=config.DEP_TIMEOUT_SECONDS,
        connection_attempts=1,
    )


def publish_payment_task_rabbitmq(order: Dict[str, Any], retry_count: int = 0, to_dlq: bool = False) -> Dict[str, Any]:
    """Ödeme görevini RabbitMQ `payments` (veya `payments.dlq`) kuyruğuna yazar."""
    target_queue = config.RABBITMQ_DLQ if to_dlq else config.RABBITMQ_QUEUE

    def _op() -> Dict[str, Any]:
        start_ts = time.perf_counter()
        conn = pika.BlockingConnection(_rabbit_parameters())
        try:
            ch = conn.channel()
            ch.queue_declare(queue=config.RABBITMQ_QUEUE, durable=True)
            ch.queue_declare(queue=config.RABBITMQ_DLQ, durable=True)
            props = pika.BasicProperties(
                delivery_mode=2,  # Kalıcı (persistent) mesaj: broker restart olsa da silinmez
                content_type="application/json",
                headers={"x-retry": int(retry_count)},
            )
            ch.basic_publish(
                exchange="",
                routing_key=target_queue,
                body=json.dumps(order).encode("utf-8"),
                properties=props,
            )
            latency = time.perf_counter() - start_ts
            DEP_LATENCY.labels("rabbitmq").observe(latency)
            return {"status": "UP", "queue": target_queue, "latency_ms": round(latency * 1000, 2)}
        finally:
            if conn.is_open:
                conn.close()

    return BREAKERS["rabbitmq"].call(lambda: retry(_op, attempts=2, base=0.05, cap=0.3))


# ==============================================================================
# 5. CASSANDRA İSTEMCİSİ (KEYSPACE `resilience`, TABLE `order_events`)
# ==============================================================================
# Neden Cassandra?
# Yüksek hacimli olay günlükleri (event log / audit trail) ve zaman serisi verileri
# için masterless mimarisiyle yüksek yazma hızı sunar. Lab ortamında (4 GB RAM worker)
# `SimpleStrategy` ve `replication_factor: 1` ile çalışır; prod ortamında ise
# `NetworkTopologyStrategy` ve `replication_factor: 3` + `LOCAL_QUORUM` kullanılır.
def write_event_to_cassandra(event: Dict[str, Any]) -> Dict[str, Any]:
    """Kafka'dan tüketilen sipariş olayını Cassandra `resilience.order_events` tablosuna yazar."""
    def _op() -> Dict[str, Any]:
        start_ts = time.perf_counter()
        from cassandra.auth import PlainTextAuthProvider
        from cassandra.cluster import Cluster

        auth = PlainTextAuthProvider(
            username=config.CASSANDRA_USER,
            password=config.CASSANDRA_PASSWORD,
        )
        cluster = Cluster(
            contact_points=config.CASSANDRA_HOSTS,
            port=config.CASSANDRA_PORT,
            auth_provider=auth,
            connect_timeout=config.DEP_TIMEOUT_SECONDS,
            control_connection_timeout=config.DEP_TIMEOUT_SECONDS,
        )
        try:
            session = cluster.connect()
            session.default_timeout = config.DEP_TIMEOUT_SECONDS
            session.execute(
                f"""
                CREATE KEYSPACE IF NOT EXISTS {config.CASSANDRA_KEYSPACE}
                WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}};
                """
            )
            session.set_keyspace(config.CASSANDRA_KEYSPACE)
            session.execute(
                """
                CREATE TABLE IF NOT EXISTS order_events (
                    order_id text PRIMARY KEY,
                    customer_id text,
                    product_id text,
                    amount double,
                    created_at text
                );
                """
            )
            session.execute(
                """
                INSERT INTO order_events (order_id, customer_id, product_id, amount, created_at)
                VALUES (%s, %s, %s, %s, %s);
                """,
                (
                    str(event.get("order_id", uuid.uuid4().hex)),
                    str(event.get("customer_id", "unknown")),
                    str(event.get("product_id", "unknown")),
                    float(event.get("amount", 0.0)),
                    str(event.get("created_at", datetime.now(timezone.utc).isoformat())),
                ),
            )
            latency = time.perf_counter() - start_ts
            DEP_LATENCY.labels("cassandra").observe(latency)
            return {"status": "UP", "keyspace": config.CASSANDRA_KEYSPACE, "latency_ms": round(latency * 1000, 2)}
        finally:
            cluster.shutdown()

    return BREAKERS["cassandra"].call(lambda: retry(_op, attempts=2, base=0.05, cap=0.3))


# ==============================================================================
# 6. REDIS ÖNBELLEK İSTEMCİSİ (SON SİPARİŞ & SAYAÇLAR)
# ==============================================================================
def cache_order_in_redis(order: Dict[str, Any]) -> Dict[str, Any]:
    """Sipariş özetini Redis'te önbelleğe alır ve toplam sipariş sayacını artırır."""
    def _op() -> Dict[str, Any]:
        start_ts = time.perf_counter()
        client = redis.Redis(
            host=config.REDIS_HOST,
            port=config.REDIS_PORT,
            password=config.REDIS_PASSWORD,
            socket_timeout=config.DEP_TIMEOUT_SECONDS,
            socket_connect_timeout=config.DEP_TIMEOUT_SECONDS,
            decode_responses=True,
        )
        total_cached = client.incr("resiliencestream:orders_count")
        client.set(
            f"resiliencestream:order:{order['order_id']}",
            json.dumps(order),
            ex=3600,
        )
        client.set("resiliencestream:last_order_id", order["order_id"])
        latency = time.perf_counter() - start_ts
        DEP_LATENCY.labels("redis").observe(latency)
        return {"status": "UP", "orders_cached": total_cached, "latency_ms": round(latency * 1000, 2)}

    return BREAKERS["redis"].call(lambda: retry(_op, attempts=2, base=0.05, cap=0.3))


# ==============================================================================
# 7. ARKA PLAN SAĞLIK TARAYICISI (BACKGROUND HEALTH PROBE DAEMON)
# ==============================================================================
# Proje 4 Dersi #6:
# `/metrics` çağrıldığında veritabanlarına bağlanmaya çalışmak (synchronous probe on scrape)
# büyük bir anti-pattern'dir: bir veritabanı yavaşladığında Prometheus scrape timeout
# alır ve TÜM metrikler kesilir. Bunun yerine bağımsız bir arka plan iş parçacığı
# (daemon thread) her 5 saniyede bir 5 bağımlılığı yoklar ve `rs_dependency_up`
# ile `rs_dependency_latency_seconds` metriklerini günceller.
def _probe_single_dependency(dep: str) -> Dict[str, Any]:
    start_ts = time.perf_counter()
    try:
        if dep == "postgres":
            conn = _pg_connect()
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1;")
                    cur.fetchone()
            finally:
                conn.close()
        elif dep == "redis":
            client = redis.Redis(
                host=config.REDIS_HOST,
                port=config.REDIS_PORT,
                password=config.REDIS_PASSWORD,
                socket_timeout=config.DEP_TIMEOUT_SECONDS,
                socket_connect_timeout=config.DEP_TIMEOUT_SECONDS,
            )
            client.ping()
        elif dep == "rabbitmq":
            conn = pika.BlockingConnection(_rabbit_parameters())
            try:
                ch = conn.channel()
                ch.queue_declare(queue=config.RABBITMQ_QUEUE, durable=True)
                ch.queue_declare(queue=config.RABBITMQ_DLQ, durable=True)
            finally:
                if conn.is_open:
                    conn.close()
        elif dep == "kafka":
            timeout_ms = int(config.DEP_TIMEOUT_SECONDS * 1000)
            consumer = KafkaConsumer(
                bootstrap_servers=[config.KAFKA_BOOTSTRAP],
                request_timeout_ms=timeout_ms,
                api_version_auto_timeout_ms=timeout_ms,
                consumer_timeout_ms=timeout_ms,
            )
            try:
                consumer.topics()
            finally:
                consumer.close()
        elif dep == "cassandra":
            from cassandra.auth import PlainTextAuthProvider
            from cassandra.cluster import Cluster

            auth = PlainTextAuthProvider(
                username=config.CASSANDRA_USER,
                password=config.CASSANDRA_PASSWORD,
            )
            cluster = Cluster(
                contact_points=config.CASSANDRA_HOSTS,
                port=config.CASSANDRA_PORT,
                auth_provider=auth,
                connect_timeout=config.DEP_TIMEOUT_SECONDS,
                control_connection_timeout=config.DEP_TIMEOUT_SECONDS,
            )
            try:
                session = cluster.connect()
                session.default_timeout = config.DEP_TIMEOUT_SECONDS
                session.execute("SELECT release_version FROM system.local;")
            finally:
                cluster.shutdown()

        latency = time.perf_counter() - start_ts
        DEP_LATENCY.labels(dep).observe(latency)
        DEP_UP.labels(dep).set(1)
        BREAKERS[dep].record_success()
        return {"status": "UP", "latency_ms": round(latency * 1000, 2), "detail": "OK"}
    except Exception as exc:
        latency = time.perf_counter() - start_ts
        DEP_LATENCY.labels(dep).observe(latency)
        DEP_UP.labels(dep).set(0)
        BREAKERS[dep].record_failure()
        return {"status": "DOWN", "latency_ms": round(latency * 1000, 2), "detail": str(exc)[:140]}


def probe_all_dependencies_once() -> Dict[str, Dict[str, Any]]:
    """5 bağımlılığın tamamını tek sefer yoklar ve metrikleri günceller."""
    results: Dict[str, Dict[str, Any]] = {}
    for dep in DEPENDENCIES:
        res = _probe_single_dependency(dep)
        results[dep] = res
    with _PROBE_LOCK:
        _LAST_PROBE_STATUS.update(results)
    return results


def get_cached_dependency_status() -> Dict[str, Dict[str, Any]]:
    """Arka plan thread'inin son ölçtüğü bağımlılık durumlarını döndürür."""
    with _PROBE_LOCK:
        return {
            dep: {
                **info,
                "circuit_breaker": BREAKERS[dep].state,
            }
            for dep, info in _LAST_PROBE_STATUS.items()
        }


def _health_probe_loop(stop_event: Optional[threading.Event] = None) -> None:
    while not (stop_event and stop_event.is_set()):
        try:
            probe_all_dependencies_once()
        except Exception as exc:
            logger.warning("Health probe döngüsünde beklenmeyen hata: %s", exc)
        time.sleep(config.HEALTH_PROBE_INTERVAL)


def start_health_probe_daemon() -> None:
    """Arka plan sağlık kontrolü daemon thread'ini başlatır (idempotent)."""
    global _PROBE_THREAD_STARTED
    if _PROBE_THREAD_STARTED:
        return
    _PROBE_THREAD_STARTED = True
    t = threading.Thread(target=_health_probe_loop, name="rs-health-probe", daemon=True)
    t.start()


# ==============================================================================
# 8. KAFKA ANALYTICS CONSUMER VE RABBITMQ PAYMENT WORKER DÖNGÜLERİ
# ==============================================================================
def analytics_consumer_loop(stop_event: Optional[threading.Event] = None) -> None:
    """Kafka `orders.events` topic'ini dinler, Cassandra `resilience.order_events` tablosuna yazar
    ve `rs_kafka_consumer_lag` ile `rs_kafka_events_consumed_total` metriklerini günceller."""
    timeout_ms = int(config.DEP_TIMEOUT_SECONDS * 1000)
    while not (stop_event and stop_event.is_set()):
        consumer: Optional[KafkaConsumer] = None
        try:
            consumer = KafkaConsumer(
                config.KAFKA_TOPIC,
                bootstrap_servers=[config.KAFKA_BOOTSTRAP],
                group_id=config.KAFKA_GROUP,
                auto_offset_reset="earliest",
                enable_auto_commit=True,
                request_timeout_ms=timeout_ms,
                api_version_auto_timeout_ms=timeout_ms,
                consumer_timeout_ms=1000,
                value_deserializer=lambda m: json.loads(m.decode("utf-8")),
            )
            polled = consumer.poll(timeout_ms=1000, max_records=20)
            total_lag = 0
            for tp, records in polled.items():
                for rec in records:
                    try:
                        write_event_to_cassandra(rec.value)
                        KAFKA_CONSUMED.inc()
                    except CircuitOpenError:
                        logger.warning("Cassandra devresi açık (OPEN), event bekletiliyor.")
                    except Exception as exc:
                        logger.warning("Cassandra yazma hatası: %s", exc)
                try:
                    end_offsets = consumer.end_offsets([tp])
                    end_offset = end_offsets.get(tp, rec.offset + 1)
                    lag = max(0, int(end_offset - (rec.offset + 1)))
                    total_lag += lag
                except Exception:
                    pass
            KAFKA_LAG.set(total_lag)
        except Exception as exc:
            logger.debug("Kafka analytics consumer bağlantı/okuma beklemesinde: %s", exc)
            time.sleep(2.0)
        finally:
            if consumer is not None:
                try:
                    consumer.close()
                except Exception:
                    pass
        time.sleep(1.0)


def process_single_payment_message(body: bytes, headers: Optional[Dict[str, Any]] = None) -> str:
    """Tek bir RabbitMQ ödeme mesajını işler.

    Dönüş değeri:
    - `'success'`: Ödeme PostgreSQL `payments` tablosuna yazıldı.
    - `'retry'`: Hata oluştu, `x-retry` < `RABBITMQ_MAX_RETRIES` olduğu için yeniden kuyruklandı.
    - `'dlq'`: Maksimum deneme sayısı aşıldı, mesaj `payments.dlq` kuyruğuna gönderildi.
    """
    payload = json.loads(body.decode("utf-8"))
    order_id = str(payload.get("order_id", f"ORD-{uuid.uuid4().hex[:8]}"))
    amount = float(payload.get("amount", 0.0))
    hdrs = headers or {}
    retry_count = int(hdrs.get("x-retry", 0))

    try:
        # Kaos / hata simülasyonu: PAYMENT_FAILURE_RATE oranında veya force_fail bayrağında hata fırlat
        if payload.get("force_fail") or (
            config.PAYMENT_FAILURE_RATE > 0 and random.random() < config.PAYMENT_FAILURE_RATE
        ):
            raise RuntimeError("Simulated payment gateway decline")

        write_payment_to_postgres(order_id=order_id, amount=amount, retries=retry_count)
        RABBIT_PROCESSED.labels("success").inc()
        return "success"
    except Exception as exc:
        logger.warning("Ödeme işleme hatası (order_id=%s, retry=%d): %s", order_id, retry_count, exc)
        if retry_count + 1 < config.RABBITMQ_MAX_RETRIES:
            try:
                publish_payment_task_rabbitmq(payload, retry_count=retry_count + 1, to_dlq=False)
            except Exception as pub_exc:
                logger.error("Retry mesajı kuyruklanamadı: %s", pub_exc)
            RABBIT_PROCESSED.labels("retry").inc()
            return "retry"
        else:
            try:
                publish_payment_task_rabbitmq(payload, retry_count=retry_count + 1, to_dlq=True)
            except Exception as dlq_exc:
                logger.error("DLQ mesajı kuyruklanamadı: %s", dlq_exc)
            RABBIT_PROCESSED.labels("dlq").inc()
            return "dlq"


def payment_worker_loop(stop_event: Optional[threading.Event] = None) -> None:
    """RabbitMQ `payments` kuyruğunu dinler; hatalarda 3 deneme sonrası `payments.dlq`'ya yönlendirir."""
    while not (stop_event and stop_event.is_set()):
        conn: Optional[pika.BlockingConnection] = None
        try:
            conn = pika.BlockingConnection(_rabbit_parameters())
            ch = conn.channel()
            ch.queue_declare(queue=config.RABBITMQ_QUEUE, durable=True)
            ch.queue_declare(queue=config.RABBITMQ_DLQ, durable=True)
            ch.basic_qos(prefetch_count=1)

            method_frame, header_frame, body = ch.basic_get(queue=config.RABBITMQ_QUEUE, auto_ack=False)
            if method_frame and body:
                headers = (header_frame.headers if header_frame and header_frame.headers else {}) or {}
                process_single_payment_message(body=body, headers=headers)
                ch.basic_ack(delivery_tag=method_frame.delivery_tag)
            else:
                time.sleep(1.0)
        except Exception as exc:
            logger.debug("RabbitMQ payment worker beklemede: %s", exc)
            time.sleep(2.0)
        finally:
            if conn is not None and conn.is_open:
                try:
                    conn.close()
                except Exception:
                    pass
