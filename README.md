# 🚀 Cloud-Native Kubernetes & DevOps Engineering Workspace

Welcome to the comprehensive **Kubernetes, Cloud Infrastructure, and Site Reliability Engineering (SRE)** repository. This repository represents an end-to-end journey from foundational container orchestration to enterprise-grade DevSecOps, GitOps, observability, and real-world production incident response simulations.

All projects and troubleshooting scenarios are fully reproducible on local clusters (**Minikube**) and production cloud environments (**Oracle Cloud Infrastructure Container Engine for Kubernetes - OKE**).

---

## 🧭 Repository Structure & Curriculum Index

```text
k8sfundamentals/
├── Projects/
│   ├── k8-training/          # Scratch / training manifests
│   ├── k8-project-1/         # Kubernetes Foundations (Deployments, StatefulSets, DaemonSets, Storage, Ingress)
│   ├── k8-project-2/         # Multi-Tier Microservices & Platform Hardening (Minikube 5-Node Cluster)
│   ├── k8-project-3/         # Production Enterprise Platform on OKE (3-Node Dedicated Cloud Cluster)
│   ├── k8-project-4/         # Observability & Batch Processing (Helm, Prometheus-Stack, Grafana, CronJobs)
│   ├── k8-project-5/         # GitOps & Progressive Delivery (ArgoCD, Argo Rollouts, Automated Canary Rollbacks)
│   ├── k8-project-6/         # Cloud-Native CI/CD & DevSecOps (GitLab Runner, Rootless Buildah, Trivy, SBOM)
│   ├── rk2-azure-project-1/  # 5-Node RKE2 High-Isolation Architecture on Azure (Master + Infra + PG + Mongo + App)
│   ├── rk2-azure-project-2/  # Automated 5-Node RKE2 + Rancher Dashboard (Terraform + Ansible + Multi-DB)
│   ├── terraform-ansible-1/  # IaC Intro: Azure single VM (Terraform) + K3s bootstrap (Ansible), auto-generated inventory
│   └── terraform-ansible-2/  # IaC Multi-Node: Azure 1 Master + 1 Worker (Terraform) + K3s cluster join (Ansible) + Helm
│
└── Troubleshoot/
    ├── k8-troubleshoot-1/    # ShopSphere E-Commerce (11 Cascading Multi-Object Failures)
    ├── k8-troubleshoot-2/    # NovaMarket Platform (7 Deep Topology & Stateful Failures)
    ├── k8-troubleshoot-3/    # ApexPay Gateway (7 Linux Security, VFS & Socket Failures)
    ├── k8-troubleshoot-4/    # PulseMed Telemetry (7 Service, Port & EndpointSlice Failures)
    ├── k8-troubleshoot-5/    # ApexPay Core Banking (5 Deep Service, Port & Mesh Routing Failures)
    ├── k8-troubleshoot-6/    # AeroOps Flight Radar (8 Cascading Service, Probe & Anti-Affinity Failures)
    ├── k8-troubleshoot-7/    # NexusLogistics (8 Storage, OOM, RBAC & Gateway Failures)
    ├── k8-troubleshoot-8/    # Helix Ledger (10 Deep RBAC, NetworkPolicy, StartupProbe & Topology Failures)
    ├── k8-troubleshoot-9/    # PayStream (5 Sequential Bottom-Up Failures: Scheduling, CSI, Probes, NetPol & Routing)
    ├── k8-troubleshoot-10/   # Chronos (5 Helm, LB, OOM, AntiAffinity & L7 Gateway Failures)
    ├── k8-troubleshoot-11/   # PulseStream (5 Job, Helm Scope, Probe Timeout, HPA & DaemonSet Failures)
    ├── k8-troubleshoot-12/   # Vortex (5 Traefik Ingress Helm, StripPrefix, Secret Ref, TopologySpread & CronJob OOM)
    ├── k8-troubleshoot-13/   # NovaEdge (5 Edge Ingress LB Port, IngressClass 404, Stream API, DaemonSet & Probe Failures)
    ├── k8-troubleshoot-14/   # AegisGrid (5 Secret/Job Immutability, Helm Init, Readiness, Toleration & L7 Gateway)
    ├── k8-troubleshoot-15/   # QuantFlow (5 Job/CronJob, Helm OOM/Liveness, Env Precedence & HPA, DaemonSet & L7)
    ├── k8-troubleshoot-16/   # OmniCore Grand Finale Capstone (7-Layer 18-Fault Master Review)
    ├── k8-troubleshoot-17/   # AetherMesh Production Capstone on AKS (7-Layer 18-Fault Review)
    ├── k8-troubleshoot-18/   # NovaStore v2.4 Storefront Live Crisis (6-Fault Cascading Production Outage on AKS)
    ├── k8-troubleshoot-19/   # OmniPulse v3.0 Full-Stack Capstone on AKS (12-Fault Master Kubernetes Object & Interview Review)
    ├── tf-troubleshoot-1/    # Terraform Lab 1 (Azure): State Drift, Import (already exists), prevent_destroy
    ├── tf-troubleshoot-2/    # Terraform Lab 2 (local): State Lock, Lost State recovery, Refactor (moved / state mv)
    ├── tf-troubleshoot-3/    # Terraform Lab 3 (local): Broken code (5 errors incl. Cycle), -replace / secret rotation
    ├── tf-troubleshoot-4/    # IaC Incident Lab 4: ChronoPay — Terraform Schema/Secret Mode, Inventory Handoff, Ansible Group/Become & Idempotency
    ├── tf-troubleshoot-5/    # IaC Incident Lab 5: NexusVault — State Wipe Recovery, Protected Rename (moved), -replace & Ansible Precedence
    └── tf-troubleshoot-6/    # IaC Incident Lab 6: AegisCloud — Multi-Tier Cluster (Dependency Cycle, Cross-Host hostvars, lineinfile & L7 LB)
```

---

## 🛠️ Technology Stack & Tooling

| Domain | Tools & Technologies |
| :--- | :--- |
| **Compute & Orchestration** | Kubernetes (v1.30 – v1.37), OCI OKE, Minikube, K3s, CRI-O, containerd |
| **Infrastructure as Code** | Terraform (azurerm, local, random), Ansible (playbooks, inventory, idempotency), Azure CLI, Azure for Students |
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

### Topology C: Azure Self-Managed K3s (Terraform + Ansible)
* **Region:** `denmarkeast` (Azure for Students allowed regions only), VM size `Standard_B2s`
* **Provisioning:** Terraform (RG, VNet `10.0.0.0/16`, Subnet `10.0.1.0/24`, NSG, Public IP, NIC, Ubuntu 24.04 VM)
* **Configuration:** Ansible (containerd, swap off, K3s) — inventory generated by Terraform `local_file`

---

## 📚 Project Summary & Deep-Dive Links

### 1. Hands-On Platform Projects (Build & Deploy)
* [**k8-project-1:** Core Kubernetes Primitives](./Projects/k8-project-1/README.md) — Comprehensive hands-on coverage of Deployments, StatefulSets (MongoDB), DaemonSets, PersistentVolumes, PersistentVolumeClaims, Services, and Ingress routing.
* [**k8-project-2:** Platform Hardening on Minikube](./Projects/k8-project-2/README.md) — 5-node multi-tenant architecture with `staging`/`production` namespaces, dedicated worker taints, NetworkPolicies, InitContainers, HPA, PDB, and RBAC client pods.
* [**k8-project-3:** Production Enterprise Platform on OCI OKE](./Projects/k8-project-3/README.md) — Enterprise multi-tier deployment on cloud infrastructure with OCI Block Volume CSI, TopologySpreadConstraints, OCI Flexible Load Balancers, Redis StatefulSet, and node drain operations.
* [**k8-project-4:** SRE Observability & Batch Processing](./Projects/k8-project-4/README.md) — Custom microservice Helm chart, production-tuned `kube-prometheus-stack`, Grafana dashboards, batch Jobs/CronJobs, ServiceMonitors, Alertmanager rules, and synthetic crash testing.
* [**k8-project-5:** GitOps & Progressive Delivery](./Projects/k8-project-5/README.md) — Declarative ArgoCD GitOps pipelines, self-healing drift remediation, Argo Rollouts automated canary deployments, and Prometheus metric-based automated rollbacks.
* [**k8-project-6:** Cloud-Native CI/CD & DevSecOps Platform](./Projects/k8-project-6/README.md) — Dynamic Kubernetes-executor GitLab Runner, rootless container image builds (Buildah), automated vulnerability scanning (Trivy), CycloneDX SBOM generation, and automated GitOps promotion.

* [**terraform-ansible-1:** IaC Intro on Azure](./Projects/terraform-ansible-1/) — Single Azure VM provisioned with Terraform (VNet, NSG, Public IP, NIC), Ansible playbook bootstrapping containerd + K3s, idempotency demo, and Terraform-generated Ansible inventory.
* [**terraform-ansible-2:** Multi-Node K3s on Azure](./Projects/terraform-ansible-2/) — 1 Master + 1 Worker topology with Terraform, Ansible-driven cluster join, Helm-based LoadBalancer/Ingress and a static web app (work in progress).

### 2. On-Call SRE Incident Triage Labs (Troubleshooting)
* [**k8-troubleshoot-1:** ShopSphere E-Commerce Incident Triage](./Troubleshoot/k8-troubleshoot-1/README.md) — 11 cascading tickets covering StorageClass mismatches, Secret key typos, Headless DNS failures, Service selector drift, Liveness Probe cyclic crashes, HPA metric starvation, DaemonSet taints, and RBAC core API group errors.
* [**k8-troubleshoot-2:** NovaMarket Platform Outage Triage](./Troubleshoot/k8-troubleshoot-2/README.md) — 7 cascading production tickets: `NoExecute` vs `NoSchedule` toleration, ext4 `lost+found` initdb rejection, startupProbe budget starvation, `optional: true` silent failures, Service selector drift, and required anti-affinity deadlocks.
* [**k8-troubleshoot-3:** ApexPay Financial Gateway Outage Triage](./Troubleshoot/k8-troubleshoot-3/README.md) — 7 system-level tickets: NodeAffinity label mismatch, non-root storage permissions (`fsGroup: 999`), excessive CPU requests (`Insufficient cpu`), VFS volume mount code overlay, probe timeout storms, named port resolution, and `127.0.0.1` localhost socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetry & Clinic Gateway Triage](./Troubleshoot/k8-troubleshoot-4/README.md) — 7 network and service tickets: Taint key mismatch, Headless Service DNS NXDOMAIN, Service `targetPort` (6380 vs 6379), Probe port mismatch (8000 vs 8080), ConfigMap upstream port mismatch (5433 vs 5432), and Nginx `proxy_pass` port conflict (8080 vs 80).
* [**k8-troubleshoot-5:** ApexPay Banking & Service Mesh Triage](./Troubleshoot/k8-troubleshoot-5/README.md) — 5 deep Kubernetes Service architectural tickets: Headless Service DNS naming contract, multi-label selector over-specification, port vs targetPort indirection, transport protocol mismatch (TCP vs UDP), and `externalTrafficPolicy: Local` packet blackholing.
* [**k8-troubleshoot-6:** AeroOps Flight Radar & Mesh Dispatch Triage](./Troubleshoot/k8-troubleshoot-6/README.md) — 8 cascading production tickets: Taint toleration typo, Headless DNS NXDOMAIN, Redis targetPort mismatch, probe port failure CrashLoopBackOff, ConfigMap upstream port mismatch, Service selector label drift, Nginx 502 Bad Gateway upstream port conflict, and hard anti-affinity 2-node deadlock.
* [**k8-troubleshoot-7:** NexusLogistics Autonomous Dispatch Grid Triage](./Troubleshoot/k8-troubleshoot-7/README.md) — 8 cascading production tickets: CSI StorageClass & AccessMode rejection (PVC Pending), Secret key typo (CreateContainerConfigError), InitContainer hostname typo, Memory limit starvation (OOMKilled 137), in-cluster RBAC 403 Forbidden, LoadBalancer selector drift, NGINX upstream 502 Bad Gateway, and 2-node hard anti-affinity deadlock.
* [**k8-troubleshoot-8:** Helix Ledger Platform Outage Triage](./Troubleshoot/k8-troubleshoot-8/README.md) — 10 advanced production tickets: Taint NoExecute vs NoSchedule, ext4 lost+found initdb rejection, secretKeyRef optional silent failure, startupProbe budget starvation, NetworkPolicy AND vs OR selector trap, ServiceAccount token automount, RBAC subject namespace scoping, RBAC core apiGroups mismatches, NodeAffinity label mismatch, and Service selector tier drift.
* [**k8-troubleshoot-9:** PayStream Settlement Engine Triage](./Troubleshoot/k8-troubleshoot-9/README.md) — 5 strictly linear, bottom-up production tickets: Taint toleration & ext4 lost+found (Postgres), Block Volume ReadWriteMany vs RWO & Service selector drift (Redis), InitContainer port mismatch & Liveness probe conflict, ConfigMap port mismatch (Readiness failure & traffic blackhole), and NetworkPolicy ingress selector & Nginx trailing slash path stripping.
* [**k8-troubleshoot-10:** Chronos Distributed Order & Inventory Platform Triage](./Troubleshoot/k8-troubleshoot-10/README.md) — 5 strictly linear, bottom-up production tickets using Helm & LoadBalancer: Python memory cgroup limit starvation (OOMKilled 137), 2-node hard podAntiAffinity scheduling deadlock, ConfigMap vs extraEnv precedence & 503 readiness failure, Service targetPort mismatch & externalTrafficPolicy: Local packet blackholing, and missing L7 security gateway header with silent ConfigMap reload failure.
* [**k8-troubleshoot-11:** PulseStream Real-Time Analytics & Reporting Platform Triage](./Troubleshoot/k8-troubleshoot-11/README.md) — 5 strictly linear, bottom-up production tickets: Job activeDeadlineSeconds & target host mismatch (Database Migration Immutability), Helm values hierarchy scope mismatch (Worker Redis connection refused), Python probe timeout timeoutSeconds: 1 (ReplicaSet rollout deadlock), HPA target name typo & missing requests.cpu (Unknown metrics starvation), and DaemonSet missing database taint toleration with Named Port Service 502 Bad Gateway.
* [**k8-troubleshoot-12:** Vortex Microservices Platform & Traefik Ingress Triage](./Troubleshoot/k8-troubleshoot-12/README.md) — 5 cascading production tickets: Traefik Ingress Helm Controller non-root port 80 CrashLoopBackOff, Ingress pathType Exact & StripPrefix routing 404, Auth-Service Secret key typo & Redis DNS discovery, Payment-Service multi-zone TopologySpreadConstraint scheduling deadlock, and Notification-Dispatcher CronJob cgroup memory OOMKilled 137.
* [**k8-troubleshoot-13:** NovaEdge Real-Time Edge IoT & Ingress Gateway Triage](./Troubleshoot/k8-troubleshoot-13/README.md) — 5 cascading production tickets: Edge Ingress Helm LoadBalancer targetPort mismatch, Ingress resource IngressClassName & backend port 80 resolution, Stream API container startup command path & buffer size validation crash, Edge Node DaemonSet Node-3 database taint & read-only volume permissions, and Stream Sync Worker async HTTP probe protocol & Redis channel mismatch.
* [**k8-troubleshoot-14:** AegisGrid Distributed Threat Intelligence & Security Telemetry Triage](./Troubleshoot/k8-troubleshoot-14/README.md) — 5 strictly linear, bottom-up production tickets: Threat Feed Job `secretKeyRef` mismatch & CronJob suspend/Redis DNS drift, Helm `scanner-worker` InitContainer port & `startupProbe` budget starvation, `intel-api` readinessProbe port & ConfigMap upstream discovery failure, `Service/intel-api` selector/targetPort blackhole & `node-shield` DaemonSet `NoExecute` vs `NoSchedule` toleration, and Helm `aegis-gateway` Nginx 504/502/403 security token rejection with ConfigMap `subPath` reload.
* [**k8-troubleshoot-15:** QuantFlow Algorithmic Risk, Liquidity Engine & L7 Edge Gateway Triage](./Troubleshoot/k8-troubleshoot-15/README.md) — 5 strictly linear, bottom-up production tickets: Ledger Bootstrap Job `secretKeyRef`/DB host mismatch & CronJob suspend/Redis port drift, Helm `liquidity-worker` InitContainer Redis host, cgroup `OOMKilled` (`137`) & `livenessProbe` path 404, `risk-engine` `env` vs `envFrom` override precedence & HPA target/CPU request starvation, `Service/risk-engine` selector/targetPort blackhole & `latency-probe` DaemonSet taint key/read-only VFS crash, and Helm `quant-gateway` LoadBalancer targetPort, `403` signature rejection with `subPath` reload & Ingress binding.
* [**k8-troubleshoot-16:** OmniCore Enterprise Order, Settlement, Telemetry & L7 Edge Platform (Grand Finale Capstone)](./Troubleshoot/k8-troubleshoot-16/README.md) — 7-layer, 18-fault master review covering StatefulSet taint effect (`NoExecute` vs `NoSchedule`), CSI `WaitForFirstConsumer` & ext4 `lost+found` (`subPath: pgdata`), Redis Service `targetPort`, Batch `Job` immutability & `CronJob` suspension, Helm `InitContainer` port, cgroup `OOMKilled` (`137`) & `startupProbe` budget, 2-node hard `podAntiAffinity` deadlock & `env` vs `envFrom` precedence, HPA `requests.cpu` metric starvation & Service selector drift, DaemonSet taint key & read-only VFS crash, and L7 Gateway `subPath` reload & Ingress binding.
* [**k8-troubleshoot-17:** AetherMesh Distributed Global Payment, Real-Time Event Processing & Edge Telemetry Platform (Master Review)](./Troubleshoot/k8-troubleshoot-17/README.md) — 7-layer, 18-fault comprehensive master review covering StatefulSet taint value matching (`workload=database:NoSchedule`), ext4 `lost+found` (`subPath: pgdata`), Redis Service `targetPort`, Batch `Job` secret key typo (`CreateContainerConfigError`) & immutability, `CronJob` suspension, Helm `stream-worker` InitContainer TCP portu, cgroup `OOMKilled` (`137`) & `startupProbe` warmup budget, 2-node hard `podAntiAffinity` scheduling deadlock & `env` vs `envFrom` precedence, HPA `requests.cpu` metric starvation & Service selector drift, DaemonSet taint key & read-only VFS crash, and L7 Gateway `subPath` reload & Ingress binding.
* [**k8-troubleshoot-18:** NovaStore v2.4 Storefront Live Crisis (AKS + Helm)](./Troubleshoot/k8-troubleshoot-18/README.md) — 6-fault cascading production outage on AKS covering CSI StorageClass (`managed-csi`), Secret key matching, NetworkPolicy podSelector/port filtering, ImagePullBackOff tag fix, Nginx readiness/liveness probe paths, and Service selector/targetPort routing.
* [**k8-troubleshoot-19:** OmniPulse v3.0 Full-Stack Capstone on AKS (Master Object & Interview Review)](./Troubleshoot/k8-troubleshoot-19/README.md) — 12-fault comprehensive Kubernetes object review on AKS (`StatefulSet`, Headless DNS, `PVC` `ReadWriteOnce` vs `ReadWriteMany` across multiple pods/nodes, `Job` immutability, `CronJob`, `DaemonSet`, `InitContainer`, `podAntiAffinity`, `OOMKilled`, `HPA`, `PDB`, `NetworkPolicy`, `Service`, and `Ingress`).

### 3. Terraform Troubleshooting Labs (IaC Incident Response)
* [**tf-troubleshoot-1:** Drift, Import & Destroy Protection (Azure, free resources)](./Troubleshoot/tf-troubleshoot-1/README.md) — Manual portal changes (NSG rule & tag drift), `-refresh-only`, unmanaged subnet `already exists` → `import {}` block, and `lifecycle.prevent_destroy`.
* [**tf-troubleshoot-2:** State Disasters (local)](./Troubleshoot/tf-troubleshoot-2/README.md) — State lock contention & `force-unlock`, deleted `terraform.tfstate` recovery from backup, resource rename refactor with `moved {}` / `terraform state mv`.
* [**tf-troubleshoot-3:** Broken Code, Cycles & Replace (local)](./Troubleshoot/tf-troubleshoot-3/README.md) — 5 validate/plan errors (type mismatch, undeclared variable, unsupported attribute, duplicate resource, dependency cycle) and targeted secret rotation with `-replace`.
* [**tf-troubleshoot-4:** ChronoPay Pipeline Outage (Terraform + Ansible)](./Troubleshoot/tf-troubleshoot-4/README.md) — 5 sequential tickets: Terraform variable types, duplicate resource & undeclared outputs, inventory handoff & `0600` secret permissions, Ansible host group matching, raw command idempotency vs `file:` module, Jinja2 undefined variable, and handler notification name mismatch (`502 Bad Gateway`).
* [**tf-troubleshoot-5:** NexusVault Stateful Outage (State Disasters & Precedence)](./Troubleshoot/tf-troubleshoot-5/README.md) — 5 sequential tickets: Missing `terraform.tfstate` recovery from `.backup`, protected resource refactoring (`prevent_destroy` + `moved {}`), targeted secret rotation with `-replace`, Ansible role variable precedence trap (`vars/` vs `group_vars/` vs `defaults/`), and conditional `when:` string-vs-int evaluation (`503 Vault Sealed`).
* [**tf-troubleshoot-6:** AegisCloud Multi-Tier Cluster Outage (Advanced Capstone)](./Troubleshoot/tf-troubleshoot-6/README.md) — 5 sequential tickets: Cross-resource dependency cycle (`Error: Cycle`), dynamic inventory group mismatch, cross-host `slurp:` Base64 join token decoding (`| b64decode | trim`), `lineinfile` missing `regexp:` duplicate config bug, and Jinja2 LoadBalancer upstream loop routing to workers.

---

<br>

---

## 🇹🇷 Türkçe Versiyon / Turkish Version

# 🚀 Bulut-Yerel Kubernetes ve DevOps Mühendisliği Çalışma Alanı

Bu depo; temel konteyner orkestrasyonundan kurumsal DevSecOps, GitOps, gözlemlenebilirlik (observability) ve gerçek zamanlı SRE olay müdahale (incident triage) simülasyonlarına kadar uzanan kapsamlı bir **Kubernetes ve Platform Mühendisliği** çalışma alanıdır.

Tüm projeler ve sorun giderme laboratuvarları hem yerel kümelerde (**Minikube**) hem de gerçek bulut ortamında (**Oracle Cloud Infrastructure Container Engine for Kubernetes - OKE**) birebir çalıştırılabilir ve doğrulanabilir şekilde tasarlanmıştır.

---

### 📂 Proje ve Laboratuvar Haritası

* [**k8-project-1:** Temel Kubernetes Nesneleri](./Projects/k8-project-1/README.md) — Deployment, StatefulSet (MongoDB), DaemonSet, PV/PVC, StorageClass, Service ve Ingress temelleri.
* [**k8-project-2:** Çok Katmanlı Platform Güçlendirme (Minikube)](./Projects/k8-project-2/README.md) — 5 node'lu kümede staging/production ayrımı, dedicated taint/toleration, NetworkPolicy, InitContainer, HPA, PDB ve RBAC.
* [**k8-project-3:** OCI OKE Üretim Ortamı Mimarisi](./Projects/k8-project-3/README.md) — OCI Block Volume (oci-bv CSI), TopologySpread, OCI Flexible Load Balancer, Redis StatefulSet ve kontrollü node drain operasyonları.
* [**k8-project-4:** SRE Gözlemlenebilirlik ve Batch Süreçler](./Projects/k8-project-4/README.md) — Custom Helm chart, optimize `kube-prometheus-stack`, Grafana panelleri, CronJob yedekleme, ServiceMonitor ve Alertmanager alarm kuralları.
* [**k8-project-5:** GitOps ve İlerici Dağıtım (ArgoCD & Argo Rollouts)](./Projects/k8-project-5/README.md) — Deklaratif ArgoCD yönetimi, self-healing sürüklenme engelleme, Canary dağıtımları ve Prometheus metrik tabanlı otomatik rollback.
* [**k8-project-6:** Bulut-Yerel CI/CD ve DevSecOps Hattı](./Projects/k8-project-6/README.md) — Dinamik GitLab Runner, rootless Buildah ile imaj derleme, Trivy güvenlik kapısı (vulnerability gating), SBOM üretimi ve GitOps köprüsü.
* [**terraform-ansible-1:** Azure Üzerinde IaC Giriş](./Projects/terraform-ansible-1/) — Terraform ile tek Azure VM (VNet, NSG, Public IP, NIC), Ansible ile containerd + K3s kurulumu, idempotency gösterimi ve Terraform tarafından otomatik üretilen Ansible inventory.
* [**terraform-ansible-2:** Azure Üzerinde Multi-Node K3s](./Projects/terraform-ansible-2/) — Terraform ile 1 Master + 1 Worker, Ansible ile cluster join, Helm ile LoadBalancer/Ingress ve basit web uygulaması (devam ediyor).
* [**rk2-azure-project-1:** 5 Node'lu Yüksek İzolasyonlu Manuel RKE2 Kümesi](./Projects/rk2-azure-project-1/step) — Azure üzerinde 1 Master (`Standard_B2s_v2`) + 4 Worker (`Standard_B1ms`: infra, pg, mongo, app), Taint/Toleration kalkanları, Local-Path Storage, CoreDNS servis ağı ve Ingress doğrulaması.
* [**rk2-azure-project-2:** Otomatik 5-Node RKE2 + Rancher Dashboard (Terraform & Ansible)](./Projects/rk2-azure-project-2/README.md) — Azure altyapısının Terraform ile kurulması, Ansible ile RKE2 bootstrap, cert-manager, görsel Rancher Dashboard arayüzü, 3 veritabanı (Redis, PG, Mongo) ve FastAPI mikroservisinin tam otomasyonu.
* [**k8-troubleshoot-1:** ShopSphere E-Ticaret Arıza Kurtarma Labı](./Troubleshoot/k8-troubleshoot-1/README.md) — 11 zincirleme bilet: StorageClass, Headless DNS, Service selector, Liveness probe, HPA, DaemonSet taint ve RBAC core apiGroups.
* [**k8-troubleshoot-2:** NovaMarket Canlı Kesinti Müdahale Labı](./Troubleshoot/k8-troubleshoot-2/README.md) — 7 üretim arızası: Toleration NoExecute vs NoSchedule, ext4 lost+found initdb engeli, startupProbe bütçesi, `optional: true` sessiz hatası ve katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-3:** ApexPay Finansal Gateway Arıza Kurtarma Labı](./Troubleshoot/k8-troubleshoot-3/README.md) — 7 sistem seviyesi arıza: NodeAffinity, non-root `fsGroup: 999`, gerçek dışı CPU isteği, VFS mount kod ezmesi, probe timeout ve `127.0.0.1` socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetri Servis & Port Arıza Labı](./Troubleshoot/k8-troubleshoot-4/README.md) — 7 ağ ve port arızası: Taint key uyuşmazlığı, Headless DNS NXDOMAIN, `port` vs `targetPort`, Probe port uyuşmazlığı, ConfigMap port hatası ve Nginx `proxy_pass` port çatışması.
* [**k8-troubleshoot-5:** ApexPay Çekirdek Bankacılık & Servis Ağı Arıza Labı](./Troubleshoot/k8-troubleshoot-5/README.md) — 5 derin Kubernetes Servis mimarisi arızası: Headless Service DNS sözleşmesi, selector etiket fazlalığı (empty endpoints), port / targetPort yönlendirme hatası, TCP vs UDP protokol çelişkisi ve externalTrafficPolicy Local paket kara delik (blackhole) arızası.
* [**k8-troubleshoot-6:** AeroOps Uçuş Radar & Servis Ağı Arıza Labı](./Troubleshoot/k8-troubleshoot-6/README.md) — 8 zincirleme üretim arızası: Taint toleration yazım hatası, Headless DNS NXDOMAIN, Redis targetPort hatası, probe port çelişkisi CrashLoopBackOff, ConfigMap upstream port hatası, Service selector etiket sürüklenmesi, Nginx 502 Bad Gateway port çatışması ve katı anti-affinity 2-node kilitlenmesi.
* [**k8-troubleshoot-7:** NexusLogistics Otonom Sevkiyat Ağı Arıza Labı](./Troubleshoot/k8-troubleshoot-7/README.md) — 8 zincirleme üretim arızası: CSI StorageClass & AccessMode reddi (PVC Pending), Secret key yazım hatası (CreateContainerConfigError), InitContainer hostname hatası, cgroup bellek sınırı (OOMKilled 137), küme içi RBAC 403 Forbidden, LoadBalancer seçici etiket sapması, NGINX upstream 502 Bad Gateway ve 2-node katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-8:** Helix Ledger Canlı Kesinti & İleri Düzey RBAC/Ağ Müdahale Labı](./Troubleshoot/k8-troubleshoot-8/README.md) — 10 ileri düzey üretim arızası: Taint NoExecute vs NoSchedule uyuşmazlığı, ext4 lost+found initdb engeli, secretKeyRef optional sessiz hatası, startupProbe bütçesi tükenmesi, NetworkPolicy AND/OR seçici tuzağı, ServiceAccount token automount eksikliği, RoleBinding namespace kapsam hatası, RBAC core apiGroups uyuşmazlığı, NodeAffinity etiket hatası ve Service selector sürüklenmesi.
* [**k8-troubleshoot-9:** PayStream Ödeme ve Mutabakat Sistemi Arıza Labı](./Troubleshoot/k8-troubleshoot-9/README.md) — 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Taint toleration ve ext4 lost+found engeli (Postgres), Blok depolamada ReadWriteMany vs RWO çelişkisi ve Service selector sapması (Redis), InitContainer port hatası ve Liveness probe çelişkisi, ConfigMap port uyuşmazlığı (Readiness hatası ve trafik kara deliği) ve NetworkPolicy Ingress seçici hatası ile Nginx trailing slash URI kırpma arızası.
* [**k8-troubleshoot-10:** Chronos Dağıtık Sipariş ve Stok Koordinasyon Platformu Arıza Labı](./Troubleshoot/k8-troubleshoot-10/README.md) — Helm ve LoadBalancer mimarisi ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Python bellek sınırı yetersizliği (OOMKilled 137), 2-node katı podAntiAffinity zamanlama kilitlenmesi, ConfigMap vs extraEnv öncelik çatışması & 503 readiness hatası, Servis targetPort uyuşmazlığı & externalTrafficPolicy Local paket kara delik arızası ve L7 ağ geçidi güvenlik başlığı eksikliği ile ConfigMap sessiz yeniden yükleme (reload) engeli.
* [**k8-troubleshoot-11:** PulseStream Gerçek Zamanlı Analitik ve Raporlama Platformu Arıza Labı](./Troubleshoot/k8-troubleshoot-11/README.md) — Job, Helm, ReplicaSet, HPA ve DaemonSet ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Veritabanı göç işinde Job zaman aşımı (activeDeadlineSeconds: 4) ve hedef host hatası (Job nesnesi değiştirilemezliği - Immutability), Helm values hiyerarşi/kapsam tuzağı (Worker Redis bağlantı reddi), 2.5s sağlık yanıtına karşılık Kubelet prob zaman aşımı timeoutSeconds: 1 (ReplicaSet rollout kilitlenmesi), HPA hedef isim hatası ve eksik requests.cpu tanımı (Metrik açlığı), ve DaemonSet veritabanı taint toleration eksikliği ile Named Port servis 502 Bad Gateway arızası.
* [**k8-troubleshoot-12:** Vortex Dağıtık Servisler & Traefik Ingress Platformu Arıza Labı](./Troubleshoot/k8-troubleshoot-12/README.md) — Traefik Helm Ingress ve mikroservis mimarisi ile 5 zincirleme üretim arızası: Traefik Ingress Helm kontrolcüsünün yetkisiz (non-root) port 80 dinleme engeli (CrashLoopBackOff), Ingress pathType Exact ve StripPrefix yönlendirme hatası (HTTP 404), Auth-Service Secret anahtar adı uyuşmazlığı ve Redis servis keşif hatası, Payment-Service çoklu bölge TopologySpreadConstraint zamanlama kilitlenmesi, ve Notification-Dispatcher CronJob cgroup bellek sınırı yetersizliği (OOMKilled 137).
* [**k8-troubleshoot-13:** NovaEdge Gerçek Zamanlı Edge IoT & Ingress Akış Ağ Geçidi Arıza Labı](./Troubleshoot/k8-troubleshoot-13/README.md) — Edge Ingress LoadBalancer, DaemonSet ve akış mikroservisleri ile 5 zincirleme üretim arızası: Edge Ingress Helm LoadBalancer targetPort yönlendirme hatası, Ingress kaynağında IngressClassName ve backend servis portu 80 uyuşmazlığı, Stream API konteyner başlatma komut yolu hatası ve bellek tamponu doğrulama engeli, Edge Node DaemonSet Node-3 veritabanı taint toleration ve salt okunur (read-only) dosya sistemi yazma engeli, ve Stream Sync Worker HTTP olmayan kuyruk işleyicide HTTP readiness probe hatası ile Redis kanal adı uyuşmazlığı.
* [**k8-troubleshoot-14:** AegisGrid Dağıtık Tehdit İstihbaratı & Güvenlik Telemetri Platformu Arıza Labı](./Troubleshoot/k8-troubleshoot-14/README.md) — Job, CronJob, Helm, Service, DaemonSet ve Ingress/LoadBalancer ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Threat Feed Job `secretKeyRef` anahtar uyuşmazlığı & CronJob suspend/Redis DNS hatası, Helm `scanner-worker` InitContainer port hatası & `startupProbe` başlangıç bütçesi yetersizliği, `intel-api` readinessProbe port & ConfigMap upstream keşif hatası, `Service/intel-api` seçici etiket/targetPort yönlendirme kara deliği & `node-shield` DaemonSet `NoExecute` vs `NoSchedule` toleration hatası, ve Helm `aegis-gateway` Nginx 504/502/403 güvenlik anahtarı reddi ile ConfigMap `subPath` yeniden yükleme (reload) engeli.
* [**k8-troubleshoot-15:** QuantFlow Algoritmik Risk, Likidite Motoru & L7 Edge Gateway Arıza Labı](./Troubleshoot/k8-troubleshoot-15/README.md) — Job, CronJob, Helm, HPA, PDB, Service, DaemonSet ve Ingress/LoadBalancer ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Ledger Bootstrap Job `secretKeyRef`/DB host uyuşmazlığı & CronJob suspend/Redis port hatası, Helm `liquidity-worker` InitContainer Redis host, cgroup `OOMKilled` (`137`) & `livenessProbe` path 404 hatası, `risk-engine` `env` vs `envFrom` öncelik çatışması & HPA hedef/CPU request metrik açlığı, `Service/risk-engine` seçici/targetPort kara deliği & `latency-probe` DaemonSet taint anahtar/salt okunur VFS çökmesi, ve Helm `quant-gateway` LoadBalancer targetPort, `403` imza reddi (`subPath` reload) & Ingress bağlama hatası.
* [**k8-troubleshoot-16:** OmniCore Kurumsal Sipariş, Mutabakat, Telemetri & L7 Edge Platformu (Büyük Final / Genel Tekrar)](./Troubleshoot/k8-troubleshoot-16/README.md) — 7 katmanlı, 18 alt arızalı kapsamlı genel tekrar: StatefulSet taint etkisi (`NoExecute` vs `NoSchedule`), CSI `WaitForFirstConsumer` & ext4 `lost+found` (`subPath: pgdata`), Redis Servis `targetPort`, Batch `Job` değişmezliği & `CronJob` askıya alma, Helm `InitContainer` portu, cgroup `OOMKilled` (`137`) & `startupProbe` bütçesi, 2-node katı `podAntiAffinity` kilitlenmesi & `env` vs `envFrom` önceliği, HPA `requests.cpu` metrik açlığı & Servis seçici sapması, DaemonSet taint anahtarı & salt okunur VFS çökmesi, ve L7 Gateway `subPath` reload & Ingress bağlama.
* [**k8-troubleshoot-17:** AetherMesh Dağıtık Küresel Ödeme, Gerçek Zamanlı Stream ve Edge Telemetri Platformu (Genel Tekrar Labı)](./Troubleshoot/k8-troubleshoot-17/README.md) — 7 katmanlı, 18 alt arızalı kapsamlı genel tekrar: StatefulSet taint değer uyumu (`workload=database:NoSchedule`), ext4 `lost+found` (`subPath: pgdata`), Redis Servis `targetPort`, Batch `Job` secret key hatası (`CreateContainerConfigError`) & değişmezlik, `CronJob` askıya alma, Helm `stream-worker` InitContainer TCP portu, cgroup `OOMKilled` (`137`) & `startupProbe` bütçesi, 2-node katı `podAntiAffinity` zamanlama kilitlenmesi & `env` vs `envFrom` önceliği, HPA `requests.cpu` metrik açlığı & Servis seçici sapması, DaemonSet taint anahtarı & salt okunur VFS çökmesi, ve L7 Gateway `subPath` reload & Ingress bağlama.
* [**k8-troubleshoot-18:** NovaStore v2.4 Storefront Canlı Yayın Kesintisi (AKS + Helm)](./Troubleshoot/k8-troubleshoot-18/README.md) — Dış dünyadan Ingress erişimli e-ticaret vitrini ve Redis oturum önbelleğinde 6 zincirleme prodüksiyon arızası: Geçersiz CSI StorageClass (`managed-csi-fast`), Secret anahtar adı uyuşmazlığı (`CACHE_TOKEN` vs `REDIS_PASSWORD`), NetworkPolicy podSelector ve port izolasyon engeli (`tier: backend` & `6380`), kırık container image tag (`ImagePullBackOff`), Nginx probe path uyumsuzluğu (`/healthz` vs `/ready`), ve Service selector/targetPort yönlendirme kara deliği (`503 Service Unavailable`).
* [**k8-troubleshoot-19:** OmniPulse v3.0 Canlı Yayın & Mülakat Genel Tekrar Labı (AKS + Terraform + Helm)](./Troubleshoot/k8-troubleshoot-19/README.md) — Dış dünyadan Ingress IP ile canlı web sayfasına ulaşana kadar tüm temel Kubernetes objelerini (`StatefulSet`, Headless DNS, farklı node'lardaki birden fazla podun aynı `PVC`'yi bağlaması `ReadWriteOnce` vs `ReadWriteMany`, `Job` değişmezliği, `CronJob`, `DaemonSet`, `InitContainer`, `podAntiAffinity`, `OOMKilled`, `HPA`, `PDB`, `NetworkPolicy`, `Service` ve `Ingress`) uçtan uca kurcalatan 12 bağlantılı arıza senaryosu.
* [**Kubernetes L4/L7 Ingress ve Ağ Mimarisi Rehberi**](./K8S_INGRESS_TRAFFIC_ARCHITECTURE.md) — Dış dünyadan (Cloud LB) Ingress Controller'a, NodePort DNAT'tan API Gateway ve Backend Pod'larına kadar paket gidiş ve dönüş yolculuğu, Mermaid şeması ve port eşleştirme sözlüğü.
* [**tf-troubleshoot-1:** Drift, Import ve Silme Koruması (Azure, ücretsiz kaynaklar)](./Troubleshoot/tf-troubleshoot-1/README.md) — Portaldan elle yapılan NSG kural/etiket sapması, `-refresh-only`, yönetilmeyen subnet `already exists` → `import {}` bloğu ve `lifecycle.prevent_destroy`.
* [**tf-troubleshoot-2:** State Felaketleri (lokal)](./Troubleshoot/tf-troubleshoot-2/README.md) — State lock çakışması ve `force-unlock`, silinen `terraform.tfstate` dosyasının backup ile kurtarılması, `moved {}` / `terraform state mv` ile yeniden adlandırma.
* [**tf-troubleshoot-3:** Bozuk Kod, Cycle ve Replace (lokal)](./Troubleshoot/tf-troubleshoot-3/README.md) — 5 validate/plan hatası (tip uyuşmazlığı, tanımsız değişken, olmayan attribute, çift kaynak, döngüsel bağımlılık) ve `-replace` ile hedefli şifre rotasyonu.
* [**tf-troubleshoot-4:** ChronoPay Hattı Kesintisi (Terraform + Ansible)](./Troubleshoot/tf-troubleshoot-4/README.md) — 5 sıralı arıza: Terraform değişken tipleri, mükerrer kaynak ve tanımsız çıktılar, envanter aktarımı & `0600` dosya izinleri, Ansible grup eşleşmesi, komut idempotency ihlali vs `file:` modülü, Jinja2 tanımsız değişken ve handler isim uyuşmazlığı (`502 Bad Gateway`).
* [**tf-troubleshoot-5:** NexusVault State ve Öncelik Kesintisi](./Troubleshoot/tf-troubleshoot-5/README.md) — 5 sıralı arıza: Silinen `terraform.tfstate` dosyasının `.backup` üzerinden kurtarılması, korumalı kaynak refactoring (`prevent_destroy` + `moved {}`), `-replace` ile hedefli gizli anahtar rotasyonu, Ansible rol değişkeni öncelik tuzağı (`vars/` vs `group_vars/` vs `defaults/`) ve `when:` koşulunda tip dönüşümü (`503 Vault Kilitli`).
* [**tf-troubleshoot-6:** AegisCloud Çok Katmanlı Küme Kesintisi (İleri Seviye Bitirme)](./Troubleshoot/tf-troubleshoot-6/README.md) — 5 sıralı arıza: Kaynaklar arası döngüsel bağımlılık (`Error: Cycle`), dinamik envanter grubu uyuşmazlığı, sunucular arası `slurp:` Base64 join token çözümü (`| b64decode | trim`), `lineinfile` `regexp:` eksikliği kaynaklı mükerrer satır hatası ve Jinja2 LoadBalancer worker döngüsü yönlendirmesi.
