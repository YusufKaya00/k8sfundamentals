# ☁️ Lab 3: Production Enterprise Platform on Oracle Cloud Infrastructure (OCI OKE)

This lab guides you through the deployment and operational lifecycle of an enterprise-grade platform on a live 3-worker node **Oracle Cloud Infrastructure Container Engine for Kubernetes (OKE)** cluster (`VM.Standard.E5.Flex`, Oracle Linux 9 UEK, Kubernetes v1.37.0).

Key production topics covered: **Dedicated Worker Taints & Labels, Multi-Tenancy Quotas (`ResourceQuota` / `LimitRange`), Workload Scheduling Architecture, OCI Native Block Volume (`oci-bv` CSI) Storage, InitContainers & Multi-Stage Probes, High Availability (`podAntiAffinity`, `topologySpreadConstraints`), Zero-Downtime Graceful Shutdown (`preStop`), Zero-Trust Microsegmentation (`NetworkPolicy`), OCI Flexible Load Balancers (10-40 Mbps dynamic shaping), Redis StatefulSet with Headless Services, HPA & PDB, In-Cluster RBAC Client Pods, and Planned Cloud Node Drain Operations.**

> **Solutions / Çözümler:** For step-by-step commands, architectural rationale, verification outputs, and cloud troubleshooting:  
> **👉 [Explore Solution Guide (solution/README.md)](./solution/README.md)**

---

## 📋 Curriculum Steps (13 Steps)

### Step 1: OKE Worker Node Discovery, Labeling, and Dedicated Taints
Inspect the 3-node OKE worker pool. Designate the 3rd worker node strictly for stateful database workloads by applying the `workload=database:NoSchedule` taint and `tier=database` label. Label the first two worker nodes with `tier=web` for frontend and application services.

### Step 2: Enterprise Multi-Tenancy & Resource Governance
Create the `production` namespace. Enforce strict resource governance against noisy-neighbor starvation using `ResourceQuota` (CPU, memory, pod count, PVC volume limits) and `LimitRange` (default request/limit injections) (`02-namespaces-and-quotas.yaml`).

### Step 3: Dedicated Node Scheduling & Workload Separation Architecture
Implement a bi-directional scheduling policy:
- **Repel mechanism:** The `workload=database:NoSchedule` taint repels any workloads lacking explicit tolerations.
- **Attract mechanism:** Database workloads use matching tolerations and `nodeSelector: { tier: database }`, while web services target `tier=web` nodes.

### Step 4: Configuration & Secret Decoupling
Decouple sensitive database credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`) into a Kubernetes `Secret`. Externalize environment configuration parameters (`APP_ENV`, `PORT`, `LOG_LEVEL`, `DB_HOST`, `DB_PORT`) into a `ConfigMap` (`04-config-and-secret.yaml`).

### Step 5: Persistent PostgreSQL Deployment via OCI Block Volume CSI
Move beyond ephemeral local storage by utilizing the cloud-native `oci-bv` CSI driver (`blockvolume.csi.oraclecloud.com`). Provision a 50Gi PersistentVolumeClaim and deploy PostgreSQL 16 on the dedicated database node with a `Recreate` update strategy and `ClusterIP` Service (`05-postgres-pvc-deployment.yaml`).

### Step 6: Dependency Management via InitContainer & Comprehensive Health Probes
Deploy a 2-replica Web REST API. Embed an `initContainer` running `pg_isready` to block web container startup until PostgreSQL accepts connections on port 5432. Configure `startupProbe` (slow-start buffer), `readinessProbe` (traffic gating), and `livenessProbe` (crash detection) (`06-07-web-deployment.yaml`).

### Step 7: High Availability (Anti-Affinity, Topology Spread) & Zero-Downtime Shutdown
Evenly distribute web pods across the two web worker nodes using `podAntiAffinity` and `topologySpreadConstraints` (`maxSkew: 1`, `topologyKey: kubernetes.io/hostname`). Implement a `lifecycle.preStop` hook (`sleep 10`) to drain in-flight TCP connections during rolling updates and node evictions (`06-07-web-deployment.yaml`).

### Step 8: Zero-Trust Microsegmentation (NetworkPolicy)
Enforce a Default-Deny Ingress policy for PostgreSQL. Allow incoming 5432/TCP connections strictly from authenticated pods labeled `app: web-api` within the `production` namespace, blocking all other namespaces and external access (`08-network-policy.yaml`).

### Step 9: Public Ingress via OCI Flexible Load Balancer
Expose the Web API through an OCI Cloud Controller Manager (CCM) integrated `LoadBalancer` Service. Use OCI native annotations to provision a flexible load balancer dynamically shaped between 10 Mbps and 40 Mbps bandwidth (`09-web-loadbalancer-service.yaml`).

### Step 10: Distributed Caching with Redis StatefulSet & Cloud Block Volumes
Deploy a 2-replica Redis StatefulSet backed by a Headless Service (`clusterIP: None`) for deterministic DNS endpoints. Utilize `volumeClaimTemplates` to dynamically provision independent 10Gi `oci-bv` block volumes for each replica (`10-redis-statefulset.yaml`).

### Step 11: Elastic Autoscaling (HPA) & Pod Disruption Budget (PDB)
Configure a `HorizontalPodAutoscaler` (HPA) targeting 60% average CPU utilization (scaling between 2 and 8 replicas). Deploy a `PodDisruptionBudget` (`minAvailable: 1`) to ensure high availability during planned maintenance and node drains (`11-hpa-and-pdb.yaml`).

### Step 12: Least-Privilege RBAC & Secure In-Cluster API Client
Create a dedicated `ServiceAccount`, `Role`, and `RoleBinding` granting read-only permissions (`get`, `list`) restricted to pods and events in `production`. Verify access via `auth can-i` and by launching an authenticated curl container querying the Kubernetes API over HTTPS (`12-rbac-and-client-pod.yaml`).

### Step 13: Planned Maintenance & Live Node Drain Operations
Identify an active worker node hosting web pods and initiate node eviction using `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`. Validate that the PDB prevents service outages and forces graceful rescheduling to the remaining web node. Uncordon the node after maintenance (`kubectl uncordon`).

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

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
