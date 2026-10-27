#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
===============================================================================
OMNISTREAM EVENT-DRIVEN POLYGLOT MİKROSERVİS & CANLI SRE TERMİNALİ  DENEMEEEEE
===============================================================================
Mimari Rolü:
Bu mikroservis, 5 sunuculu (5-Node) RKE2 Kubernetes kümesinde `vm-worker-app`
(tier=app) düğümü üzerinde çalışır ve `data` namespace'inde izole edilmiş 4 farklı
veri/akış sistemiyle (Polyglot Persistence + Event Streaming) gerçek zamanlı konuşur:

1. Apache Kafka (KRaft Mode - ZooKeeper'sız):
   - DNS: kafka.data.svc.cluster.local:9092
   - Topic: omnistream-events
   - Görev: Her sayfa ziyaretinde veya `/api/publish` çağrısında olay (event)
     üretir (Producer) ve topic'teki son mesajları/offset durumunu okur (Consumer).
   - Dayanıklılık (Resilience): Kafka henüz ısınıyorken (warming up) uygulamanın
     asılı kalmaması (hang olmaması) için 2 saniyelik sıkı zaman aşımı (timeout) kullanır.

2. Redis 7 (In-Memory Cache & Real-Time Counters):
   - DNS: redis-master.data.svc.cluster.local:6379
   - Görev: Gerçek zamanlı istek/olay sayaçlarını (`INCR`) ve son akış gecikmesini
     (stream latency ms) milisaniyeler içinde saklar.

3. PostgreSQL 16 (Relational ACID Database):
   - DNS: postgres-postgresql.data.svc.cluster.local:5432
   - Görev: `transactions_ledger` tablosunu otomatik oluşturur (`CREATE TABLE IF NOT EXISTS`),
     her işlemde kayıt ekler ve toplam satır sayısı ile motor sürümünü sorgular.

4. MongoDB 7 (NoSQL Document Store):
   - DNS: mongodb.data.svc.cluster.local:27017
   - Görev: `audit_events` koleksiyonuna esnek şemalı (JSON/BSON) denetim (audit)
     dokümanları yazar ve toplam doküman sayısını döndürür.

5. Prometheus Gözlemlenebilirlik (`/metrics`):
   - `omnistream_http_requests_total` (Counter)
   - `omnistream_kafka_events_published_total` (Counter)
   - `omnistream_db_health_status` (Gauge: 1=UP, 0=DOWN)
===============================================================================
"""

import json
import os
import socket
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List

import psycopg2
import pymongo
import redis
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from kafka import KafkaConsumer, KafkaProducer, TopicPartition
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

# ==============================================================================
# 1. ORTAM DEĞİŞKENLERİ (ENVIRONMENT VARIABLES) & KUBERNETES COREDNS ADRESLERİ
# ==============================================================================
# Kubernetes içinde servisler birbirine IP ile değil, CoreDNS üzerinden
# `<servis-adi>.<namespace>.svc.cluster.local` FQDN formatıyla bağlanır.
KAFKA_BOOTSTRAP_SERVERS = os.getenv(
    "KAFKA_BOOTSTRAP_SERVERS", "kafka.data.svc.cluster.local:9092"
)
KAFKA_TOPIC = os.getenv("KAFKA_TOPIC", "omnistream-events")

REDIS_HOST = os.getenv("REDIS_HOST", "redis-master.data.svc.cluster.local")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
REDIS_PASS = os.getenv("REDIS_PASS", "RedisStrongPassword123!")

PG_HOST = os.getenv("PG_HOST", "postgres-postgresql.data.svc.cluster.local")
PG_PORT = int(os.getenv("PG_PORT", "5432"))
PG_USER = os.getenv("PG_USER", "appuser")
PG_PASS = os.getenv("PG_PASS", "AppDbPassword123!")
PG_DB = os.getenv("PG_DB", "appdb")

MONGO_HOST = os.getenv("MONGO_HOST", "mongodb.data.svc.cluster.local")
MONGO_PORT = int(os.getenv("MONGO_PORT", "27017"))
MONGO_USER = os.getenv("MONGO_USER", "appuser")
MONGO_PASS = os.getenv("MONGO_PASS", "AppMongoPassword123!")
MONGO_DB = os.getenv("MONGO_DB", "appdb")

APP_VERSION = os.getenv("APP_VERSION", "1.0.0")

# ==============================================================================
# 2. PROMETHEUS METRİK TANIMLAMALARI (OBSERVABILITY)
# ==============================================================================
# Prometheus Operator (ServiceMonitor), `/metrics` uç noktasını düzenli olarak
# kazıyarak (scrape) bu metrikleri Grafana panellerinde görselleştirir.
HTTP_REQUESTS_TOTAL = Counter(
    "omnistream_http_requests_total",
    "OmniStream mikroservisine gelen toplam HTTP istek sayisi",
    ["method", "endpoint"],
)

KAFKA_EVENTS_PUBLISHED_TOTAL = Counter(
    "omnistream_kafka_events_published_total",
    "Apache Kafka omnistream-events topigine basariyla gonderilen toplam olay sayisi",
    ["topic", "status"],
)

DB_HEALTH_STATUS = Gauge(
    "omnistream_db_health_status",
    "Arka uc veri sistemlerinin anlik saglik durumu (1=Saglikli/UP, 0=Hata/DOWN)",
    ["backend"],
)

# ==============================================================================
# 3. FASTAPI UYGULAMA BAŞLATICI
# ==============================================================================
app = FastAPI(
    title="OmniStream Event-Driven Polyglot Microservice",
    description="RKE2 Kubernetes Capstone: Kafka (KRaft) + Redis + PostgreSQL + MongoDB + Prometheus",
    version=APP_VERSION,
)


# ==============================================================================
# 4. ARKA UÇ (BACKEND) ENTEGRASYON FONKSİYONLARI (2 SANİYE TIMEOUT KORUMALI)
# ==============================================================================
def interact_with_kafka(event_source: str = "page_visit") -> Dict[str, Any]:
    """
    Apache Kafka (KRaft Mode) entegrasyonu:
    1. `omnistream-events` topic'ine JSON formatında bir olay (event) basar (Producer).
    2. Aynı topic'in son partition offset değerini ve son mesajları okur (Consumer).
    3. Bağlantı zaman aşımı 2 saniye (`2000ms`) ile sınırlandırılmıştır; böylece
       Kafka pod'u henüz ayağa kalkıyorsa uygulama kilitlenmez (non-blocking fail-safe).
    """
    start_ts = time.perf_counter()
    event_id = str(uuid.uuid4())[:8]
    event_payload = {
        "event_id": event_id,
        "source": event_source,
        "pod": socket.gethostname(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "pipeline": "OmniStream-KRaft-Engine",
    }

    try:
        # --- ADIM A: KAFKA PRODUCER İLE EVENT GÖNDERİMİ ---
        producer = KafkaProducer(
            bootstrap_servers=[KAFKA_BOOTSTRAP_SERVERS],
            value_serializer=lambda v: json.dumps(v).encode("utf-8"),
            request_timeout_ms=2000,
            max_block_ms=2000,
            api_version_auto_timeout_ms=2000,
            acks=1,
        )
        future = producer.send(KAFKA_TOPIC, value=event_payload)
        record_metadata = future.get(timeout=2.0)
        producer.flush(timeout=2.0)
        producer.close(timeout=2.0)

        KAFKA_EVENTS_PUBLISHED_TOTAL.labels(topic=KAFKA_TOPIC, status="success").inc()

        # --- ADIM B: KAFKA CONSUMER İLE SON OFFSET VE MESAJLARI OKUMA ---
        latest_messages: List[Dict[str, Any]] = []
        end_offset = record_metadata.offset + 1
        partition_id = record_metadata.partition

        try:
            consumer = KafkaConsumer(
                bootstrap_servers=[KAFKA_BOOTSTRAP_SERVERS],
                auto_offset_reset="latest",
                enable_auto_commit=False,
                consumer_timeout_ms=1500,
                request_timeout_ms=2000,
                api_version_auto_timeout_ms=2000,
                value_deserializer=lambda m: json.loads(m.decode("utf-8")),
            )
            tp = TopicPartition(KAFKA_TOPIC, partition_id)
            consumer.assign([tp])

            # Son 3 mesajı okumak için offset'i geriye sar
            end_offsets = consumer.end_offsets([tp])
            end_offset = end_offsets.get(tp, end_offset)
            start_offset = max(0, end_offset - 3)
            consumer.seek(tp, start_offset)

            polled = consumer.poll(timeout_ms=1000, max_records=3)
            for _, records in polled.items():
                for rec in records:
                    latest_messages.append(
                        {
                            "offset": rec.offset,
                            "partition": rec.partition,
                            "payload": rec.value,
                        }
                    )
            consumer.close()
        except Exception:
            # Okuma sırasında zaman aşımı olsa bile üretilen mesaj bilgisini göster
            latest_messages = [
                {
                    "offset": record_metadata.offset,
                    "partition": partition_id,
                    "payload": event_payload,
                }
            ]

        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="kafka").set(1)

        return {
            "status": "UP",
            "mode": "KRaft (ZooKeeper-less)",
            "broker": KAFKA_BOOTSTRAP_SERVERS,
            "topic": KAFKA_TOPIC,
            "partition": partition_id,
            "latest_offset": end_offset,
            "published_event": event_payload,
            "recent_stream": latest_messages[-3:],
            "latency_ms": latency_ms,
        }

    except Exception as exc:
        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        KAFKA_EVENTS_PUBLISHED_TOTAL.labels(topic=KAFKA_TOPIC, status="error").inc()
        DB_HEALTH_STATUS.labels(backend="kafka").set(0)
        return {
            "status": "DOWN",
            "mode": "KRaft (ZooKeeper-less)",
            "broker": KAFKA_BOOTSTRAP_SERVERS,
            "topic": KAFKA_TOPIC,
            "partition": 0,
            "latest_offset": 0,
            "published_event": event_payload,
            "recent_stream": [],
            "error": str(exc)[:160],
            "latency_ms": latency_ms,
        }


def interact_with_redis(kafka_latency_ms: float, action: str = "visit") -> Dict[str, Any]:
    """
    Redis 7 entegrasyonu:
    Gerçek zamanlı ziyaret/olay sayacını (`omnistream:hits`) artırır ve
    son Kafka akış gecikmesini (`omnistream:last_stream_latency_ms`) önbelleğe yazar.
    """
    start_ts = time.perf_counter()
    try:
        client = redis.Redis(
            host=REDIS_HOST,
            port=REDIS_PORT,
            password=REDIS_PASS,
            socket_timeout=2.0,
            socket_connect_timeout=2.0,
            decode_responses=True,
        )
        total_hits = client.incr("omnistream:hits")
        if action == "publish":
            published_count = client.incr("omnistream:published_events")
        else:
            published_count = int(client.get("omnistream:published_events") or 0)

        client.set("omnistream:last_stream_latency_ms", str(kafka_latency_ms))
        client.set(
            "omnistream:last_updated",
            datetime.now(timezone.utc).strftime("%H:%M:%S UTC"),
        )

        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="redis").set(1)

        return {
            "status": "UP",
            "host": f"{REDIS_HOST}:{REDIS_PORT}",
            "total_hits": total_hits,
            "published_events_cached": published_count,
            "last_stream_latency_ms": kafka_latency_ms,
            "latency_ms": latency_ms,
        }
    except Exception as exc:
        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="redis").set(0)
        return {
            "status": "DOWN",
            "host": f"{REDIS_HOST}:{REDIS_PORT}",
            "total_hits": 0,
            "published_events_cached": 0,
            "last_stream_latency_ms": kafka_latency_ms,
            "error": str(exc)[:160],
            "latency_ms": latency_ms,
        }


def interact_with_postgres(event_source: str = "page_visit") -> Dict[str, Any]:
    """
    PostgreSQL 16 entegrasyonu:
    `transactions_ledger` tablosunu otomatik oluşturur, yeni bir işlem kaydı
    (transaction record) ekler ve toplam satır sayısı ile PostgreSQL sürümünü döndürür.
    """
    start_ts = time.perf_counter()
    try:
        conn = psycopg2.connect(
            host=PG_HOST,
            port=PG_PORT,
            user=PG_USER,
            password=PG_PASS,
            dbname=PG_DB,
            connect_timeout=2,
        )
        cur = conn.cursor()

        # Tablo yoksa otomatik oluştur (Idempotent DDL)
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS transactions_ledger (
                id SERIAL PRIMARY KEY,
                tx_code VARCHAR(32) NOT NULL,
                event_source VARCHAR(64) NOT NULL,
                pod_name VARCHAR(128) NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            );
            """
        )

        tx_code = f"TX-{str(uuid.uuid4())[:8].upper()}"
        cur.execute(
            """
            INSERT INTO transactions_ledger (tx_code, event_source, pod_name)
            VALUES (%s, %s, %s);
            """,
            (tx_code, event_source, socket.gethostname()),
        )
        conn.commit()

        cur.execute("SELECT COUNT(*) FROM transactions_ledger;")
        row_count = cur.fetchone()[0]

        cur.execute("SHOW server_version;")
        pg_version = cur.fetchone()[0]

        cur.close()
        conn.close()

        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="postgresql").set(1)

        return {
            "status": "UP",
            "host": f"{PG_HOST}:{PG_PORT}",
            "table": "transactions_ledger",
            "total_rows": row_count,
            "last_tx_code": tx_code,
            "version": f"PostgreSQL {pg_version}",
            "latency_ms": latency_ms,
        }
    except Exception as exc:
        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="postgresql").set(0)
        return {
            "status": "DOWN",
            "host": f"{PG_HOST}:{PG_PORT}",
            "table": "transactions_ledger",
            "total_rows": 0,
            "last_tx_code": "N/A",
            "version": "Unavailable",
            "error": str(exc)[:160],
            "latency_ms": latency_ms,
        }


def interact_with_mongodb(event_source: str = "page_visit") -> Dict[str, Any]:
    """
    MongoDB 7 entegrasyonu:
    `audit_events` koleksiyonuna yeni bir denetim (audit) dokümanı ekler ve
    koleksiyondaki toplam doküman sayısını döndürür.
    """
    start_ts = time.perf_counter()
    try:
        mongo_uri = (
            f"mongodb://{MONGO_USER}:{MONGO_PASS}@{MONGO_HOST}:{MONGO_PORT}/"
            f"{MONGO_DB}?authSource={MONGO_DB}"
        )
        client = pymongo.MongoClient(
            mongo_uri,
            serverSelectionTimeoutMS=2000,
            connectTimeoutMS=2000,
            socketTimeoutMS=2000,
        )
        db = client[MONGO_DB]
        collection = db["audit_events"]

        audit_doc = {
            "audit_id": f"AUD-{str(uuid.uuid4())[:8].upper()}",
            "event_source": event_source,
            "pod_name": socket.gethostname(),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        collection.insert_one(audit_doc)
        total_docs = collection.count_documents({})
        client.close()

        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="mongodb").set(1)

        return {
            "status": "UP",
            "host": f"{MONGO_HOST}:{MONGO_PORT}",
            "collection": "audit_events",
            "total_documents": total_docs,
            "last_audit_id": audit_doc["audit_id"],
            "latency_ms": latency_ms,
        }
    except Exception as exc:
        latency_ms = round((time.perf_counter() - start_ts) * 1000, 2)
        DB_HEALTH_STATUS.labels(backend="mongodb").set(0)
        return {
            "status": "DOWN",
            "host": f"{MONGO_HOST}:{MONGO_PORT}",
            "collection": "audit_events",
            "total_documents": 0,
            "last_audit_id": "N/A",
            "error": str(exc)[:160],
            "latency_ms": latency_ms,
        }


def collect_full_telemetry(event_source: str = "page_visit") -> Dict[str, Any]:
    """
    4 veri katmanının tamamını çalıştırır ve birleşik telemetri sözlüğü üretir.
    """
    kafka_data = interact_with_kafka(event_source=event_source)
    redis_data = interact_with_redis(
        kafka_latency_ms=kafka_data.get("latency_ms", 0.0),
        action="publish" if event_source != "page_visit" else "visit",
    )
    postgres_data = interact_with_postgres(event_source=event_source)
    mongo_data = interact_with_mongodb(event_source=event_source)

    healthy_count = sum(
        1
        for item in (kafka_data, redis_data, postgres_data, mongo_data)
        if item["status"] == "UP"
    )

    return {
        "application": "omnistream-app",
        "version": APP_VERSION,
        "pod_hostname": socket.gethostname(),
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "event_source": event_source,
        "overall_health": f"{healthy_count}/4 Systems Operational",
        "topology": {
            "vm-worker-stream": "tier=stream (Taint: dedicated=stream:NoSchedule) -> Kafka KRaft + Redis 7",
            "vm-worker-sql": "tier=db-sql (Taint: dedicated=db-sql:NoSchedule) -> PostgreSQL 16",
            "vm-worker-nosql": "tier=db-nosql (Taint: dedicated=db-nosql:NoSchedule) -> MongoDB 7",
            "vm-worker-app": "tier=app -> omnistream-app + GitLab Runner",
        },
        "backends": {
            "kafka": kafka_data,
            "redis": redis_data,
            "postgresql": postgres_data,
            "mongodb": mongo_data,
        },
    }


# ==============================================================================
# 5. HTTP UÇ NOKTALARI (API & CANLI TERMİNAL DASHBOARD ENDPOINTS)
# ==============================================================================
@app.get("/healthz")
def healthz() -> JSONResponse:
    """
    Kubernetes Liveness ve Readiness Probe uç noktası.
    Pod'un trafik almaya hazır olup olmadığını hızlıca doğrular.
    """
    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/healthz").inc()
    return JSONResponse(content={"status": "ok", "pod": socket.gethostname()})


@app.get("/metrics")
def metrics() -> Response:
    """
    Prometheus Operator (ServiceMonitor) tarafından kazınan (scrape) metrik uç noktası.
    """
    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/metrics").inc()
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/api/status")
def api_status() -> JSONResponse:
    """
    Tüm 4 veri sisteminin (Kafka, Redis, PostgreSQL, MongoDB) anlık JSON telemetrisini döndürür.
    """
    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/api/status").inc()
    telemetry = collect_full_telemetry(event_source="api_status_poll")
    return JSONResponse(content=telemetry)


@app.post("/api/publish")
async def api_publish(request: Request) -> JSONResponse:
    """
    Kullanıcı arayüzündeki '⚡ Kafka Event Gönder (Produce)' butonundan veya
    dış sistemlerden çağrıldığında yeni bir Kafka event'i üretir, PostgreSQL ve
    MongoDB'ye kayıt düşer, Redis sayacını artırır ve JSON sonucunu döner.
    """
    HTTP_REQUESTS_TOTAL.labels(method="POST", endpoint="/api/publish").inc()
    try:
        body = await request.json()
        source = body.get("source", "manual_ui_trigger")
    except Exception:
        source = "manual_ui_trigger"

    telemetry = collect_full_telemetry(event_source=source)
    return JSONResponse(content=telemetry)


@app.get("/", response_class=HTMLResponse)
def dashboard() -> HTMLResponse:
    """
    Cyberpunk / SRE Dark-Mode Canlı Terminal Kontrol Paneli.
    Kafka (KRaft), Redis, PostgreSQL ve MongoDB durum kartlarını, 5 düğümlü RKE2
    topolojisini, canlı Kafka Event gönderme butonunu ve JSON telemetri konsolunu sunar.
    """
    HTTP_REQUESTS_TOTAL.labels(method="GET", endpoint="/").inc()
    telemetry = collect_full_telemetry(event_source="dashboard_visit")
    backends = telemetry["backends"]

    def badge_html(status: str) -> str:
        if status == "UP":
            return '<span class="badge badge-up">● ONLINE (UP)</span>'
        return '<span class="badge badge-down">▲ DEGRADED (DOWN)</span>'

    kafka_b = backends["kafka"]
    redis_b = backends["redis"]
    pg_b = backends["postgresql"]
    mongo_b = backends["mongodb"]
    telemetry_json = json.dumps(telemetry, indent=2, ensure_ascii=False)

    html_content = f"""<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>OmniStream SRE Command Center | RKE2 Polyglot & Kafka Platform</title>
    <style>
        :root {{
            --bg-dark: #070b14;
            --bg-card: #0f172a;
            --bg-terminal: #050811;
            --border: #1e293b;
            --cyan: #06b6d4;
            --emerald: #10b981;
            --amber: #f59e0b;
            --rose: #f43f5e;
            --purple: #a855f7;
            --text-main: #f1f5f9;
            --text-muted: #94a3b8;
        }}
        * {{ box-sizing: border-box; margin: 0; padding: 0; }}
        body {{
            background-color: var(--bg-dark);
            background-image: radial-gradient(circle at 15% 15%, rgba(6, 182, 212, 0.08), transparent 35%),
                              radial-gradient(circle at 85% 80%, rgba(168, 85, 247, 0.08), transparent 35%);
            color: var(--text-main);
            font-family: 'JetBrains Mono', 'Fira Code', 'Courier New', monospace;
            padding: 24px;
            line-height: 1.5;
        }}
        .container {{ max-width: 1320px; margin: 0 auto; }}
        .header {{
            display: flex;
            flex-wrap: wrap;
            justify-content: space-between;
            align-items: center;
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-left: 4px solid var(--cyan);
            border-radius: 10px;
            padding: 20px 24px;
            margin-bottom: 24px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.45);
        }}
        .title-block h1 {{
            font-size: 1.45rem;
            color: var(--cyan);
            letter-spacing: 0.5px;
        }}
        .title-block p {{
            color: var(--text-muted);
            font-size: 0.85rem;
            margin-top: 4px;
        }}
        .actions {{
            display: flex;
            gap: 12px;
            align-items: center;
            margin-top: 10px;
        }}
        .btn-produce {{
            background: linear-gradient(135deg, #06b6d4, #3b82f6);
            color: #fff;
            border: none;
            padding: 12px 20px;
            border-radius: 8px;
            font-family: inherit;
            font-weight: 700;
            font-size: 0.9rem;
            cursor: pointer;
            transition: transform 0.15s ease, box-shadow 0.15s ease;
            box-shadow: 0 0 18px rgba(6, 182, 212, 0.4);
        }}
        .btn-produce:hover {{
            transform: translateY(-2px);
            box-shadow: 0 0 25px rgba(6, 182, 212, 0.7);
        }}
        .btn-produce:active {{ transform: translateY(0); }}
        .meta-pill {{
            background: rgba(15, 23, 42, 0.9);
            border: 1px solid var(--border);
            padding: 8px 14px;
            border-radius: 6px;
            font-size: 0.8rem;
            color: var(--text-muted);
        }}
        .grid-cards {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(290px, 1fr));
            gap: 18px;
            margin-bottom: 24px;
        }}
        .card {{
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 18px;
            position: relative;
            overflow: hidden;
        }}
        .card-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 14px;
            padding-bottom: 10px;
            border-bottom: 1px solid var(--border);
        }}
        .card-title {{
            font-size: 1rem;
            font-weight: 700;
            color: #fff;
        }}
        .badge {{
            font-size: 0.72rem;
            padding: 4px 10px;
            border-radius: 999px;
            font-weight: 700;
        }}
        .badge-up {{
            background: rgba(16, 185, 129, 0.15);
            color: var(--emerald);
            border: 1px solid rgba(16, 185, 129, 0.4);
        }}
        .badge-down {{
            background: rgba(244, 63, 94, 0.15);
            color: var(--rose);
            border: 1px solid rgba(244, 63, 94, 0.4);
        }}
        .kv-row {{
            display: flex;
            justify-content: space-between;
            font-size: 0.82rem;
            margin-bottom: 8px;
        }}
        .kv-key {{ color: var(--text-muted); }}
        .kv-val {{ color: var(--text-main); font-weight: 600; text-align: right; }}
        .section-panel {{
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 18px 20px;
            margin-bottom: 24px;
        }}
        .section-title {{
            font-size: 0.95rem;
            color: var(--cyan);
            margin-bottom: 14px;
            text-transform: uppercase;
            letter-spacing: 1px;
        }}
        .topology-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
            gap: 12px;
        }}
        .node-box {{
            background: var(--bg-terminal);
            border: 1px solid var(--border);
            border-left: 3px solid var(--purple);
            padding: 12px;
            border-radius: 6px;
            font-size: 0.8rem;
        }}
        .node-box strong {{ color: #fff; display: block; margin-bottom: 4px; }}
        .node-box span {{ color: var(--text-muted); }}
        .terminal-box {{
            background: var(--bg-terminal);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 16px;
            overflow-x: auto;
            max-height: 420px;
            font-size: 0.8rem;
            color: #38bdf8;
        }}
    </style>
</head>
<body>
<div class="container">
    <header class="header">
        <div class="title-block">
            <h1>⚡ OMNISTREAM // EVENT-DRIVEN POLYGLOT SRE TERMINAL  DENEMEEEE</h1>
            <p>Pod: <strong>{telemetry["pod_hostname"]}</strong> | Sürüm: <strong>v{telemetry["version"]}</strong> | Durum: <strong>{telemetry["overall_health"]}</strong> | {telemetry["timestamp_utc"]}</p>
        </div>
        <div class="actions">
            <span class="meta-pill">Prometheus: <a href="/metrics" style="color:var(--cyan);">/metrics</a></span>
            <button class="btn-produce" id="produceBtn" onclick="publishKafkaEvent()">⚡ Kafka Event Gönder (Produce)</button>
        </div>
    </header>

    <section class="grid-cards">
        <!-- 1. APACHE KAFKA (KRAFT) KARTI -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">1. Apache Kafka (KRaft)</span>
                <span id="kafka-badge">{badge_html(kafka_b["status"])}</span>
            </div>
            <div class="kv-row"><span class="kv-key">Node / Tier:</span><span class="kv-val">vm-worker-stream (tier=stream)</span></div>
            <div class="kv-row"><span class="kv-key">Topic:</span><span class="kv-val" id="kafka-topic">{kafka_b["topic"]}</span></div>
            <div class="kv-row"><span class="kv-key">Latest Offset:</span><span class="kv-val" id="kafka-offset">{kafka_b["latest_offset"]}</span></div>
            <div class="kv-row"><span class="kv-key">Son Event ID:</span><span class="kv-val" id="kafka-event-id">{kafka_b["published_event"]["event_id"]}</span></div>
            <div class="kv-row"><span class="kv-key">Gecikme (Latency):</span><span class="kv-val" id="kafka-latency">{kafka_b["latency_ms"]} ms</span></div>
        </div>

        <!-- 2. REDIS 7 KARTI -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">2. Redis 7 Cache</span>
                <span id="redis-badge">{badge_html(redis_b["status"])}</span>
            </div>
            <div class="kv-row"><span class="kv-key">Node / Tier:</span><span class="kv-val">vm-worker-stream (tier=stream)</span></div>
            <div class="kv-row"><span class="kv-key">Canlı Hit Sayacı:</span><span class="kv-val" id="redis-hits">{redis_b["total_hits"]}</span></div>
            <div class="kv-row"><span class="kv-key">Publish Sayacı:</span><span class="kv-val" id="redis-pub">{redis_b["published_events_cached"]}</span></div>
            <div class="kv-row"><span class="kv-key">Stream Latency Cache:</span><span class="kv-val" id="redis-stream-lat">{redis_b["last_stream_latency_ms"]} ms</span></div>
            <div class="kv-row"><span class="kv-key">Gecikme (Latency):</span><span class="kv-val" id="redis-latency">{redis_b["latency_ms"]} ms</span></div>
        </div>

        <!-- 3. POSTGRESQL 16 KARTI -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">3. PostgreSQL 16 (ACID)</span>
                <span id="pg-badge">{badge_html(pg_b["status"])}</span>
            </div>
            <div class="kv-row"><span class="kv-key">Node / Tier:</span><span class="kv-val">vm-worker-sql (tier=db-sql)</span></div>
            <div class="kv-row"><span class="kv-key">Tablo:</span><span class="kv-val">{pg_b["table"]}</span></div>
            <div class="kv-row"><span class="kv-key">Toplam Kayıt (Row):</span><span class="kv-val" id="pg-rows">{pg_b["total_rows"]}</span></div>
            <div class="kv-row"><span class="kv-key">Son İşlem Kodu:</span><span class="kv-val" id="pg-tx">{pg_b["last_tx_code"]}</span></div>
            <div class="kv-row"><span class="kv-key">Gecikme (Latency):</span><span class="kv-val" id="pg-latency">{pg_b["latency_ms"]} ms</span></div>
        </div>

        <!-- 4. MONGODB 7 KARTI -->
        <div class="card">
            <div class="card-header">
                <span class="card-title">4. MongoDB 7 (NoSQL)</span>
                <span id="mongo-badge">{badge_html(mongo_b["status"])}</span>
            </div>
            <div class="kv-row"><span class="kv-key">Node / Tier:</span><span class="kv-val">vm-worker-nosql (tier=db-nosql)</span></div>
            <div class="kv-row"><span class="kv-key">Koleksiyon:</span><span class="kv-val">{mongo_b["collection"]}</span></div>
            <div class="kv-row"><span class="kv-key">Toplam Doküman:</span><span class="kv-val" id="mongo-docs">{mongo_b["total_documents"]}</span></div>
            <div class="kv-row"><span class="kv-key">Son Audit ID:</span><span class="kv-val" id="mongo-audit">{mongo_b["last_audit_id"]}</span></div>
            <div class="kv-row"><span class="kv-key">Gecikme (Latency):</span><span class="kv-val" id="mongo-latency">{mongo_b["latency_ms"]} ms</span></div>
        </div>
    </section>

    <!-- KUBERNETES DÜĞÜM İZOLASYONU (NODE TOPOLOGY) -->
    <section class="section-panel">
        <div class="section-title">☸️ RKE2 Kubernetes Workload Isolation & Node Topology</div>
        <div class="topology-grid">
            <div class="node-box">
                <strong>vm-worker-stream (Standard_B1ms)</strong>
                <span>Label: tier=stream | Taint: dedicated=stream:NoSchedule<br/>Workloads: Apache Kafka (KRaft) + Redis 7</span>
            </div>
            <div class="node-box">
                <strong>vm-worker-sql (Standard_B1ms)</strong>
                <span>Label: tier=db-sql | Taint: dedicated=db-sql:NoSchedule<br/>Workloads: PostgreSQL 16 StatefulSet</span>
            </div>
            <div class="node-box">
                <strong>vm-worker-nosql (Standard_B1ms)</strong>
                <span>Label: tier=db-nosql | Taint: dedicated=db-nosql:NoSchedule<br/>Workloads: MongoDB 7 Standalone</span>
            </div>
            <div class="node-box">
                <strong>vm-worker-app (Standard_B1ms)</strong>
                <span>Label: tier=app | Taint: None (Application Tier)<br/>Workloads: omnistream-app + GitLab Runner</span>
            </div>
        </div>
    </section>

    <!-- CANLI JSON TELEMETRİ TERMİNALİ -->
    <section class="section-panel">
        <div class="section-title">📟 Canlı Telemetri & Kafka Stream Log Konsolu (/api/status & /api/publish)</div>
        <pre class="terminal-box" id="terminalOutput">{telemetry_json}</pre>
    </section>
</div>

<script>
async function publishKafkaEvent() {{
    const btn = document.getElementById('produceBtn');
    const term = document.getElementById('terminalOutput');
    btn.disabled = true;
    btn.innerText = '⏳ Kafka Event Gönderiliyor...';
    try {{
        const response = await fetch('/api/publish', {{
            method: 'POST',
            headers: {{ 'Content-Type': 'application/json' }},
            body: JSON.stringify({{ source: 'sre_dashboard_produce_button' }})
        }});
        const data = await response.json();
        term.textContent = JSON.stringify(data, null, 2);

        if (data.backends) {{
            const k = data.backends.kafka;
            const r = data.backends.redis;
            const p = data.backends.postgresql;
            const m = data.backends.mongodb;
            document.getElementById('kafka-offset').innerText = k.latest_offset;
            document.getElementById('kafka-event-id').innerText = k.published_event.event_id;
            document.getElementById('kafka-latency').innerText = k.latency_ms + ' ms';
            document.getElementById('redis-hits').innerText = r.total_hits;
            document.getElementById('redis-pub').innerText = r.published_events_cached;
            document.getElementById('redis-stream-lat').innerText = r.last_stream_latency_ms + ' ms';
            document.getElementById('redis-latency').innerText = r.latency_ms + ' ms';
            document.getElementById('pg-rows').innerText = p.total_rows;
            document.getElementById('pg-tx').innerText = p.last_tx_code;
            document.getElementById('pg-latency').innerText = p.latency_ms + ' ms';
            document.getElementById('mongo-docs').innerText = m.total_documents;
            document.getElementById('mongo-audit').innerText = m.last_audit_id;
            document.getElementById('mongo-latency').innerText = m.latency_ms + ' ms';
        }}
    }} catch (err) {{
        term.textContent = 'Hata oluştu: ' + err;
    }} finally {{
        btn.disabled = false;
        btn.innerText = '⚡ Kafka Event Gönder (Produce)';
    }}
}}
</script>
</body>
</html>"""
    return HTMLResponse(content=html_content)
