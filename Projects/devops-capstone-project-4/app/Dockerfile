# ==============================================================================
# OMNISTREAM MİKROSERVİSİ — GÜVENLİK SIKILAŞTIRILMŞ (HARDENED) DOCKERFILE
# ==============================================================================
# Bu Dockerfile, DevSecOps standartlarına (CIS Docker Benchmark & Trivy) tam
# uyumlu olacak şekilde tasarlanmıştır:
# 1. Küçük Saldırı Yüzeyi (Minimal Attack Surface): `python:3.11-slim` baz imajı
#    kullanılarak gereksiz işletim sistemi paketleri ve potansiyel CVE zafiyetleri
#    imaj dışında bırakılmıştır.
# 2. Katman Önbellekleme (Layer Caching): `requirements.txt` dosyası uygulama
#    kodundan (`app.py`) ÖNCE kopyalanır. Böylece sadece Python kodu değiştiğinde
#    Buildah tüm paketleri baştan indirmek yerine önbellekteki (cache) katmanı kullanır.
# 3. `--no-cache-dir` Kullanımı: `pip` kurulum önbelleği imaj içinde tutulmaz;
#    konteyner boyutu onlarca MB küçülür.
# 4. Non-Root Kullanıcı (`appuser`, UID `10001`): Konteyner asla `root` (UID 0)
#    olarak çalışmaz! Olası bir konteyner kaçış (Container Escape) saldırısında
#    saldırganın Kubernetes worker düğümünde (`vm-worker-app`) root yetkisi
#    kazanması engellenir ve Trivy güvenlik taramalarından tam not alınır.
# ==============================================================================

FROM python:3.11-slim

# Python çalışma zamanı optimizasyonları:
# PYTHONDONTWRITEBYTECODE=1 -> .pyc derlenmiş bayt kodu dosyalarının diske yazılmasını engeller.
# PYTHONUNBUFFERED=1        -> stdout/stderr loglarının tamponlanmadan (buffer) anında
#                              `kubectl logs` çıktısına düşmesini sağlar.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_HOME=/app

WORKDIR ${APP_HOME}

# İşletim sistemi güvenlik güncellemelerini uygula ve apt önbelleğini temizle
# (Trivy taramasında OS kaynaklı HIGH/CRITICAL CVE çıkmaması için kritik adım)
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Kurumsal güvenlik standartları gereği UID 10001 olan yetkisiz (non-root) sistem
# grubu ve kullanıcısı (`appuser`) oluşturulur.
RUN groupadd --gid 10001 appuser && \
    useradd --uid 10001 --gid 10001 --shell /sbin/nologin --create-home appuser

# ÖNCE bağımlılık dosyasını kopyala (Docker/Buildah Layer Caching optimizasyonu)
COPY requirements.txt .

# Bağımlılıkları `--no-cache-dir` ile kurarak imaj boyutunu minimumda tut
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Uygulama kaynak kodunu kopyala ve dosya sahipliğini non-root kullanıcıya devret
COPY --chown=appuser:appuser app.py .

# KRİTİK DEVSECOPS KURALI: Root yetkilerini bırak ve UID 10001 (appuser) ile çalış!
USER 10001

# FastAPI / Uvicorn sunucusunun dinleyeceği port
EXPOSE 8000

# Uvicorn ASGI sunucusunu başlat
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
