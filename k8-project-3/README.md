# OCI OKE Production Kubernetes Laboratuvarı

Bu laboratuvar projesi, **Oracle Cloud Infrastructure (OCI) Container Engine for Kubernetes (OKE)** üzerinde çalışan **3 worker node'lu (VM.Standard.E5.Flex, Oracle Linux 9, k8s v1.37.0)** gerçek bir üretim kümesinde uygulanmak üzere tasarlanmıştır.

Laboratuvar müfredatı; kurumsal seviyede **Dedicated Node Taints/Tolerations, OCI Block Volume (oci-bv CSI), Yüksek Erişilebilirlik (TopologySpread, PodAntiAffinity), Zero-Downtime Graceful Shutdown (preStop), Mikro Segmentasyon (NetworkPolicy), OCI Flexible Load Balancer, Headless Service & StatefulSet, HPA, PDB, RBAC ve Planlı Bakım (Drain/Cordon)** konularını uçtan uca kapsar.

> Adım adım komutlar, mimari gerekçeler, doğrulama adımları ve OCI sorun giderme kılavuzu için:  
> **👉 [Çözüm Rehberini İnceleyin (solution/README.md)](./solution/README.md)**

---

## Laboratuvar Müfredatı (13 Adım)

### Adım 1: OKE Worker Node Keşfi, Etiketleme ve Taint Yönetimi
3 worker node'lu OKE kümesindeki node'ları listeleyin. Üçüncü worker node'u yalnızca kritik veritabanı iş yüklerine ayırmak üzere `workload=database:NoSchedule` taint'i ve `tier=database` etiketi ile işaretleyin. Diğer 2 worker node'a ise ön yüz iş yüklerini karşılamak üzere `tier=web` etiketini atayın.

### Adım 2: Çoklu Kiracılık (Multi-Tenancy) ve Kaynak Kotaları
Üretim ortamı için `production` adında bir namespace oluşturun. OKE kümesinde kontrolsüz kaynak tüketimini ve noisy-neighbor sorununu engellemek amacıyla CPU, bellek, pod sayısı ve depolama kotalarını sınırlandıran `ResourceQuota` ile varsayılan limitleri belirleyen `LimitRange` kurallarını uygulayın (`02-namespaces-and-quotas.yaml`).

### Adım 3: Dedicated Node Scheduling ve İş Yükü Ayrımı Mimarisi
Veritabanı pod'larının yalnızca 3. node'da, web pod'larının ise web node'larında çalışmasını garanti eden scheduling kurallarını ve taint/toleration ile nodeSelector/nodeAffinity mekanizmalarını mimari olarak kurgulayın.

### Adım 4: Güvenli Konfigürasyon ve Secret Yönetimi
Hassas veritabanı kimlik bilgilerini (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB) Kubernetes `Secret` nesnesinde; uygulama çalışma zamanı ayarlarını (APP_ENV, PORT, LOG_LEVEL, DB_HOST, DB_PORT) ise `ConfigMap` nesnesinde birbirinden izole biçimde tanımlayın (`04-config-and-secret.yaml`).

### Adım 5: OCI Block Volume CSI ile Kalıcı PostgreSQL Dağıtımı
Minikube yerel diskleri yerine gerçek bulut blok depolaması (`storageClassName: oci-bv`) kullanarak dinamik olarak OCI Block Volume talep eden bir PVC oluşturun. PostgreSQL 16 veritabanını, 3. node'daki taint'i tolere edecek ve yalnızca `tier=database` node'una yerleşecek şekilde `ClusterIP` servisiyle birlikte deploy edin (`05-postgres-pvc-deployment.yaml`).

### Adım 6: InitContainer ile Veritabanı Bağımlılığı Yönetimi ve Sağlık Kontrolleri
2 replikalı bir Web REST API deployment'ı oluşturun. Pod içerisine bir InitContainer ekleyerek PostgreSQL veritabanı portu (5432) erişilebilir olana kadar ana container'ın başlamasını bekletin. Pod'un sağlıklı durumunu denetlemek için `startupProbe`, `readinessProbe` ve `livenessProbe` kontrollerini tanımlayın (`06-07-web-deployment.yaml`).

### Adım 7: Yüksek Erişilebilirlik (Anti-Affinity, Topology Spread) ve Zero-Downtime Shutdown
Web pod'larının tek bir node'da kümelenmesini önlemek ve 2 web node'una homojen dağıtmak için `podAntiAffinity` ile `topologySpreadConstraints` (maxSkew: 1, topologyKey: kubernetes.io/hostname) kurallarını uygulayın. Rolling update ve termination sırasında bağlantı kaybını önlemek (connection draining) amacıyla `lifecycle.preStop` (`sleep 10`) hook'unu yapılandırın (`06-07-web-deployment.yaml`).

### Adım 8: Mikro Segmentasyon ve Ağ Güvenliği (NetworkPolicy)
Default-Deny Ingress felsefesine uygun olarak, PostgreSQL pod'una gelen trafiği tamamen izole eden bir `NetworkPolicy` uygulayın. PostgreSQL portuna (5432/TCP) sadece aynı namespace içerisindeki `app: web-api` etiketine sahip yetkili pod'ların erişebilmesini, diğer tüm pod ve dış erişimlerin engellenmesini sağlayın (`08-network-policy.yaml`).

### Adım 9: OCI Native Flexible Load Balancer ile Dış Dünyaya Erişim
Web API uygulamasını OCI Cloud Controller Manager (CCM) entegrasyonlu bir `LoadBalancer` servisiyle dış dünyaya açın. OCI esnek yük dengeleyici anotasyonlarını kullanarak bant genişliğini minimum 10 Mbps, maksimum 40 Mbps dinamik aralıkta yapılandırın (`09-web-loadbalancer-service.yaml`).

### Adım 10: OCI Block Volume Destekli Redis StatefulSet Dağıtımı
Stabil ağ kimliği sunan Headless Service (`clusterIP: None`) arkasında çalışan 2 replikalı bir Redis StatefulSet dağıtın. `volumeClaimTemplates` kullanarak her bir replika pod için dinamik olarak bağımsız 10Gi `oci-bv` Block Volume diski tahsis edilmesini sağlayın (`10-redis-statefulset.yaml`).

### Adım 11: Otomatik Yatay Ölçeklendirme (HPA) ve Kesinti Bütçesi (PDB)
Web API deployment'ı için ortalama CPU kullanımı %60'ı aştığında pod sayısını dinamik olarak artıran (min: 2, max: 8) bir `HorizontalPodAutoscaler` yapılandırın. Node bakım veya tahliye anlarında servisin kesintiye uğramasını önlemek adına en az 1 web pod'unun daima ayakta kalmasını garanti eden `PodDisruptionBudget` (`minAvailable: 1`) kuralını devreye alın (`11-hpa-and-pdb.yaml`).

### Adım 12: En Az Yetki Prensibi (RBAC) ve In-Cluster API İstemcisi
Kubernetes API Server ile güvenli haberleşme için en az yetki prensibine uygun bir `ServiceAccount`, yalnızca `production` namespace'indeki `pods` ve `events` kaynaklarını get/list edebilen bir `Role` ve bu ikisini bağlayan bir `RoleBinding` oluşturun. Bu ServiceAccount kimliğini kullanan güvenli bir curl pod'u üzerinden cluster API'sine (`/api/v1/namespaces/production/pods` ve `/events`) HTTPS sorgusu atarak yetkileri doğrulayın (`12-rbac-and-client-pod.yaml`).

### Adım 13: Planlı Bakım ve Güvenli Drenaj Operasyonu (Maintenance & Drain)
Üzerinde aktif web pod'u çalışan bir worker node'u tespit edin. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` komutunu işleterek tahliye sürecini başlatın. PodDisruptionBudget kuralının trafiği nasıl koruduğunu ve pod'un diğer web node'una kesintisiz geçişini gözlemleyin. Bakım senaryosu tamamlandıktan sonra node'u `kubectl uncordon` ile tekrar çizelgelemeye açın.

---

## Dizin Yapısı

```text
.
├── README.md                                # 13 Adımlık OKE Müfredatı (bu dosya)
└── solution/
    ├── README.md                            # Uçtan uca çözüm komutları, mimari gerekçeler ve troubleshooting
    ├── 02-namespaces-and-quotas.yaml        # Namespace, ResourceQuota ve LimitRange
    ├── 04-config-and-secret.yaml            # Secret ve ConfigMap
    ├── 05-postgres-pvc-deployment.yaml      # OCI Block Volume PVC ve PostgreSQL 16 Deployment
    ├── 06-07-web-deployment.yaml            # Web API Deployment (InitContainer, Probes, Topology, preStop)
    ├── 08-network-policy.yaml               # PostgreSQL Default-Deny Ingress NetworkPolicy
    ├── 09-web-loadbalancer-service.yaml     # OCI Flexible Load Balancer (10-40 Mbps) Service
    ├── 10-redis-statefulset.yaml            # Headless Service ve 10Gi oci-bv volumeClaimTemplates Redis StatefulSet
    ├── 11-hpa-and-pdb.yaml                  # CPU %60 HPA ve minAvailable: 1 PDB
    └── 12-rbac-and-client-pod.yaml          # ServiceAccount, Role, RoleBinding ve API Client Pod
```
