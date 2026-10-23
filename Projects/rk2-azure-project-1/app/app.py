import os
from fastapi import FastAPI
import psycopg2
from pymongo import MongoClient
import redis

app = FastAPI(title="RKE2 Multi-Tier Platform")

# Ortam değişkenlerinden K8s CoreDNS adreslerini ve şifreleri alıyoruz
REDIS_HOST = os.getenv("REDIS_HOST", "redis-master.data.svc.cluster.local")
REDIS_PORT = int(os.getenv("REDIS_PORT", 6379))
REDIS_PASS = os.getenv("REDIS_PASS", "RedisStrongPassword123!")

PG_HOST = os.getenv("PG_HOST", "postgres-postgresql.data.svc.cluster.local")
PG_PORT = int(os.getenv("PG_PORT", 5432))
PG_USER = os.getenv("PG_USER", "appuser")
PG_PASS = os.getenv("PG_PASS", "AppDbPassword123!")
PG_DB   = os.getenv("PG_DB", "appdb")

MONGO_HOST = os.getenv("MONGO_HOST", "mongodb.data.svc.cluster.local")
MONGO_PORT = int(os.getenv("MONGO_PORT", 27017))
MONGO_USER = os.getenv("MONGO_USER", "appuser")
MONGO_PASS = os.getenv("MONGO_PASS", "AppMongoPassword123!")
MONGO_DB   = os.getenv("MONGO_DB", "appdb")

@app.get("/healthz")
def healthz():
    return {"status": "ok"}

@app.get("/")
def dashboard():
    results = {}

    # 1. REDIS TESTİ (Ziyaretçi Sayacı)
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASS, socket_timeout=2)
        visits = r.incr("page_visits")
        results["redis"] = {"status": "CONNECTED (vm-worker-infra)", "visits": visits}
    except Exception as e:
        results["redis"] = {"status": "FAILED", "error": str(e)}

    # 2. POSTGRESQL TESTİ (İlişkisel DB)
    try:
        conn = psycopg2.connect(host=PG_HOST, port=PG_PORT, user=PG_USER, password=PG_PASS, dbname=PG_DB, connect_timeout=2)
        cur = conn.cursor()
        cur.execute("SELECT version();")
        pg_ver = cur.fetchone()[0]
        cur.close()
        conn.close()
        results["postgresql"] = {"status": "CONNECTED (vm-worker-pg)", "version": pg_ver.split()[0:2]}
    except Exception as e:
        results["postgresql"] = {"status": "FAILED", "error": str(e)}

    # 3. MONGODB TESTİ (NoSQL Audit Log)
    try:
        client = MongoClient(f"mongodb://{MONGO_USER}:{MONGO_PASS}@{MONGO_HOST}:{MONGO_PORT}/{MONGO_DB}?authSource={MONGO_DB}", serverSelectionTimeoutMS=2000)
        db = client[MONGO_DB]
        db.audit_logs.insert_one({"event": "page_view", "timestamp": str(os.times())})
        count = db.audit_logs.count_documents({})
        results["mongodb"] = {"status": "CONNECTED (vm-worker-mongo)", "total_logs": count}
    except Exception as e:
        results["mongodb"] = {"status": "FAILED", "error": str(e)}

    return {
        "platform": "RKE2 5-Node High-Isolation Enterprise Architecture",
        "app_node": "vm-worker-app",
        "services": results
    }