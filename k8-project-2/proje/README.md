**Proje Talimatları — Modern Kubernetes Platform Laboratuvarı (Minikube)**

> Çözümler için: [cozum/README.md](./cozum/README.md)

**1:** 5 node'lu (1 Control-Plane + 4 Worker) bir Minikube cluster'ı kurun ve metric-server ile ingress eklentilerini aktif hale getirin.

**2:** "staging" ve "production" adlarında 2 farklı namespace oluşturun.

**3:** Cluster'daki 2 worker node'u sadece "production" kritik iş yükleri için ayırın:

- Bu iki node'a "dedicated=production:NoSchedule" taint'i ekleyin.
- Aynı node'lara "environment=production" label'ı verin.

**4:** Güvenlik katmanı: "staging" namespace'inde öyle bir NetworkPolicy oluşturun ki PostgreSQL pod'una yalnızca aynı namespace içerisindeki etiketli web uygulaması erişebilsin, dışarıdan veya diğer pod'lardan gelen erişimler engellensin.

**5:** ConfigMap ve Secret ayrımı:

- Veritabanı kullanıcı adı ve şifresini içeren bir Secret ("postgres-creds") oluşturun.
- Uygulama ayarlarını (LOG_LEVEL, PORT, CACHE_ENABLED) tutan bir ConfigMap ("app-config") hazırlayın.

**6:** Init-Container destekli Web + PostgreSQL Stack:

- "production" ve "staging" namespace'lerinde PostgreSQL 16 veritabanını PVC ile deploy edin.
- Web uygulamasının (ör: Python/Node.js REST API) pod tanımına bir Init-Container ekleyin; bu init container veritabanı portu (5432) dinlemeye başlayana kadar (netcat / pg_isready ile) ana web container'ının başlamasını bekletsin.
- "production" pod'ları 3. adımdaki taint'e uygun toleration ve nodeAffinity ile işaretlenmiş node'larda çalışsın.

**7:** Ingress ile Path ve Host Tabanlı Yönlendirme:

- "staging" ortamı için "staging.lab.internal" hostu,
- "production" ortamı için "api.lab.internal" hostu ve "/metrics" yolu için farklı bir backend servisine yönlenen güncel "networking.k8s.io/v1" Ingress kuralı tanımlayın.

**8:** Veritabanı Yedekleme CronJob'u (Batch Processing):

- Her gece 02:00'de (test için elle tetiklenebilir biçimde) çalışıp veritabanından dump alıp shared bir PVC'ye yazan veya stdout'a başarılı log üreten bir CronJob ("db-backup-job") tanımlayın.

**9:** Horizontal Pod Autoscaler (HPA) ve Pod Disruption Budget (PDB):

- Production web deployment'ı için CPU kullanımı %60'ı aştığında pod sayısını min 2, max 8 yapacak bir HPA tanımlayın.
- Bakım anlarında en az 1 pod'un daima ayakta kalmasını garanti eden PodDisruptionBudget (PDB) kuralı uygulayın.

**10:** Cluster-Wide Log DaemonSet:

- Node'ların "/var/log" dizinini hostPath ile mount eden ve production taint'ini tolere ederek tüm worker'larda çalışan bir "fluent-bit" DaemonSet'i yapılandırın.

**11:** StatefulSet ile 2 Replikalı Redis Cluster / Replica:

- "volumeClaimTemplates" kullanan, headless service arkasında stabil network kimliğine sahip 2 replikalı bir Redis StatefulSet'i deploy edin.

**12:** In-Cluster API İstemcisi ve ServiceAccount:

- Sadece bulunduğu namespace içerisindeki Job ve Pod nesnelerini listeleyebilen ("get", "list") bir ServiceAccount ve Role/RoleBinding oluşturun.
- Bu ServiceAccount'ı kullanan bir curl pod'u üzerinden cluster API'sine (/api/v1/namespaces/{ns}/pods) HTTPS isteği atarak çalışan pod listesini JSON olarak çekin.

**13:** Planlı Bakım ve Güvenli Drenaj (Maintenance):

- Üzerinde pod çalışan bir worker node'u drain ederek mevcut pod'ların PDB kurallarına uygun şekilde diğer node'lara taşınmasını sağlayın. Node'u cordon ve uncordon döngüsüyle doğrulayın.
