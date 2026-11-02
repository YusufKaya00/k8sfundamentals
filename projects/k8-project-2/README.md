# 🛡️ Lab 2: Multi-Tier Microservices & Platform Hardening (Minikube 5-Node)

This lab builds an enterprise-grade platform on a 5-node Minikube cluster (1 Control Plane + 4 Workers), implementing environment segmentation (`staging` vs. `production`), dedicated worker node taints & labels, zero-trust L4 NetworkPolicies (PostgreSQL isolation), InitContainers, Ingress L7 path/host routing, backup CronJobs, Horizontal Pod Autoscaling (HPA), Pod Disruption Budgets (PDB), cluster-wide logging DaemonSets, Redis StatefulSets, in-cluster RBAC API clients, and safe node drain operations.

> **Solutions / Çözümler:** Step-by-step solutions and commands are documented in [solution/README.md](./solution/README.md).

---

## 📋 English Instructions

**1:** Provision a 5-node Minikube cluster (1 Control Plane + 4 Workers) with the Calico CNI (to enforce NetworkPolicies), and enable `metrics-server` and `ingress` addons.

**2:** Create two distinct environments: `staging` and `production` namespaces.

**3:** Dedicate 2 worker nodes exclusively for mission-critical `production` workloads:
- Apply taint: `dedicated=production:NoSchedule`.
- Apply label: `environment=production`.

**4:** Zero-Trust Network Security:
- In the `staging` namespace, enforce a `NetworkPolicy` allowing inbound traffic to the PostgreSQL pod **only** from the labeled web application pod within the same namespace. Deny all other inter-pod and external ingress traffic.

**5:** Configuration & Secret Decoupling:
- Create a `Secret` (`postgres-creds`) containing sensitive database credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`).
- Create a `ConfigMap` (`app-config`) storing application configuration (`LOG_LEVEL`, `PORT`, `CACHE_ENABLED`).

**6:** Resilient Microservice Stack with InitContainer:
- Deploy PostgreSQL 16 backed by PersistentVolumeClaims in both `staging` and `production`.
- In the web application pod (e.g., Python/Node.js REST API), configure an `initContainer` that polls database readiness on port 5432 using `pg_isready` or `nc` before the primary web container starts.
- Ensure `production` pods schedule strictly onto dedicated nodes using appropriate `tolerations` and `nodeAffinity`.

**7:** L7 Ingress Routing (Host & Path Based):
- Configure an `ingress` resource routing:
  - `staging.lab.internal` to the staging web service.
  - `api.lab.internal` to the production web service.
  - `api.lab.internal/metrics` to an internal metrics backend.

**8:** Scheduled Database Backups (CronJob):
- Deploy a nightly backup `CronJob` (`db-backup-job`) scheduled at 02:00 UTC (manually triggerable for validation) that dumps database tables and logs backup status.

**9:** Elastic Autoscaling & High Availability:
- Implement a `HorizontalPodAutoscaler` (HPA) for the production web deployment targeting 60% CPU utilization (min 2, max 8 replicas).
- Implement a `PodDisruptionBudget` (PDB) guaranteeing `minAvailable: 1` during node maintenance and voluntary disruptions.

**10:** Cluster-Wide Logging DaemonSet:
- Deploy a `fluent-bit` DaemonSet mounting host `/var/log` paths via `hostPath`, tolerating production taints to run on every worker node.

**11:** Distributed In-Memory Cache (Redis StatefulSet):
- Deploy a 2-replica Redis StatefulSet using `volumeClaimTemplates` and a Headless Service (`redis-headless`) for stable network identities and predictable storage bindings.

**12:** In-Cluster RBAC Client & API Querying:
- Create a dedicated `ServiceAccount`, `Role`, and `RoleBinding` granting read-only permissions (`get`, `list`) restricted to Jobs and Pods in the local namespace.
- Deploy an ephemeral curl container using this ServiceAccount to securely query the cluster API endpoint (`/api/v1/namespaces/{ns}/pods`) using the projected JWT bearer token.

**13:** Graceful Node Maintenance & Drain:
- Drain an active worker node hosting application pods (`kubectl drain`), verifying that pods are safely rescheduled onto alternate nodes respecting PDB guarantees. Cordon and uncordon the node.

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

**Proje Talimatları — Modern Kubernetes Platform Laboratuvarı (Minikube)**

> Çözümler için: [solution/README.md](./solution/README.md)

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
