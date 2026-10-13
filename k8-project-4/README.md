# 📊 Lab 4: Enterprise SRE & Observability (Helm 3, Prometheus-Stack, Grafana & Batch Workloads)

This lab simulates real-world SRE operations across package management (**Helm 3**), full-stack observability (**kube-prometheus-stack**, **Prometheus Operator**, **Grafana**, **PromQL**, **ServiceMonitors**, **Alertmanager**), and resilient batch workloads (**Kubernetes Jobs & CronJobs** with OCI Block Volume persistence).

> **Solutions / Çözümler:** Step-by-step SRE execution commands and verification steps:  
> **👉 [Explore Solution Guide (solution/README.md)](./solution/README.md)**

---

## 📋 Infrastructure & Environment Constraints

- **3 Worker Node Architecture:**
  - 1 x Dedicated Database Node (`workload=database:NoSchedule`, `tier=database`)
  - 2 x Web / Worker Nodes (`tier=web`)
- **Enterprise Container Runtimes (Oracle Linux 9 / OCI OKE):** All images must specify fully qualified domain names (FQDN) (e.g., `docker.io/library/python:3.11-slim`).
- **Resource Optimization:** Tuned configurations (`monitoring/prometheus-values.yaml`) to run Prometheus and Grafana smoothly within compute quotas.

---

## 📋 Curriculum Steps (10 Steps)

### Step 1: Helm 3 Package Management & Repository Operations
Verify the Helm 3 CLI environment. Add official chart repositories (`prometheus-community`, `bitnami`) and update repositories. Understand declarative templating vs. live cluster installations (`helm template` vs. `helm install --dry-run`).

### Step 2: Custom Microservice Helm Chart Architecture
- Develop a production-ready Helm Chart in `charts/web-api/` (`Chart.yaml`, `values.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/_helpers.tpl`).
- Parameterize `nodeSelector` and `podAntiAffinity` so pods target `tier=web` worker nodes.
- Make graceful shutdown (`preStop: sleep 10`) and multi-stage health probes (`startupProbe`, `readinessProbe`, `livenessProbe`) fully customizable via `values.yaml`.
- Deploy to the `production` namespace with 2 replicas, and validate lifecycle rollbacks (`helm upgrade` and `helm rollback`).

### Step 3: Production-Tuned Kube-Prometheus-Stack Deployment
- Install `kube-prometheus-stack` into the `monitoring` namespace using `monitoring/prometheus-values.yaml`.
- Ensure the `node-exporter` DaemonSet carries tolerations for `workload=database:NoSchedule` to collect node metrics across all 3 nodes.
- Configure 24-hour metric retention and lightweight resource boundaries for Prometheus and Grafana.

### Step 4: Grafana Dashboards & PromQL Telemetry Inspection
- Port-forward Grafana (`3000:80`) and authenticate with default credentials (`admin` / `prom-operator`).
- Inspect Kubernetes cluster dashboards (Node Metrics, Workload Resources).
- Execute PromQL queries in Prometheus / Grafana Explore to calculate container CPU usage (`rate(container_cpu_usage_seconds_total[5m])`) and memory saturation.

### Step 5: One-Off Database Migration & Seeding Job (Kubernetes Job)
- Deploy a Kubernetes `Job` (`batch/05-db-migrate-job.yaml`) that runs before the web application to provision the `customer_orders` schema and seed sample data in PostgreSQL.
- Configure failure recovery: `restartPolicy: OnFailure`, `backoffLimit: 3`, and `activeDeadlineSeconds: 300` with tolerations for the database tier.

### Step 6: Automated PostgreSQL Backup CronJob (Kubernetes CronJob)
- Deploy a scheduled `CronJob` (`batch/06-db-backup-cronjob.yaml`) executing periodic `pg_dump` backups (`schedule: "*/30 * * * *"`).
- Set `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, and `failedJobsHistoryLimit: 2`. Manually trigger a one-off run for validation.

### Step 7: Persistent Backup Archival on OCI Block Volume
- Mount an independent PersistentVolumeClaim backed by OCI Block Volume (`storageClassName: oci-bv`) to preserve `.sql.gz` backup archives across pod lifecycles.
- Validate persistent file integrity via a debug pod.

### Step 8: Auto-Discovery with ServiceMonitor CRD
- Deploy a Prometheus Operator `ServiceMonitor` (`monitoring/servicemonitor.yaml`) to enable Prometheus scraping for the `web-api` microservice.
- Verify target status is `UP` in the Prometheus Targets dashboard.

### Step 9: Alertmanager Rules for SRE Incident Detection
- Create a `PrometheusRule` (`monitoring/custom-alerts.yaml`) defining alerts for `PodCrashLooping` (CrashLoopBackOff) and `HighPodCpuUsage` (>80% CPU request threshold).
- Confirm rules are loaded and active in the Prometheus Alerts UI.

### Step 10: Synthetic Failure Injection & Incident Triage
- Deploy a deliberately failing pod (`synthetic-crash-pod`, exit 1) to generate a CrashLoopBackOff incident.
- Observe metric spikes and watch the `PodCrashLooping` alert transition from `PENDING` to `FIRING` in Grafana and Prometheus. Clean up test workloads.

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

**Proje Talimatları — Enterprise SRE & Observability Laboratuvarı (Helm, Monitoring & Batch)**

> Çözümler için: [solution/README.md](./solution/README.md)

**Altyapı Notu:**
- 3 Worker Node: 1 x DB Node (`workload=database:NoSchedule`, `tier=database`), 2 x Web/Worker Node (`tier=web`).
- Oracle Linux 9 / OKE uyumu için tüm imajlarda tam FQDN (ör. `docker.io/library/python:3.11-slim`) kullanılmalıdır.
- Prometheus ve Grafana pod'ları trial kaynak sınırlarını aşmayacak şekilde hafifletilmiş konfigürasyon ile çalıştırılmalıdır.

---

### Görev Adımları:

**1:** Helm 3 CLI kurulumunu ve sürümünü doğrulayın. Artifact Hub ve resmi repozituvarları (`bitnami`, `prometheus-community`) sisteme ekleyin. `helm template` ile `helm install` arasındaki farkı ve dry-run mantığını kavrayıp repozituvar listesini güncelleyin.

**2:** Custom Microservice Helm Chart Tasarımı:
- `charts/web-api/` altında profesyonel bir Helm Chart oluşturun (`Chart.yaml`, `values.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/_helpers.tpl`).
- Pod'ların yalnızca `tier=web` etiketli worker node'lara yerleşmesi için `nodeSelector` ve `podAntiAffinity` kurallarını şablonlayın.
- Graceful shutdown (`preStop: sleep 10`) ve sağlık kontrollerini (`startupProbe`, `readinessProbe`, `livenessProbe`) values üzerinden yapılandırılabilir hale getirin.
- Chart'ı `production` namespace'inde 2 replika ile deploy edip `helm upgrade` ve `helm rollback` döngüsüyle sürüm yönetimini test edin.

**3:** Helm ile Kube-Prometheus-Stack Kurulumu (Production Tuning):
- `prometheus-community/kube-prometheus-stack` chart'ını OKE 3-node kümesine göre optimize edilmiş `monitoring/prometheus-values.yaml` ile `monitoring` namespace'ine kurun.
- `node-exporter` DaemonSet'inin DB node'undaki (`workload=database:NoSchedule`) taint'i tolere ederek 3 node'un tamamından metrik toplamasını sağlayın.
- Prometheus için 24 saatlik retention ve `emptyDir` depolama, Grafana için hafif kaynak limitleri belirleyin.

**4:** Grafana Paneli ve Cluster Metriklerinin İncelenmesi:
- Grafana servisini port-forward üzerinden (`3000:80`) açıp `admin` / `prom-operator` bilgileriyle giriş yapın.
- Kubernetes Nodes ve Compute Resources dashboard'larını inceleyin.
- Prometheus / Grafana Explore ekranında CPU ve Memory için temel PromQL sorgularını (`rate(container_cpu_usage_seconds_total[5m])`, bellek tüketimi) çalıştırın.

**5:** One-Off Veritabanı Migrasyon / Seeding Job'ı (K8s Job):
- Uygulama başlamadan önce PostgreSQL veritabanına bağlanıp `customer_orders` tablosunu oluşturan ve örnek veri basan bir Kubernetes Job nesnesi (`batch/05-db-migrate-job.yaml`) tanımlayın.
- `restartPolicy: OnFailure`, `backoffLimit: 3` ve `activeDeadlineSeconds: 300` kuralları ile başarısızlık yönetimini sağlayın. Job'ın DB node'una yerleşmesi için toleration tanımlayın.

**6:** Otomatik PostgreSQL Yedekleme CronJob'ı (K8s CronJob):
- Belirli periyotlarla (`schedule: "*/30 * * * *"`) çalışıp `pg_dump` alarak sıkıştıran kurumsal bir CronJob (`batch/06-db-backup-cronjob.yaml`) oluşturun.
- `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3` ve `failedJobsHistoryLimit: 2` direktiflerini ekleyin. Test için manuel bir job tetikleyerek doğruluğunu test edin.

**7:** OCI Block Volume Üzerinde Yedek Arşivleme:
- Alınan SQL dump yedeklerinin geçici pod diski yerine kalıcı bir OCI Block Volume (`storageClassName: oci-bv`) PVC'sine yazılmasını sağlayın.
- Geçici bir pod üzerinden kalıcı disk içerisindeki `.sql.gz` arşivlerini doğrulayın.

**8:** Custom Exporter ve ServiceMonitor Entegrasyonu:
- Prometheus Operator'ün `ServiceMonitor` CRD nesnesini (`monitoring/servicemonitor.yaml`) kullanarak `web-api` mikroservisinin metrik uç noktasının Prometheus tarafından otomatik keşfedilmesini (auto-discovery) sağlayın.
- Prometheus Targets sayfasında servisin UP durumunda olduğunu doğrulayın.

**9:** Prometheus Alertmanager Kuralı Tanımlama:
- SRE senaryosu: Bir pod sürekli çöktüğünde (`PodCrashLooping` / `CrashLoopBackOff`) veya CPU kotası %80'i aştığında (`HighPodCpuUsage`) tetiklenecek özel bir `PrometheusRule` (`monitoring/custom-alerts.yaml`) oluşturun.
- Kuralların Prometheus Alerts ekranına yüklendiğini doğrulayın.

**10:** Sentetik Arıza Testi ve Dashboard Doğrulaması:
- Sürekli çöken (exit 1) sentetik bir test pod'u (`synthetic-crash-pod`) başlatarak CrashLoopBackOff senaryosu oluşturun.
- Grafana ve Prometheus üzerinde arıza anını, metrik değişimini ve `PodCrashLooping` alarmının `FIRING` durumuna geçişini gözlemleyin. Test sonrası temizlik yapın.
