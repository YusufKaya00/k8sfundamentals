# 🚀 Cloud-Native Kubernetes & DevOps Engineering Workspace

Welcome to the comprehensive **Kubernetes, Cloud Infrastructure, and Site Reliability Engineering (SRE)** repository. This repository represents an end-to-end journey from foundational container orchestration to enterprise-grade DevSecOps, GitOps, observability, and real-world production incident response simulations.

All projects and troubleshooting scenarios are fully reproducible on local clusters (**Minikube**) and production cloud environments (**Oracle Cloud Infrastructure Container Engine for Kubernetes - OKE**).

---

## 🧭 Repository Structure & Curriculum Index

```text
k8sfundamentals/
├── k8-project-1/       # Kubernetes Foundations (Deployments, StatefulSets, DaemonSets, Storage, Ingress)
├── k8-project-2/       # Multi-Tier Microservices & Platform Hardening (Minikube 5-Node Cluster)
├── k8-project-3/       # Production Enterprise Platform on OKE (3-Node Dedicated Cloud Cluster)
├── k8-project-4/       # Observability & Batch Processing (Helm, Prometheus-Stack, Grafana, CronJobs)
├── k8-project-5/       # GitOps & Progressive Delivery (ArgoCD, Argo Rollouts, Automated Canary Rollbacks)
├── k8-project-6/       # Cloud-Native CI/CD & DevSecOps (GitLab Runner, Rootless Buildah, Trivy, SBOM)
├── k8-troubleshoot-1/  # SRE Incident Lab 1: ShopSphere E-Commerce (11 Cascading Multi-Object Failures)
├── k8-troubleshoot-2/  # SRE Incident Lab 2: NovaMarket Platform (7 Deep Topology & Stateful Failures)
├── k8-troubleshoot-3/  # SRE Incident Lab 3: ApexPay Gateway (7 Linux Security, VFS & Socket Failures)
├── k8-troubleshoot-4/  # SRE Incident Lab 4: PulseMed Telemetry (7 Service, Port & EndpointSlice Failures)
├── k8-troubleshoot-5/  # SRE Incident Lab 5: ApexPay Core Banking (5 Deep Service, Port & Mesh Routing Failures)
├── k8-troubleshoot-6/  # SRE Incident Lab 6: AeroOps Flight Radar (8 Cascading Service, Probe & Anti-Affinity Failures)
├── k8-troubleshoot-7/  # SRE Incident Lab 7: NexusLogistics Autonomous Dispatch (8 Storage, OOM, RBAC & Gateway Failures)
├── k8-troubleshoot-8/  # SRE Incident Lab 8: Helix Ledger Platform (10 Deep RBAC, NetworkPolicy, StartupProbe & Topology Failures)
├── k8-troubleshoot-9/  # SRE Incident Lab 9: PayStream Settlement Engine (5 Sequential Bottom-Up Failures: Scheduling, CSI, Probes, NetPol & Routing)
└── k8-troubleshoot-10/ # SRE Incident Lab 10: Chronos Platform (5 Helm, LB, OOM, AntiAffinity & L7 Gateway Failures)
```

---

## 🛠️ Technology Stack & Tooling

| Domain | Tools & Technologies |
| :--- | :--- |
| **Compute & Orchestration** | Kubernetes (v1.30 – v1.37), OCI OKE, Minikube, CRI-O |
| **Package & Config Management** | Helm 3, Kustomize, ConfigMaps, Secrets |
| **Storage & Persistence** | OCI Block Volume (`oci-bv` CSI), Dynamic PVCs, `subPath`, `fsGroup` |
| **Networking & Discovery** | OCI VCN-Native CNI, ClusterIP, NodePort, Headless Services, Ingress, CoreDNS |
| **GitOps & Delivery** | ArgoCD, Argo Rollouts (Canary Releases, AnalysisTemplates, Rollbacks) |
| **CI/CD & DevSecOps** | GitLab CI (Kubernetes Executor), Rootless Buildah, Trivy Security Scanner, CycloneDX SBOM |
| **Observability & SRE** | Prometheus, Grafana, Alertmanager, Prometheus Operator, PromQL, Kube-State-Metrics |
| **Application Runtimes** | Python (HTTP / REST APIs), Nginx (L7 Reverse Proxy), PostgreSQL 16, Redis 7.2 |

---

## 🌐 Production Cluster Topologies

### Topology A: OCI Container Engine for Kubernetes (OKE)
* **Control Plane:** Fully Managed Oracle Kubernetes Engine (Kubernetes v1.37.0)
* **Worker Nodes (3 Nodes, `VM.Standard.E3.Flex`, Oracle Linux 8.10 UEK):**
  * `10.0.10.122`: Web / Application Tier (`tier=web`, Untainted)
  * `10.0.10.208`: Web / Application Tier (`tier=web`, Untainted)
  * `10.0.10.78`: Dedicated Database Tier (`tier=database`, Taint: `workload=database:NoSchedule`)
* **Default StorageClass:** `oci-bv` (`blockvolume.csi.oraclecloud.com`, ext4, WaitForFirstConsumer)

### Topology B: Local Minikube Platform
* **Architecture:** 5 Nodes (1 Control-Plane + 4 Workers)
* **Features:** Ingress Controller (`nginx`), Metrics Server, Calico CNI, Local Storage Provisioner

---

## 📚 Project Summary & Deep-Dive Links

### 1. Hands-On Platform Projects (Build & Deploy)
* [**k8-project-1:** Core Kubernetes Primitives](./k8-project-1/README.md) — Comprehensive hands-on coverage of Deployments, StatefulSets (MongoDB), DaemonSets, PersistentVolumes, PersistentVolumeClaims, Services, and Ingress routing.
* [**k8-project-2:** Platform Hardening on Minikube](./k8-project-2/README.md) — 5-node multi-tenant architecture with `staging`/`production` namespaces, dedicated worker taints, NetworkPolicies, InitContainers, HPA, PDB, and RBAC client pods.
* [**k8-project-3:** Production Enterprise Platform on OCI OKE](./k8-project-3/README.md) — Enterprise multi-tier deployment on cloud infrastructure with OCI Block Volume CSI, TopologySpreadConstraints, OCI Flexible Load Balancers, Redis StatefulSet, and node drain operations.
* [**k8-project-4:** SRE Observability & Batch Processing](./k8-project-4/README.md) — Custom microservice Helm chart, production-tuned `kube-prometheus-stack`, Grafana dashboards, batch Jobs/CronJobs, ServiceMonitors, Alertmanager rules, and synthetic crash testing.
* [**k8-project-5:** GitOps & Progressive Delivery](./k8-project-5/README.md) — Declarative ArgoCD GitOps pipelines, self-healing drift remediation, Argo Rollouts automated canary deployments, and Prometheus metric-based automated rollbacks.
* [**k8-project-6:** Cloud-Native CI/CD & DevSecOps Platform](./k8-project-6/README.md) — Dynamic Kubernetes-executor GitLab Runner, rootless container image builds (Buildah), automated vulnerability scanning (Trivy), CycloneDX SBOM generation, and automated GitOps promotion.

### 2. On-Call SRE Incident Triage Labs (Troubleshooting)
* [**k8-troubleshoot-1:** ShopSphere E-Commerce Incident Triage](./k8-troubleshoot-1/README.md) — 11 cascading tickets covering StorageClass mismatches, Secret key typos, Headless DNS failures, Service selector drift, Liveness Probe cyclic crashes, HPA metric starvation, DaemonSet taints, and RBAC core API group errors.
* [**k8-troubleshoot-2:** NovaMarket Platform Outage Triage](./k8-troubleshoot-2/README.md) — 7 cascading production tickets: `NoExecute` vs `NoSchedule` toleration, ext4 `lost+found` initdb rejection, startupProbe budget starvation, `optional: true` silent failures, Service selector drift, and required anti-affinity deadlocks.
* [**k8-troubleshoot-3:** ApexPay Financial Gateway Outage Triage](./k8-troubleshoot-3/README.md) — 7 system-level tickets: NodeAffinity label mismatch, non-root storage permissions (`fsGroup: 999`), excessive CPU requests (`Insufficient cpu`), VFS volume mount code overlay, probe timeout storms, named port resolution, and `127.0.0.1` localhost socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetry & Clinic Gateway Triage](./k8-troubleshoot-4/README.md) — 7 network and service tickets: Taint key mismatch, Headless Service DNS NXDOMAIN, Service `targetPort` (6380 vs 6379), Probe port mismatch (8000 vs 8080), ConfigMap upstream port mismatch (5433 vs 5432), and Nginx `proxy_pass` port conflict (8080 vs 80).
* [**k8-troubleshoot-5:** ApexPay Banking & Service Mesh Triage](./k8-troubleshoot-5/README.md) — 5 deep Kubernetes Service architectural tickets: Headless Service DNS naming contract, multi-label selector over-specification, port vs targetPort indirection, transport protocol mismatch (TCP vs UDP), and `externalTrafficPolicy: Local` packet blackholing.
* [**k8-troubleshoot-6:** AeroOps Flight Radar & Mesh Dispatch Triage](./k8-troubleshoot-6/README.md) — 8 cascading production tickets: Taint toleration typo, Headless DNS NXDOMAIN, Redis targetPort mismatch, probe port failure CrashLoopBackOff, ConfigMap upstream port mismatch, Service selector label drift, Nginx 502 Bad Gateway upstream port conflict, and hard anti-affinity 2-node deadlock.
* [**k8-troubleshoot-7:** NexusLogistics Autonomous Dispatch Grid Triage](./k8-troubleshoot-7/README.md) — 8 cascading production tickets: CSI StorageClass & AccessMode rejection (PVC Pending), Secret key typo (CreateContainerConfigError), InitContainer hostname typo, Memory limit starvation (OOMKilled 137), in-cluster RBAC 403 Forbidden, LoadBalancer selector drift, NGINX upstream 502 Bad Gateway, and 2-node hard anti-affinity deadlock.
* [**k8-troubleshoot-8:** Helix Ledger Platform Outage Triage](./k8-troubleshoot-8/README.md) — 10 advanced production tickets: Taint NoExecute vs NoSchedule, ext4 lost+found initdb rejection, secretKeyRef optional silent failure, startupProbe budget starvation, NetworkPolicy AND vs OR selector trap, ServiceAccount token automount, RBAC subject namespace scoping, RBAC core apiGroups mismatches, NodeAffinity label mismatch, and Service selector tier drift.
* [**k8-troubleshoot-9:** PayStream Settlement Engine Triage](./k8-troubleshoot-9/README.md) — 5 strictly linear, bottom-up production tickets: Taint toleration & ext4 lost+found (Postgres), Block Volume ReadWriteMany vs RWO & Service selector drift (Redis), InitContainer port mismatch & Liveness probe conflict, ConfigMap port mismatch (Readiness failure & traffic blackhole), and NetworkPolicy ingress selector & Nginx trailing slash path stripping.
* [**k8-troubleshoot-10:** Chronos Distributed Order & Inventory Platform Triage](./k8-troubleshoot-10/README.md) — 5 strictly linear, bottom-up production tickets using Helm & LoadBalancer: Python memory cgroup limit starvation (OOMKilled 137), 2-node hard podAntiAffinity scheduling deadlock, ConfigMap vs extraEnv precedence & 503 readiness failure, Service targetPort mismatch & externalTrafficPolicy: Local packet blackholing, and missing L7 security gateway header with silent ConfigMap reload failure.

---

<br>

---

## 🇹🇷 Türkçe Versiyon / Turkish Version

# 🚀 Bulut-Yerel Kubernetes ve DevOps Mühendisliği Çalışma Alanı

Bu depo; temel konteyner orkestrasyonundan kurumsal DevSecOps, GitOps, gözlemlenebilirlik (observability) ve gerçek zamanlı SRE olay müdahale (incident triage) simülasyonlarına kadar uzanan kapsamlı bir **Kubernetes ve Platform Mühendisliği** çalışma alanıdır.

Tüm projeler ve sorun giderme laboratuvarları hem yerel kümelerde (**Minikube**) hem de gerçek bulut ortamında (**Oracle Cloud Infrastructure Container Engine for Kubernetes - OKE**) birebir çalıştırılabilir ve doğrulanabilir şekilde tasarlanmıştır.

---

### 📂 Proje ve Laboratuvar Haritası

* [**k8-project-1:** Temel Kubernetes Nesneleri](./k8-project-1/README.md) — Deployment, StatefulSet (MongoDB), DaemonSet, PV/PVC, StorageClass, Service ve Ingress temelleri.
* [**k8-project-2:** Çok Katmanlı Platform Güçlendirme (Minikube)](./k8-project-2/README.md) — 5 node'lu kümede staging/production ayrımı, dedicated taint/toleration, NetworkPolicy, InitContainer, HPA, PDB ve RBAC.
* [**k8-project-3:** OCI OKE Üretim Ortamı Mimarisi](./k8-project-3/README.md) — OCI Block Volume (oci-bv CSI), TopologySpread, OCI Flexible Load Balancer, Redis StatefulSet ve kontrollü node drain operasyonları.
* [**k8-project-4:** SRE Gözlemlenebilirlik ve Batch Süreçler](./k8-project-4/README.md) — Custom Helm chart, optimize `kube-prometheus-stack`, Grafana panelleri, CronJob yedekleme, ServiceMonitor ve Alertmanager alarm kuralları.
* [**k8-project-5:** GitOps ve İlerici Dağıtım (ArgoCD & Argo Rollouts)](./k8-project-5/README.md) — Deklaratif ArgoCD yönetimi, self-healing sürüklenme engelleme, Canary dağıtımları ve Prometheus metrik tabanlı otomatik rollback.
* [**k8-project-6:** Bulut-Yerel CI/CD ve DevSecOps Hattı](./k8-project-6/README.md) — Dinamik GitLab Runner, rootless Buildah ile imaj derleme, Trivy güvenlik kapısı (vulnerability gating), SBOM üretimi ve GitOps köprüsü.
* [**k8-troubleshoot-1:** ShopSphere E-Ticaret Arıza Kurtarma Labı](./k8-troubleshoot-1/README.md) — 11 zincirleme bilet: StorageClass, Headless DNS, Service selector, Liveness probe, HPA, DaemonSet taint ve RBAC core apiGroups.
* [**k8-troubleshoot-2:** NovaMarket Canlı Kesinti Müdahale Labı](./k8-troubleshoot-2/README.md) — 7 üretim arızası: Toleration NoExecute vs NoSchedule, ext4 lost+found initdb engeli, startupProbe bütçesi, `optional: true` sessiz hatası ve katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-3:** ApexPay Finansal Gateway Arıza Kurtarma Labı](./k8-troubleshoot-3/README.md) — 7 sistem seviyesi arıza: NodeAffinity, non-root `fsGroup: 999`, gerçek dışı CPU isteği, VFS mount kod ezmesi, probe timeout ve `127.0.0.1` socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetri Servis & Port Arıza Labı](./k8-troubleshoot-4/README.md) — 7 ağ ve port arızası: Taint key uyuşmazlığı, Headless DNS NXDOMAIN, `port` vs `targetPort`, Probe port uyuşmazlığı, ConfigMap port hatası ve Nginx `proxy_pass` port çatışması.
* [**k8-troubleshoot-5:** ApexPay Çekirdek Bankacılık & Servis Ağı Arıza Labı](./k8-troubleshoot-5/README.md) — 5 derin Kubernetes Servis mimarisi arızası: Headless Service DNS sözleşmesi, selector etiket fazlalığı (empty endpoints), port / targetPort yönlendirme hatası, TCP vs UDP protokol çelişkisi ve externalTrafficPolicy Local paket kara delik (blackhole) arızası.
* [**k8-troubleshoot-6:** AeroOps Uçuş Radar & Servis Ağı Arıza Labı](./k8-troubleshoot-6/README.md) — 8 zincirleme üretim arızası: Taint toleration yazım hatası, Headless DNS NXDOMAIN, Redis targetPort hatası, probe port çelişkisi CrashLoopBackOff, ConfigMap upstream port hatası, Service selector etiket sürüklenmesi, Nginx 502 Bad Gateway port çatışması ve katı anti-affinity 2-node kilitlenmesi.
* [**k8-troubleshoot-7:** NexusLogistics Otonom Sevkiyat Ağı Arıza Labı](./k8-troubleshoot-7/README.md) — 8 zincirleme üretim arızası: CSI StorageClass & AccessMode reddi (PVC Pending), Secret key yazım hatası (CreateContainerConfigError), InitContainer hostname hatası, cgroup bellek sınırı (OOMKilled 137), küme içi RBAC 403 Forbidden, LoadBalancer seçici etiket sapması, NGINX upstream 502 Bad Gateway ve 2-node katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-8:** Helix Ledger Canlı Kesinti & İleri Düzey RBAC/Ağ Müdahale Labı](./k8-troubleshoot-8/README.md) — 10 ileri düzey üretim arızası: Taint NoExecute vs NoSchedule uyuşmazlığı, ext4 lost+found initdb engeli, secretKeyRef optional sessiz hatası, startupProbe bütçesi tükenmesi, NetworkPolicy AND/OR seçici tuzağı, ServiceAccount token automount eksikliği, RoleBinding namespace kapsam hatası, RBAC core apiGroups uyuşmazlığı, NodeAffinity etiket hatası ve Service selector sürüklenmesi.
* [**k8-troubleshoot-9:** PayStream Ödeme ve Mutabakat Sistemi Arıza Labı](./k8-troubleshoot-9/README.md) — 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Taint toleration ve ext4 lost+found engeli (Postgres), Blok depolamada ReadWriteMany vs RWO çelişkisi ve Service selector sapması (Redis), InitContainer port hatası ve Liveness probe çelişkisi, ConfigMap port uyuşmazlığı (Readiness hatası ve trafik kara deliği) ve NetworkPolicy Ingress seçici hatası ile Nginx trailing slash URI kırpma arızası.
* [**k8-troubleshoot-10:** Chronos Dağıtık Sipariş ve Stok Koordinasyon Platformu Arıza Labı](./k8-troubleshoot-10/README.md) — Helm ve LoadBalancer mimarisi ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Python bellek sınırı yetersizliği (OOMKilled 137), 2-node katı podAntiAffinity zamanlama kilitlenmesi, ConfigMap vs extraEnv öncelik çatışması & 503 readiness hatası, Servis targetPort uyuşmazlığı & externalTrafficPolicy Local paket kara delik arızası ve L7 ağ geçidi güvenlik başlığı eksikliği ile ConfigMap sessiz yeniden yükleme (reload) engeli.
