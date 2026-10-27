# ==============================================================================
# RESILIENCESTREAM — GÜVENLİK SIKILAŞTIRILMIŞ (HARDENED) DOCKERFILE
# ==============================================================================
# Neden prod'da böyle tasarlanır?
# 1. Tek İmaj, Üç Rol (12-Factor): `order-api`, `analytics-consumer` ve
#    `payment-worker` aynı `yusufk00/resiliencestream` imajını kullanır; rol
#    ayrımı Kubernetes Deployment içindeki `APP_ROLE` (`api|analytics|payment`)
#    ortam değişkeniyle yapılır.
# 2. Küçük Saldırı Yüzeyi: `python:3.11-slim` taban imajı kullanılarak gereksiz
#    derleyiciler ve paketler dışarıda bırakılır.
# 3. Katman Önbellekleme (Layer Caching): `requirements.txt` uygulama kodundan
#    (`src/`) ÖNCE kopyalanır; kod değiştiğinde paketler yeniden indirilmez.
# 4. Non-Root Kullanıcı (`UID 10001`): Konteyner asla `root` (UID 0) olarak
#    çalışmaz. Olası bir konteyner kaçış (Container Escape) zafiyetinde saldırgan
#    worker düğümünde root olamaz.
# ==============================================================================

FROM python:3.11-slim

# PYTHONDONTWRITEBYTECODE=1 -> .pyc dosyaları diske yazılmaz
# PYTHONUNBUFFERED=1        -> stdout/stderr logları tamponlanmadan anında `kubectl logs`'a düşer
# CASS_DRIVER_NO_EXTENSIONS=1 -> cassandra-driver C eklentisi derlemeye çalışmadan saf Python ile hızlı kurulur
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    CASS_DRIVER_NO_EXTENSIONS=1 \
    APP_HOME=/app

WORKDIR ${APP_HOME}

# İşletim sistemi güvenlik yamalarını uygula ve apt önbelleğini temizle (Trivy HIGH/CRITICAL CVE önlemi)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Kurumsal güvenlik standardı gereği UID 10001 olan yetkisiz (non-root) kullanıcı oluştur
RUN groupadd --gid 10001 appuser && \
    useradd --uid 10001 --gid 10001 --shell /sbin/nologin --create-home appuser

# Önce bağımlılıkları kopyala ve kur (Buildah katman önbelleklemesi)
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Uygulama kaynak kodunu (`src/`) kopyala ve sahipliğini `appuser:appuser` yap
COPY --chown=appuser:appuser src/ ./src/

# Root yetkilerini bırak: UID 10001 ile çalış
USER 10001

EXPOSE 8000

# Uvicorn ASGI sunucusunu başlat (`APP_ROLE` env değişkenine göre API + ilgili consumer thread'i çalışır)
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]
