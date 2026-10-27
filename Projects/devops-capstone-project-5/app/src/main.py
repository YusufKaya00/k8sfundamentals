"""ResilienceStream FastAPI Uygulaması ve İşçi (Worker) Giriş Noktası (`src.main:app`).

Neden Tek İmaj, Üç Rol (`APP_ROLE = api | analytics | payment`)?
12-Factor App prensiplerine göre aynı konteyner imajı (`yusufk00/resiliencestream`)
farklı Deployment'larda farklı `APP_ROLE` ortam değişkenleriyle çalıştırılır:
- `APP_ROLE=api`       -> `order-api` (HTTP sipariş uç noktaları + arka plan health probe)
- `APP_ROLE=analytics` -> `analytics-consumer` (Kafka `orders.events` -> Cassandra `order_events` + `/healthz` + `/metrics`)
- `APP_ROLE=payment`   -> `payment-worker` (RabbitMQ `payments` -> PostgreSQL `payments` + 3 retry -> `payments.dlq` + `/healthz` + `/metrics`)
- `APP_ROLE=all`       -> Tek pod modunda tüm consumer thread'lerini API ile birlikte çalıştırır.

Neden Liveness (`/healthz`) ve Readiness (`/readyz`) Ayrıdır?
- `/healthz` (Liveness Probe): Sadece Python/Uvicorn sürecinin hayatta olduğunu kontrol eder.
  ASLA veritabanına bağlanmaz! Eğer liveness probe içinde PostgreSQL kontrol edilirse,
  PostgreSQL 10 saniyeliğine yavaşladığında Kubernetes TÜM uygulama pod'larını aynı anda
  yeniden başlatır (Cascading Restart ఫీल्ड fırtınası).
- `/readyz` (Readiness Probe): Kritik bağımlılık olan PostgreSQL'in erişilebilir olduğunu
  doğrular. PostgreSQL çöktüğünde pod öldürülmez; sadece Service/Ingress yük dengeleyicisinden
  geçici olarak çıkarılır (`503 Service Unavailable`).
"""
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import json
import logging
import socket
import threading
import time
from typing import Any, Dict, Optional
import uuid

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from pydantic import BaseModel, Field

from . import config
from .backends import (
    analytics_consumer_loop,
    cache_order_in_redis,
    check_postgres_ready,
    get_cached_dependency_status,
    payment_worker_loop,
    probe_all_dependencies_once,
    publish_order_event_kafka,
    publish_payment_task_rabbitmq,
    start_health_probe_daemon,
    write_order_to_postgres,
)
from .metrics import HTTP_DURATION, HTTP_REQUESTS, ORDERS_CREATED

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("resiliencestream.main")

_WORKER_THREADS_STARTED = False


class OrderRequest(BaseModel):
    """`POST /api/orders` isteği için şema doğrulaması (k6 yük testiyle tam uyumlu)."""
    customer_id: str = Field(default="cust-demo", description="Müşteri kimliği")
    product_id: str = Field(default="sku-demo", description="Ürün kodu")
    quantity: int = Field(default=1, ge=1, description="Sipariş adedi")
    amount: float = Field(default=99.90, gt=0, description="Sipariş tutarı")
    force_fail: bool = Field(default=False, description="DLQ testi için ödemeyi bilinçli başarısız kıl")


def _start_role_threads() -> None:
    """`APP_ROLE` ayarına göre arka plan sağlık tarayıcısını ve tüketici thread'lerini başlatır."""
    global _WORKER_THREADS_STARTED
    start_health_probe_daemon()
    if _WORKER_THREADS_STARTED:
        return
    _WORKER_THREADS_STARTED = True

    role = config.APP_ROLE.lower()
    if role in ("analytics", "all"):
        logger.info("Kafka analytics-consumer arka plan iş parçacığı başlatılıyor (role=%s)...", role)
        t_analytics = threading.Thread(
            target=analytics_consumer_loop,
            name="rs-analytics-consumer",
            daemon=True,
        )
        t_analytics.start()

    if role in ("payment", "all"):
        logger.info("RabbitMQ payment-worker arka plan iş parçacığı başlatılıyor (role=%s)...", role)
        t_payment = threading.Thread(
            target=payment_worker_loop,
            name="rs-payment-worker",
            daemon=True,
        )
        t_payment.start()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Uygulama başlarken arka plan health probe ve rol bazlı consumer thread'lerini devreye alır."""
    _start_role_threads()
    yield


app = FastAPI(
    title="ResilienceStream Chaos Engineering & Polyglot Platform",
    description="Proje 5: FastAPI + PostgreSQL + Kafka KRaft + RabbitMQ (DLQ) + Cassandra + Redis + Chaos Mesh",
    version="1.0.0",
    lifespan=lifespan,
)


@app.middleware("http")
async def prometheus_http_middleware(request: Request, call_next):
    """Her HTTP isteğinin süresini (`rs_http_request_duration_seconds`) ve durum kodunu
    (`rs_http_requests_total`) otomatik olarak kaydeder."""
    start_ts = time.perf_counter()
    endpoint = request.url.path
    method = request.method
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        duration = time.perf_counter() - start_ts
        HTTP_DURATION.labels(endpoint=endpoint).observe(duration)
        HTTP_REQUESTS.labels(method=method, endpoint=endpoint, status=str(status_code)).inc()


# ==============================================================================
# 1. LIVENESS (`/healthz`) VE READINESS (`/readyz`) UÇ NOKTALARI
# ==============================================================================
@app.get("/healthz")
def healthz() -> JSONResponse:
    """Kubernetes Liveness Probe: Sadece sürecin kilitlenmediğini (process alive) doğrular.
    Dış bağımlılıkları KONTROL ETMEZ; aksi halde geçici DB arızasında pod restart fırtınası yaşanır."""
    return JSONResponse(
        status_code=200,
        content={
            "status": "alive",
            "role": config.APP_ROLE,
            "pod": socket.gethostname(),
        },
    )


@app.get("/readyz")
def readyz() -> JSONResponse:
    """Kubernetes Readiness Probe: Kritik bağımlılık PostgreSQL erişilebilirse 200,
    aksi halde 503 döndürerek pod'u geçici olarak Service/Ingress havuzundan çıkarır."""
    if config.APP_ROLE in ("analytics", "payment"):
        # Worker pod'ları HTTP trafiği almadığı için süreç ayaktaysa hazırdır
        return JSONResponse(status_code=200, content={"status": "ready", "role": config.APP_ROLE})

    pg_ok = check_postgres_ready()
    if pg_ok:
        return JSONResponse(
            status_code=200,
            content={"status": "ready", "postgres": "UP", "pod": socket.gethostname()},
        )
    return JSONResponse(
        status_code=503,
        content={"status": "not_ready", "postgres": "DOWN", "pod": socket.gethostname()},
    )


# ==============================================================================
# 2. PROMETHEUS METRİK UÇ NOKTASI (`/metrics`)
# ==============================================================================
@app.get("/metrics")
def metrics() -> Response:
    """Prometheus ServiceMonitor (`interval: 5s`) tarafından kazınan uç nokta.
    Proje 4 Dersi #6 gereği burada senkron veritabanı sorgusu YAPILMAZ; arka plan
    daemon thread'inin güncellediği metrikler anında (milisaniyede) döndürülür."""
    _start_role_threads()
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


# ==============================================================================
# 3. SİPARİŞ OLUŞTURMA (`POST /api/orders`) — GRACEFUL DEGRADATION MİMARİSİ
# ==============================================================================
@app.post("/api/orders")
def create_order(payload: Optional[OrderRequest] = None) -> JSONResponse:
    """Yeni sipariş oluşturur:
    1. Kritik yol (Hard Dependency): PostgreSQL `orders` tablosuna yazar. Başarısızsa 503 döner.
    2. Yan yollar (Soft Dependencies / Graceful Degradation):
       - Kafka `orders.events` topic'ine event yayınlar (`analytics-consumer` -> Cassandra için).
       - RabbitMQ `payments` kuyruğuna ödeme görevi basar (`payment-worker` -> Postgres için).
       - Redis'te son siparişi önbelleğe alır.
       Bu yan bağımlılıklardan biri Chaos deneyi sırasında erişilemezse (veya Circuit Breaker
       açıksa) sipariş reddedilmez; `201 Created` (`result="degraded"`) olarak döner!
    """
    req = payload or OrderRequest()
    order_id = f"ORD-{uuid.uuid4().hex[:10].upper()}"
    order_doc: Dict[str, Any] = {
        "order_id": order_id,
        "customer_id": req.customer_id,
        "product_id": req.product_id,
        "quantity": req.quantity,
        "amount": req.amount,
        "force_fail": req.force_fail,
        "pod_name": socket.gethostname(),
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    # Adım 1: Kritik Bağımlılık -> PostgreSQL
    try:
        pg_res = write_order_to_postgres(order_doc)
    except Exception as exc:
        ORDERS_CREATED.labels("failed").inc()
        logger.error("Kritik hata: Sipariş PostgreSQL'e yazılamadı: %s", exc)
        return JSONResponse(
            status_code=503,
            content={
                "status": "failed",
                "order_id": order_id,
                "error": f"Critical dependency PostgreSQL unavailable: {str(exc)[:120]}",
            },
        )

    # Adım 2: Yan Bağımlılıklar (Kafka, RabbitMQ, Redis) -> Circuit Breaker & Graceful Degradation
    degraded_reasons = []

    try:
        kafka_res = publish_order_event_kafka(order_doc)
    except Exception as exc:
        kafka_res = {"status": "DEGRADED", "error": str(exc)[:100]}
        degraded_reasons.append(f"kafka: {str(exc)[:60]}")

    try:
        rabbit_res = publish_payment_task_rabbitmq(order_doc)
    except Exception as exc:
        rabbit_res = {"status": "DEGRADED", "error": str(exc)[:100]}
        degraded_reasons.append(f"rabbitmq: {str(exc)[:60]}")

    try:
        redis_res = cache_order_in_redis(order_doc)
    except Exception as exc:
        redis_res = {"status": "DEGRADED", "error": str(exc)[:100]}
        degraded_reasons.append(f"redis: {str(exc)[:60]}")

    result_label = "degraded" if degraded_reasons else "success"
    ORDERS_CREATED.labels(result_label).inc()

    return JSONResponse(
        status_code=201,
        content={
            "status": result_label,
            "order": order_doc,
            "backends": {
                "postgres": pg_res,
                "kafka": kafka_res,
                "rabbitmq": rabbit_res,
                "redis": redis_res,
            },
            "degraded_reasons": degraded_reasons,
        },
    )


# ==============================================================================
# 4. SİSTEM DURUMU (`GET /api/status`) VE CANLI SRE KONTROL PANELİ (`GET /`)
# ==============================================================================
@app.get("/api/status")
def api_status(refresh: bool = False) -> JSONResponse:
    """5 bağımlılığın (`postgres`, `kafka`, `rabbitmq`, `cassandra`, `redis`) sağlık ve
    devre kesici (`circuit_breaker`) durumlarını JSON olarak döndürür."""
    _start_role_threads()
    if refresh:
        probe_all_dependencies_once()
    deps = get_cached_dependency_status()
    up_count = sum(1 for d in deps.values() if d.get("status") == "UP")
    return JSONResponse(
        content={
            "application": "resiliencestream",
            "role": config.APP_ROLE,
            "pod": socket.gethostname(),
            "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
            "overall_health": f"{up_count}/{len(deps)} Dependencies UP",
            "dependencies": deps,
        }
    )


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    """ResilienceStream SRE & Chaos Engineering Canlı Kontrol Paneli."""
    _start_role_threads()
    deps = get_cached_dependency_status()
    up_count = sum(1 for d in deps.values() if d.get("status") == "UP")
    status_json = json.dumps(deps, indent=2, ensure_ascii=False)

    cards_html = ""
    for name, info in deps.items():
        is_up = info.get("status") == "UP"
        badge_color = "#10b981" if is_up else "#f43f5e"
        cb_map = {0: "CLOSED (0)", 1: "HALF_OPEN (1)", 2: "OPEN (2)"}
        cb_text = cb_map.get(info.get("circuit_breaker", 0), "CLOSED (0)")
        cards_html += f"""
        <div class="card">
            <div class="card-title">{name.upper()} <span style="color:{badge_color}">● {info.get('status')}</span></div>
            <div class="kv"><span>Latency:</span><strong>{info.get('latency_ms', 0)} ms</strong></div>
            <div class="kv"><span>Circuit Breaker:</span><strong>{cb_text}</strong></div>
        </div>
        """

    html = f"""<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="UTF-8" />
    <title>ResilienceStream SRE & Chaos Command Center</title>
    <style>
        body {{ background:#0b1120; color:#f1f5f9; font-family:monospace; padding:24px; }}
        .container {{ max-width:1100px; margin:0 auto; }}
        .header {{ background:#111827; border:1px solid #1f2937; border-left:4px solid #06b6d4; padding:18px; border-radius:8px; margin-bottom:20px; display:flex; justify-content:space-between; align-items:center; }}
        .grid {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(200px, 1fr)); gap:14px; margin-bottom:20px; }}
        .card {{ background:#111827; border:1px solid #1f2937; padding:14px; border-radius:8px; }}
        .card-title {{ font-weight:bold; margin-bottom:10px; display:flex; justify-content:space-between; }}
        .kv {{ display:flex; justify-content:space-between; font-size:0.85rem; margin-top:4px; color:#94a3b8; }}
        button {{ background:#06b6d4; color:#000; border:none; padding:10px 16px; border-radius:6px; font-weight:bold; cursor:pointer; }}
        pre {{ background:#050811; border:1px solid #1f2937; padding:14px; border-radius:8px; overflow-x:auto; color:#38bdf8; }}
    </style>
</head>
<body>
<div class="container">
    <div class="header">
        <div>
            <h2>⚡ ResilienceStream — Chaos Engineering & Polyglot SRE Terminal</h2>
            <p>Pod: <strong>{socket.gethostname()}</strong> | Rol: <strong>{config.APP_ROLE}</strong> | Durum: <strong>{up_count}/{len(deps)} UP</strong></p>
        </div>
        <div>
            <button onclick="createOrder()">🛒 Sipariş Oluştur (POST /api/orders)</button>
        </div>
    </div>
    <div class="grid">{cards_html}</div>
    <h3>Canlı Telemetri & Devre Kesici Durumu</h3>
    <pre id="out">{status_json}</pre>
</div>
<script>
async function createOrder() {{
    const res = await fetch('/api/orders', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{customer_id: 'cust-ui', product_id: 'sku-chaos', quantity: 1, amount: 149.90}})
    }});
    const data = await res.json();
    document.getElementById('out').textContent = JSON.stringify(data, null, 2);
}}
</script>
</body>
</html>"""
    return HTMLResponse(content=html)
