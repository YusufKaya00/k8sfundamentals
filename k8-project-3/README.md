**Proje Talimatları — OCI OKE Production Kubernetes Laboratuvarı**

> Çözümler için: [solution/README.md](./solution/README.md)

**1:** 3 worker node'lu (VM.Standard.E5.Flex, Oracle Linux 9, k8s v1.37.0) OKE cluster'ındaki node'ları listeleyin. 3. worker node'a `workload=database:NoSchedule` taint'i ve `tier=database` label'ı, diğer 2 worker node'a `tier=web` label'ı atayın.

**2:** "production" adında bir namespace oluşturun ve CPU, bellek, pod sayısı ve depolama kotalarını belirleyen ResourceQuota ile varsayılan limitleri atayan LimitRange tanımlarını uygulayın.

**3:** Dedicated Node Scheduling: Database iş yüklerinin 3. node'a, web iş yüklerinin web node'larına gitmesini sağlayacak taint/toleration ve nodeSelector mimarisini tasarlayın ve doğrulayın.

**4:** ConfigMap ve Secret ayrımı:
- Veritabanı kimlik bilgilerini içeren bir Secret ("postgres-secret") oluşturun.
- Uygulama ayarlarını (APP_ENV, PORT, LOG_LEVEL, DB_HOST, DB_PORT) tutan bir ConfigMap ("app-config") hazırlayın.

**5:** OCI Block Volume destekli PostgreSQL:
- "production" namespace'inde `storageClassName: oci-bv` kullanan 50Gi PVC ile PostgreSQL 16 veritabanını deploy edin.
- 3. node'daki taint'e uygun toleration ve nodeSelector tanımlayın.

**6 & 7:** Init-Container destekli ve Yüksek Erişilebilirlikli Web API Deployment:
- 2 replika web-api pod'unun 2 ayrı web node'una dengeli dağılması için `podAntiAffinity` ve `topologySpreadConstraints` (maxSkew: 1) kuralları ekleyin.
- Veritabanı portu (5432) dinlemeye başlayana kadar bekleyen bir Init-Container ekleyin.
- `startupProbe`, `readinessProbe`, `livenessProbe` ve connection drain için `lifecycle.preStop` (sleep 10) tanımlayın.

**8:** Güvenlik katmanı: "production" namespace'inde öyle bir NetworkPolicy oluşturun ki PostgreSQL pod'una yalnızca aynı namespace içerisindeki etiketli web uygulaması (`app: web-api`) erişebilsin, dışarıdan veya diğer pod'lardan gelen erişimler engellensin.

**9:** Web API'yi dış dünyaya açmak için OCI Flexible Load Balancer anotasyonlarını (`service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"`, min: 10, max: 40 Mbps) içeren bir LoadBalancer servisi oluşturun.

**10:** Headless service arkasında her pod'a bağımsız 10Gi `oci-bv` PVC bağlayan `volumeClaimTemplates` yapısına sahip 2 replikalı bir Redis StatefulSet deploy edin.

**11:** Web API için CPU kullanımı %60'ı aştığında pod sayısını min 2, max 8 yapacak bir HPA ve bakım anlarında en az 1 pod'un daima ayakta kalmasını garanti eden PodDisruptionBudget (`minAvailable: 1`) kuralı uygulayın.

**12:** Yalnızca `production` namespace'indeki `pods` ve `events` kaynaklarını get/list edebilen bir ServiceAccount, Role ve RoleBinding oluşturun. Bu ServiceAccount'ı kullanan bir curl pod'u üzerinden cluster API'sine HTTPS isteği atarak çalışan pod listesini çekin.

**13:** Planlı Bakım ve Güvenli Drenaj (Maintenance): Web pod'unun çalıştığı worker node'u tespit edin, `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` ile pod'ların PDB kurallarına uygun şekilde diğer node'a taşınmasını sağlayın. Node'u `cordon` ve `uncordon` döngüsüyle doğrulayın.
