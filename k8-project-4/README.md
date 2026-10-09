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
