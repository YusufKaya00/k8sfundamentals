# Enterprise SRE & Observability Laboratuvarı: Helm, Monitoring ve Batch İş Yükleri

Bu laboratuvar; ham Kubernetes manifestolarından modern paket yönetimine (**Helm 3**), kurumsal sistem görünürlüğünden (**kube-prometheus-stack**, **Prometheus**, **Grafana**, **PromQL**) ve veri operasyonlarından (**Job** & **CronJob**) oluşan 4 temel SRE ayağını uçtan uca simüle eder.

---

## Altyapı ve Kaynak Kısıtları

- **3 Worker Node Mimarisi:** 
  - 1 x DB Node (`workload=database:NoSchedule` taint'i ve `tier=database` etiketi)
  - 2 x Web/Worker Node (`tier=web` etiketi)
- **Oracle Linux 9 / OCI OKE Uyumu:** Tüm imajlarda tam nitelikli alan adı (FQDN) kuralı uygulanmıştır (`docker.io`, `quay.io`, `registry.k8s.io`).
- **Trial & Kota Tasarrufu:** Prometheus ve Grafana pod'larının bellek tüketimini kontrol altında tutmak için hafifletilmiş (`monitoring/prometheus-values.yaml`) yapılandırma kullanılmıştır.

---

## Proje Dizin Yapısı

```text
k8s-sre-lab/
├── README.md                        # Adım adım SRE laboratuvar rehberi (bu dosya)
├── charts/
│   └── web-api/                     # Özel Mikroservis Helm Chart'ı
│       ├── Chart.yaml               # Chart metadata
│       ├── values.yaml              # Özelleştirilebilir parametreler
│       └── templates/
│           ├── deployment.yaml      # Deployment şablonu (probes, affinity, preStop)
│           ├── service.yaml         # Service şablonu
│           └── _helpers.tpl         # İsimlendirme ve etiket yardımcıları
├── monitoring/
│   ├── prometheus-values.yaml       # Kube-Prometheus-Stack OKE optimizasyon değerleri
│   ├── servicemonitor.yaml          # Uygulama metrik kazıma (scrape) kuralı
│   └── custom-alerts.yaml           # Özel CrashLoopBackOff & High CPU alarmları
└── batch/
    ├── 05-db-migrate-job.yaml       # Tek seferlik DB Migration/Seeding Job
    └── 06-db-backup-cronjob.yaml    # Periyodik pg_dump ve Block Volume CronJob
```

---

## Laboratuvar Müfredatı (10 Adım)

---

### Faz 1: Paket Yönetimi ve Helm Mimarisi

#### Adım 1: Helm 3 Kurulumu ve Repozituvar Mimarisi
**Görev:** Helm 3 CLI aracının durumunu doğrulayın, Artifact Hub ve resmi repozituvarları (bitnami, prometheus-community) ekleyip güncelleyin. `helm template` ile `helm install` farkını, dry-run ve sürüm takibi (`helm list`, `helm history`) komutlarını uygulayın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Helm sürümünü doğrulayın
helm version

# 2. Resmi topluluk Helm repozituvarlarını ekleyin
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# 3. Eklenen repozituvarları listeleyin
helm repo list

# 4. dry-run ve template mantığı:
# Template (Cluster bağlantısı olmadan ham render çıktısını üretir):
helm template my-test charts/web-api/

# Dry-run (Cluster API Server ile şemayı doğrular ancak nesneleri yaratmaz):
helm install my-test charts/web-api/ --dry-run --namespace production
```
</details>

***

#### Adım 2: Custom Microservice Helm Chart Tasarımı ve Dağıtımı
**Görev:** Web API mikroservisini kurumsal bir Helm Chart olarak (`charts/web-api/`) paketleyin. `values.yaml` üzerinden dinamik replica, resource, nodeSelector (`tier=web`) ve podAntiAffinity enjeksiyonunu test edin. Chart'ı `production` namespace'ine dağıtıp yükseltme (upgrade) ve geri alma (rollback) döngüsünü uygulayın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Chart sözdizimini (lint) kontrol edin
helm lint charts/web-api/

# 2. production namespace'ini oluşturun (mevcut değilse)
kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -

# 3. Helm Chart'ı dağıtın (Install)
helm install web-api charts/web-api/ \
  --namespace production \
  --set replicaCount=2

# 4. Dağıtımı ve pod'ların web node'larına yerleşimini doğrulayın
helm list -n production
kubectl get pods -n production -l app.kubernetes.io/name=web-api -o wide

# 5. Parametre güncelleme (Helm Upgrade ile replika sayısını 3 yapma)
helm upgrade web-api charts/web-api/ \
  --namespace production \
  --set replicaCount=3

# 6. Sürüm geçmişini inceleyin
helm history web-api -n production

# 7. Önceki sürüme geri dönme (Rollback - Revizyon 1'e dönüş)
helm rollback web-api 1 -n production
kubectl get pods -n production -l app.kubernetes.io/name=web-api
```
</details>

---

### Faz 2: Observability & Monitoring (Prometheus & Grafana)

#### Adım 3: Helm ile Kube-Prometheus-Stack Kurulumu (Production Tuning)
**Görev:** `kube-prometheus-stack` chart'ını, 3-node OKE kümesinin kaynak sınırlarına ve trial kotasına uygun olarak hazırlanan `monitoring/prometheus-values.yaml` ile deploy edin. Node-exporter DaemonSet'inin DB node'undaki (`workload=database:NoSchedule`) taint'i tolere ederek 3 node'un tamamından metrik toplamasını sağlayın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. monitoring namespace'ini oluşturun
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# 2. Optimize edilmiş değerlerle Kube-Prometheus-Stack chart'ını kurun
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/prometheus-values.yaml \
  --timeout 10m

# 3. Dağıtılan monitoring pod'larını ve node-exporter DaemonSet'ini doğrulayın
kubectl get pods -n monitoring
kubectl get ds -n monitoring

# 4. Node-exporter'ın 3 node'un tamamında çalıştığını doğrulayın (DESIRED = 3, READY = 3)
kubectl get ds kube-prometheus-stack-prometheus-node-exporter -n monitoring -o wide
```
</details>

***

#### Adım 4: Grafana Paneli ve Cluster Metriklerinin İncelenmesi
**Görev:** Grafana paneline port-forward veya LoadBalancer üzerinden erişin. Varsayılan kimlik bilgileri (`admin` / `prom-operator`) ile giriş yapıp Kubernetes Cluster (Nodes), Compute Resources (Pods) dashboard'larını inceleyin. Temel PromQL sorgularını çalıştırın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Grafana servisine port-forward başlatın (Ayrı terminalde veya arka planda)
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80 &

# 2. Tarayıcıdan erişin: http://localhost:3000
# Kullanıcı Adı: admin
# Parola       : prom-operator

# 3. Prometheus paneline erişim (İsteğe bağlı):
kubectl port-forward svc/kube-prometheus-stack-prometheus -n monitoring 9090:9090 &
# Tarayıcı: http://localhost:9090

# 4. Önemli PromQL Sorguları (Prometheus / Grafana Explore alanında test edin):
# - 5 dakikalık periyotta pod CPU kullanım oranları:
#   rate(container_cpu_usage_seconds_total{namespace="production"}[5m])
# - Pod bellek tüketimi (Megabyte):
#   container_memory_working_set_bytes{namespace="production"} / 1024 / 1024
# - Node bazlı toplam CPU kullanımı (%):
#   100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)
```
</details>

---

### Faz 3: Batch İş Yükleri ve Veri Operasyonları (Job & CronJob)

#### Adım 5: One-Off Veritabanı Migrasyon / Seeding Job'ı (K8s Job)
**Görev:** Uygulama başlamadan önce veritabanında tablo oluşturan ve örnek sipariş verilerini basan tek seferlik bir Kubernetes Job nesnesi (`batch/05-db-migrate-job.yaml`) çalıştırın. `backoffLimit: 3`, `restartPolicy: OnFailure` ve `activeDeadlineSeconds` kurallarının işleyişini inceleyin.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Job manifestosunu uygulayın
kubectl apply -f batch/05-db-migrate-job.yaml

# 2. Job'ın tamamlanmasını (Completed) bekleyin
kubectl wait --for=condition=complete job/db-migrate-job -n production --timeout=120s

# 3. Job loglarını inceleyerek veritabanı çıktısını doğrulayın
kubectl logs -n production job/db-migrate-job

# 4. Başarıyla tamamlanan Job'ı görüntüleyin
kubectl get job db-migrate-job -n production
```
</details>

***

#### Adım 6: Otomatik PostgreSQL Yedekleme CronJob'ı (K8s CronJob)
**Görev:** Her 30 dakikada bir otomatik çalışan, `pg_dump` alarak arşivleyen `batch/06-db-backup-cronjob.yaml` CronJob nesnesini uygulayın. `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3` direktiflerini doğrulayın ve test amaçlı manuel bir Job tetikleyin.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. CronJob ve PVC manifestosunu uygulayın
kubectl apply -f batch/06-db-backup-cronjob.yaml

# 2. CronJob nesnesini inceleyin
kubectl get cronjob -n production

# 3. Test için CronJob üzerinden anlık (manuel) bir Job tetikleyin
kubectl create job manual-backup-test --from=cronjob/db-backup-cronjob -n production

# 4. Manuel oluşturulan job'ın tamamlanmasını bekleyin ve logları okuyun
kubectl wait --for=condition=complete job/manual-backup-test -n production --timeout=180s
kubectl logs -n production job/manual-backup-test
```
</details>

***

#### Adım 7: OCI Block Volume Üzerinde Yedek Arşivleme ve Doğrulama
**Görev:** Alınan SQL dump arşivlerinin geçici konteyner diski yerine OCI Block Volume (`storageClassName: oci-bv`) PVC'sine kalıcı olarak yazıldığını doğrulayın. PVC durumunu ve depolama bağını inceleyin.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Yedekleme PVC durumunu doğrulayın (Bound olmalıdır)
kubectl get pvc db-backup-pvc -n production

# 2. Kalıcı disk içerisindeki yedek dosyalarını geçici bir pod ile kontrol edin
kubectl run storage-inspector -n production --rm -it --restart=Never \
  --image=docker.io/library/busybox:1.36 \
  --overrides='{
    "spec": {
      "tolerations": [{"key": "workload", "operator": "Equal", "value": "database", "effect": "NoSchedule"}],
      "nodeSelector": {"tier": "database"},
      "volumes": [{"name": "bk", "persistentVolumeClaim": {"claimName": "db-backup-pvc"}}],
      "containers": [{"name": "c", "image": "docker.io/library/busybox:1.36", "command": ["sh", "-c", "ls -lh /backup && zcat /backup/*.sql.gz | head -n 25"], "volumeMounts": [{"name": "bk", "mountPath": "/backup"}]}]
    }
  }'
```
</details>

---

### Faz 4: İleri SRE, Metrik İhracı ve Alerting

#### Adım 8: ServiceMonitor ile Uygulama Metriklerinin Otomatik Keşfi
**Görev:** Prometheus Operator'ün CRD nesnesi olan `ServiceMonitor` (`monitoring/servicemonitor.yaml`) manifestosunu uygulayın. Prometheus'un `web-api` mikroservisini otomatik olarak hedef (target) listesine eklediğini doğrulayın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. ServiceMonitor kaynağını uygulayın
kubectl apply -f monitoring/servicemonitor.yaml

# 2. ServiceMonitor nesnesinin durumunu kontrol edin
kubectl get servicemonitor -n monitoring

# 3. Prometheus Target listesinde web-api'nin göründüğünü doğrulayın
# (Prometheus arayüzünde Status -> Targets -> serviceMonitor/monitoring/web-api-monitor kontrol edilebilir)
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/targets | grep -o '"job":"web-api[^"]*"' | head -n 5
```
</details>

***

#### Adım 9: Prometheus Alertmanager Kuralı Tanımlama
**Görev:** Bir pod sürekli çöktüğünde (`PodCrashLooping`) veya CPU kotası %80'i aştığında (`HighPodCpuUsage`) tetiklenen kurumsal `PrometheusRule` alarm kurallarını (`monitoring/custom-alerts.yaml`) devreye alın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Özel alarm kurallarını uygulayın
kubectl apply -f monitoring/custom-alerts.yaml

# 2. PrometheusRule nesnesini inceleyin
kubectl get prometheusrule -n monitoring custom-sre-alerts

# 3. Prometheus'un kuralları yüklediğini doğrulayın:
# (Prometheus arayüzünde Alerts sekmesinde PodCrashLooping ve HighPodCpuUsage kuralları yeşil/INACTIVE olmalıdır)
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/rules | grep -o '"name":"PodCrashLooping"'
```
</details>

***

#### Adım 10: Sentetik Arıza Testi ve Dashboard Doğrulaması
**Görev:** Gerçek bir arıza senaryosu simüle edin: Sürekli çöken (exit 1) hatalı bir pod başlatarak `PodCrashLooping` alarmının `FIRING` durumuna geçmesini ve Grafana üzerinde arıza anını gözlemleyin. Test bitiminde temizlik yapın.

<details>
  <summary>Çözüm ve Komutlar için tıklayınız!</summary>

```bash
# 1. Sentetik Arıza: Sürekli çöken (CrashLoopBackOff) hatalı bir pod oluşturun
kubectl run synthetic-crash-pod -n production \
  --image=docker.io/library/busybox:1.36 \
  --restart=Always \
  -- /bin/sh -c "echo 'Hata olustu!'; exit 1"

# 2. Pod durumunu izleyin (CrashLoopBackOff durumuna geçmelidir)
kubectl get pod synthetic-crash-pod -n production -w

# 3. ~1-2 dakika sonra Alertmanager ve Prometheus üzerinde alarm durumunu sorgulayın
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/alerts | grep -o '"alertname":"PodCrashLooping"[^}]*'

# 4. Arıza simülasyonunu temizleyin
kubectl delete pod synthetic-crash-pod -n production --force --grace-period=0
```
</details>

---

## Önemli SRE İpuçları & Sorun Giderme (Troubleshooting)

1. **Oracle Linux 9 FQDN Kuralı:** İmaj adresi belirtirken `python:3.11-slim` yerine mutlaka `docker.io/library/python:3.11-slim` formatını kullanın; aksi halde OCI CRI-O motoru imajı çözümleyemeyebilir (`ImagePullBackOff`).
2. **Kube-Prometheus-Stack Bellek Optimizasyonu:** `prometheusSpec.resources.limits.memory` değerini 512MiB, `retention` değerini `24h` ve depolamayı `emptyDir` olarak tutarak OKE trial limitleri içinde kalırsınız.
3. **Node-Exporter DB Node Taint'i:** `prometheus-values.yaml` içerisinde `nodeExporter.tolerations` bloğuna `workload=database:NoSchedule` toleration'ı tanımlanmazsa 3. worker node'un donanım metrikleri kazınamaz.
4. **ServiceMonitor Keşif Sorunu:** Prometheus Operator'ün özel ServiceMonitor'leri bulabilmesi için `prometheusSpec.serviceMonitorSelectorNilUsesHelmValues: false` ayarı zorunludur.
