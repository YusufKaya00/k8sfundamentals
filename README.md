# 🚀 Cloud-Native Kubernetes, DevOps & Chaos Engineering Workspace

Welcome to the comprehensive **Kubernetes, Cloud Infrastructure, GitOps, Site Reliability Engineering (SRE), and Chaos Engineering** repository. This workspace represents an end-to-end journey from foundational container orchestration to enterprise-grade DevSecOps, multi-cloud topologies, polyglot data architectures, real-world incident triage simulations, and production chaos engineering.

All projects and troubleshooting scenarios are fully reproducible on local clusters (**Minikube**), managed cloud clusters (**Oracle Cloud OKE**, **Azure AKS**), and self-managed IaaS clusters (**Azure RKE2 & K3s via Terraform and Ansible**).

---

## 🧭 Repository Structure & Curriculum Index

```text
k8sfundamentals/
├── projects/
│   ├── k8-training/                 # Scratch / training manifests and deep-dive notes
│   ├── k8-project-1/                # Kubernetes Foundations (Deployments, StatefulSets, DaemonSets, Storage, Ingress)
│   ├── k8-project-2/                # Multi-Tier Microservices & Platform Hardening (Minikube 5-Node Cluster)
│   ├── k8-project-3/                # Production Enterprise Platform on OKE (3-Node Dedicated Cloud Cluster)
│   ├── k8-project-4/                # Observability & Batch Processing (Helm, Prometheus-Stack, Grafana, CronJobs)
│   ├── k8-project-5/                # GitOps & Progressive Delivery (ArgoCD, Argo Rollouts, Automated Canary Rollbacks)
│   ├── k8-project-6/                # Cloud-Native CI/CD & DevSecOps (GitLab Runner, Rootless Buildah, Trivy, SBOM)
│   ├── rk2-azure-project-1/         # 5-Node RKE2 High-Isolation Architecture on Azure (Master + Infra + PG + Mongo + App)
│   ├── rk2-azure-project-2/         # Automated 5-Node RKE2 + Rancher Dashboard (Terraform + Ansible + Multi-DB)
│   ├── terraform-ansible-1/         # IaC Intro: Azure single VM (Terraform) + K3s bootstrap (Ansible), auto-generated inventory
│   ├── terraform-ansible-2/         # IaC Multi-Node: Azure 1 Master + 1 Worker (Terraform) + K3s cluster join (Ansible) + Helm
│   ├── devops-capstone-project-4/   # StreamForge: Production GitOps, RKE2, Rancher, Multi-DB & CI/CD Pipeline
│   └── devops-capstone-project-5/   # ResilienceStream: Polyglot SRE Platform (Kafka, RabbitMQ, Cassandra, Postgres, Redis, Chaos Mesh)
│
└── troubleshoot/
    ├── chaos-troubleshooting-1/     # SRE Incident & Chaos Engineering Lab 1 (Web UI, 3 Resilient Checks, 3 Break-and-Fix Labs & Workflow)
    ├── k8-troubleshoot-1/           # ShopSphere E-Commerce (11 Cascading Multi-Object Failures)
    ├── k8-troubleshoot-2/           # NovaMarket Platform (7 Deep Topology & Stateful Failures)
    ├── k8-troubleshoot-3/           # ApexPay Gateway (7 Linux Security, VFS & Socket Failures)
    ├── k8-troubleshoot-4/           # PulseMed Telemetry (7 Service, Port & EndpointSlice Failures)
    ├── k8-troubleshoot-5/           # ApexPay Core Banking (5 Deep Service, Port & Mesh Routing Failures)
    ├── k8-troubleshoot-6/           # AeroOps Flight Radar (8 Cascading Service, Probe & Anti-Affinity Failures)
    ├── k8-troubleshoot-7/           # NexusLogistics (8 Storage, OOM, RBAC & Gateway Failures)
    ├── k8-troubleshoot-8/           # Helix Ledger (10 Deep RBAC, NetworkPolicy, StartupProbe & Topology Failures)
    ├── k8-troubleshoot-9/           # PayStream (5 Sequential Bottom-Up Failures: Scheduling, CSI, Probes, NetPol & Routing)
    ├── k8-troubleshoot-10/          # Chronos (5 Helm, LB, OOM, AntiAffinity & L7 Gateway Failures)
    ├── k8-troubleshoot-11/          # PulseStream (5 Job, Helm Scope, Probe Timeout, HPA & DaemonSet Failures)
    ├── k8-troubleshoot-12/          # Vortex (5 Traefik Ingress Helm, StripPrefix, Secret Ref, TopologySpread & CronJob OOM)
    ├── k8-troubleshoot-13/          # NovaEdge (5 Edge Ingress LB Port, IngressClass 404, Stream API, DaemonSet & Probe Failures)
    ├── k8-troubleshoot-14/          # AegisGrid (5 Secret/Job Immutability, Helm Init, Readiness, Toleration & L7 Gateway)
    ├── k8-troubleshoot-15/          # QuantFlow (5 Job/CronJob, Helm OOM/Liveness, Env Precedence & HPA, DaemonSet & L7)
    ├── k8-troubleshoot-16/          # OmniCore Grand Finale Capstone (7-Layer 18-Fault Master Review)
    ├── k8-troubleshoot-17/          # AetherMesh Production Capstone on AKS (7-Layer 18-Fault Review)
    ├── k8-troubleshoot-18/          # NovaStore v2.4 Storefront Live Crisis (6-Fault Cascading Production Outage on AKS)
    ├── k8-troubleshoot-19/          # OmniPulse v3.0 Full-Stack Capstone on AKS (12-Fault Master Kubernetes Object & Interview Review)
    ├── k8-troubleshoot-20/          # PayNexus v4.2.0 Real-Time Financial Settlement Crisis on AKS (Multi-Workload Helm Outage)
    ├── tf-troubleshoot-1/           # Terraform Lab 1 (Azure): State Drift, Import (already exists), prevent_destroy
    ├── tf-troubleshoot-2/           # Terraform Lab 2 (local): State Lock, Lost State recovery, Refactor (moved / state mv)
    ├── tf-troubleshoot-3/           # Terraform Lab 3 (local): Broken code (5 errors incl. Cycle), -replace / secret rotation
    ├── tf-troubleshoot-4/           # IaC Incident Lab 4: ChronoPay — Schema/Secret Mode, Inventory Handoff, Ansible Group/Become & Idempotency
    ├── tf-troubleshoot-5/           # IaC Incident Lab 5: NexusVault — State Wipe Recovery, Protected Rename (moved), -replace & Ansible Precedence
    └── tf-troubleshoot-6/           # IaC Incident Lab 6: AegisCloud — Multi-Tier Cluster (Dependency Cycle, Cross-Host hostvars, lineinfile & L7 LB)
```

---

## 🛠️ Technology Stack & Tooling

| Domain | Tools & Technologies |
| :--- | :--- |
| **Compute & Orchestration** | Kubernetes (v1.30 – v1.37), RKE2 (Rancher Kubernetes Engine 2), OCI OKE, Azure AKS, K3s, Minikube, containerd |
| **Infrastructure as Code** | Terraform (azurerm, local, random, templatefile), Ansible (idempotent playbooks, dynamic inventories, roles), Azure CLI |
| **Control Plane & Management** | Rancher Manager (v2.10+ Multi-Cluster Dashboard), Cert-Manager (Let's Encrypt / Self-Signed PKI), nip.io DNS routing |
| **Package & Config Management** | Helm 3, Kustomize, ConfigMaps, Secrets, Custom Resource Definitions (CRDs) |
| **Distributed Data & Messaging** | Apache Kafka (KRaft mode), RabbitMQ (DLQ & Exchanges), Apache Cassandra (LSM-Tree), PostgreSQL 16, Redis 7.2 |
| **Chaos Engineering & Resilience** | Chaos Mesh (PodChaos, NetworkChaos, DNSChaos, StressChaos, IOChaos, Workflows), Circuit Breaker, Exponential Backoff |
| **Storage & Persistence** | Local-Path Provisioner, OCI Block Volume (`oci-bv` CSI), Azure Managed Disks (`managed-csi`), PVCs, `subPath`, `fsGroup` |
| **Networking & Ingress** | Ingress NGINX Controller, Traefik Ingress, Calico / Canal CNI, Azure NAT Gateway, ClusterIP, Headless Services, CoreDNS |
| **GitOps & Progressive Delivery** | ArgoCD (Declarative Application Management, Auto-Sync, Self-Healing), Argo Rollouts (Canary, Blue/Green, AnalysisTemplates) |
| **CI/CD & DevSecOps** | GitLab CI (Kubernetes Executor), Rootless Buildah, Trivy Security Scanner, CycloneDX SBOM |
| **Observability & SRE** | Prometheus Operator, Grafana, Alertmanager, PromQL, ServiceMonitors, PrometheusRules, Kube-State-Metrics |
| **Application Runtimes** | Python (FastAPI, Uvicorn, background threads), Nginx (L7 Reverse Proxy), Docker multi-stage builds |

---

## 🌐 Production Cluster Topologies

### Topology A: Azure 3-Tier High-Performance SRE & Chaos Platform (`devops-capstone-project-5` & `chaos-troubleshooting-1`)
* **Region:** `denmarkeast` (Optimized for Azure for Students regional quota: 6 vCPUs & 3 Public IPs)
* **Tiered Node Architecture:**
  * **`vm-master` (`10.30.1.4`, Public IP #1):** `Standard_B2s_v2` (2 vCPU, **8 GB RAM**, 4 GB Swap) — RKE2 Control Plane, etcd, Ingress NGINX, Rancher, ArgoCD, Prometheus, Grafana, Alertmanager, Chaos Mesh Dashboard.
  * **`vm-worker-data` (`10.30.1.5`, Private Only):** `Standard_B2s` (2 vCPU, **4 GB RAM**) — Dedicated Data Tier (`dedicated=data:NoSchedule`): Apache Kafka (KRaft), Apache Cassandra (`768M` heap), PostgreSQL. Uses **Azure NAT Gateway (Public IP #3)** for secure outbound container pulling.
  * **`vm-worker-app` (`10.30.1.6`, Public IP #2):** `Standard_B2s` (2 vCPU, **4 GB RAM**) — Application Tier: `order-api` (x2), `analytics-consumer`, `payment-worker`, RabbitMQ, Redis, GitLab Runner.

### Topology B: OCI Container Engine for Kubernetes (OKE) (`k8-project-3`)
* **Control Plane:** Fully Managed Oracle Kubernetes Engine (Kubernetes v1.37.0)
* **Worker Nodes (3 Nodes, `VM.Standard.E3.Flex`, Oracle Linux 8.10 UEK):**
  * `10.0.10.122`: Web / Application Tier (`tier=web`, Untainted)
  * `10.0.10.208`: Web / Application Tier (`tier=web`, Untainted)
  * `10.0.10.78`: Dedicated Database Tier (`tier=database`, Taint: `workload=database:NoSchedule`)
* **Default StorageClass:** `oci-bv` (`blockvolume.csi.oraclecloud.com`, ext4, WaitForFirstConsumer)

### Topology C: Local Minikube Platform (`k8-project-2`)
* **Architecture:** 5 Nodes (1 Control-Plane + 4 Workers)
* **Features:** Ingress Controller (`nginx`), Metrics Server, Calico CNI, Local Storage Provisioner

### Topology D: Azure Self-Managed K3s via IaC (`terraform-ansible-1` & `2`)
* **Region:** `denmarkeast`, VM size `Standard_B2s`
* **Provisioning:** Terraform (RG, VNet `10.0.0.0/16`, Subnet `10.0.1.0/24`, NSG, Public IP, NIC, Ubuntu 24.04 VM)
* **Configuration:** Ansible (containerd, swap off, K3s) — inventory generated by Terraform `local_file`

---

## 📚 Project Summary & Deep-Dive Links

### 1. Hands-On Platform Projects (Build & Deploy)
* [**k8-project-1:** Core Kubernetes Primitives](./projects/k8-project-1/README.md) — Comprehensive hands-on coverage of Deployments, StatefulSets (MongoDB), DaemonSets, PersistentVolumes, PersistentVolumeClaims, Services, and Ingress routing.
* [**k8-project-2:** Platform Hardening on Minikube](./projects/k8-project-2/README.md) — 5-node multi-tenant architecture with `staging`/`production` namespaces, dedicated worker taints, NetworkPolicies, InitContainers, HPA, PDB, and RBAC client pods.
* [**k8-project-3:** Production Enterprise Platform on OCI OKE](./projects/k8-project-3/README.md) — Enterprise multi-tier deployment on cloud infrastructure with OCI Block Volume CSI, TopologySpreadConstraints, OCI Flexible Load Balancers, Redis StatefulSet, and node drain operations.
* [**k8-project-4:** SRE Observability & Batch Processing](./projects/k8-project-4/README.md) — Custom microservice Helm chart, production-tuned `kube-prometheus-stack`, Grafana dashboards, batch Jobs/CronJobs, ServiceMonitors, Alertmanager rules, and synthetic crash testing.
* [**k8-project-5:** GitOps & Progressive Delivery](./projects/k8-project-5/README.md) — Declarative ArgoCD GitOps pipelines, self-healing drift remediation, Argo Rollouts automated canary deployments, and Prometheus metric-based automated rollbacks.
* [**k8-project-6:** Cloud-Native CI/CD & DevSecOps Platform](./projects/k8-project-6/README.md) — Dynamic Kubernetes-executor GitLab Runner, rootless container image builds (Buildah), automated vulnerability scanning (Trivy), CycloneDX SBOM generation, and automated GitOps promotion.
* [**rk2-azure-project-1:** 5-Node High-Isolation RKE2 on Azure](./projects/rk2-azure-project-1/) — 1 Master (`Standard_B2s_v2`) + 4 Worker (`Standard_B1ms`: infra, pg, mongo, app) architecture with Taint/Toleration barriers, Local-Path Storage, CoreDNS service discovery, and Ingress routing.
* [**rk2-azure-project-2:** Automated RKE2 + Rancher UI Platform](./projects/rk2-azure-project-2/README.md) — Full IaC provisioning on Azure with Terraform, Ansible automated RKE2 bootstrap, cert-manager, visual Rancher Management UI, 3 database engines (Redis, PG, Mongo), and FastAPI deployment.
* [**terraform-ansible-1:** IaC Foundations on Azure](./projects/terraform-ansible-1/) — Single Azure VM provisioned with Terraform (VNet, NSG, Public IP, NIC), Ansible playbook bootstrapping containerd + K3s, idempotency validation, and dynamic inventory generation.
* [**terraform-ansible-2:** Multi-Node K3s via IaC on Azure](./projects/terraform-ansible-2/) — 1 Master + 1 Worker topology with Terraform, Ansible-driven automated cluster join, Helm-based LoadBalancer/Ingress, and multi-node workload distribution.
* [**devops-capstone-project-4:** StreamForge Enterprise GitOps Platform](./projects/devops-capstone-project-4/README.md) — End-to-end multi-service DevOps capstone: Azure IaaS (Terraform), Ansible multi-node RKE2 bootstrap, Rancher Server, ArgoCD GitOps, `kube-prometheus-stack` (5s scrape), multi-DB (Postgres, Mongo, Redis), and GitLab CI 4-stage pipeline.
* [**devops-capstone-project-5:** ResilienceStream SRE & Chaos Engineering Platform](./projects/devops-capstone-project-5/README.md) — Production-grade polyglot microservice ecosystem: Apache Kafka KRaft event streaming, RabbitMQ DLQ task queues, Apache Cassandra LSM-tree storage, PostgreSQL ACID store, Redis caching, Prometheus SLO burn-rate alerts, k6 Black Friday load testing, and 9 Chaos Mesh Game Days.

---

### 2. On-Call SRE Incident Triage & Chaos Engineering Labs (Troubleshooting)

* [**chaos-troubleshooting-1:** SRE Incident & Chaos Engineering Lab 1](./troubleshoot/chaos-troubleshooting-1/README.md) — **Hands-on Chaos Engineering & Root Cause Analysis:** 3 resilient control scenarios (Pod Kill load balancing, Redis DNS error graceful degradation, Kafka 300ms network delay) + 3 break-and-fix incident labs (PostgreSQL delay causing cyclic API restart loops via misconfigured Liveness Probe, single-replica `payment-worker` queue starvation in RabbitMQ, and `analytics-consumer` cgroup memory limit `OOMKilled 137` triggering Kafka LAG spikes). Features step-by-step Chaos Mesh Web UI guides, an operational cheat sheet, and an automated final Chaos Mesh Workflow.
* [**k8-troubleshoot-1:** ShopSphere E-Commerce Incident Triage](./troubleshoot/k8-troubleshoot-1/README.md) — 11 cascading tickets covering StorageClass mismatches, Secret key typos, Headless DNS failures, Service selector drift, Liveness Probe cyclic crashes, HPA metric starvation, DaemonSet taints, and RBAC core API group errors.
* [**k8-troubleshoot-2:** NovaMarket Platform Outage Triage](./troubleshoot/k8-troubleshoot-2/README.md) — 7 cascading production tickets: `NoExecute` vs `NoSchedule` toleration, ext4 `lost+found` initdb rejection, startupProbe budget starvation, `optional: true` silent failures, Service selector drift, and required anti-affinity deadlocks.
* [**k8-troubleshoot-3:** ApexPay Financial Gateway Outage Triage](./troubleshoot/k8-troubleshoot-3/README.md) — 7 system-level tickets: NodeAffinity label mismatch, non-root storage permissions (`fsGroup: 999`), excessive CPU requests (`Insufficient cpu`), VFS volume mount code overlay, probe timeout storms, named port resolution, and `127.0.0.1` localhost socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetry & Clinic Gateway Triage](./troubleshoot/k8-troubleshoot-4/README.md) — 7 network and service tickets: Taint key mismatch, Headless Service DNS NXDOMAIN, Service `targetPort` (6380 vs 6379), Probe port mismatch (8000 vs 8080), ConfigMap upstream port mismatch (5433 vs 5432), and Nginx `proxy_pass` port conflict (8080 vs 80).
* [**k8-troubleshoot-5:** ApexPay Banking & Service Mesh Triage](./troubleshoot/k8-troubleshoot-5/README.md) — 5 deep Kubernetes Service architectural tickets: Headless Service DNS naming contract, multi-label selector over-specification, port vs targetPort indirection, transport protocol mismatch (TCP vs UDP), and `externalTrafficPolicy: Local` packet blackholing.
* [**k8-troubleshoot-6:** AeroOps Flight Radar & Mesh Dispatch Triage](./troubleshoot/k8-troubleshoot-6/README.md) — 8 cascading production tickets: Taint toleration typo, Headless DNS NXDOMAIN, Redis targetPort mismatch, probe port failure CrashLoopBackOff, ConfigMap upstream port mismatch, Service selector label drift, Nginx 502 Bad Gateway upstream port conflict, and hard anti-affinity 2-node deadlock.
* [**k8-troubleshoot-7:** NexusLogistics Autonomous Dispatch Grid Triage](./troubleshoot/k8-troubleshoot-7/README.md) — 8 cascading production tickets: CSI StorageClass & AccessMode rejection (PVC Pending), Secret key typo (CreateContainerConfigError), InitContainer hostname typo, Memory limit starvation (OOMKilled 137), in-cluster RBAC 403 Forbidden, LoadBalancer selector drift, NGINX upstream 502 Bad Gateway, and 2-node hard anti-affinity deadlock.
* [**k8-troubleshoot-8:** Helix Ledger Platform Outage Triage](./troubleshoot/k8-troubleshoot-8/README.md) — 10 advanced production tickets: Taint NoExecute vs NoSchedule, ext4 lost+found initdb rejection, secretKeyRef optional silent failure, startupProbe budget starvation, NetworkPolicy AND vs OR selector trap, ServiceAccount token automount, RBAC subject namespace scoping, RBAC core apiGroups mismatches, NodeAffinity label mismatch, and Service selector tier drift.
* [**k8-troubleshoot-9:** PayStream Settlement Engine Triage](./troubleshoot/k8-troubleshoot-9/README.md) — 5 strictly linear, bottom-up production tickets: Taint toleration & ext4 lost+found (Postgres), Block Volume ReadWriteMany vs RWO & Service selector drift (Redis), InitContainer port mismatch & Liveness probe conflict, ConfigMap port mismatch (Readiness failure & traffic blackhole), and NetworkPolicy ingress selector & Nginx trailing slash path stripping.
* [**k8-troubleshoot-10:** Chronos Distributed Order & Inventory Platform Triage](./troubleshoot/k8-troubleshoot-10/README.md) — 5 strictly linear, bottom-up production tickets using Helm & LoadBalancer: Python memory cgroup limit starvation (OOMKilled 137), 2-node hard podAntiAffinity scheduling deadlock, ConfigMap vs extraEnv precedence & 503 readiness failure, Service targetPort mismatch & externalTrafficPolicy: Local packet blackholing, and missing L7 security gateway header with silent ConfigMap reload failure.
* [**k8-troubleshoot-11:** PulseStream Real-Time Analytics & Reporting Platform Triage](./troubleshoot/k8-troubleshoot-11/README.md) — 5 strictly linear, bottom-up production tickets: Job activeDeadlineSeconds & target host mismatch (Database Migration Immutability), Helm values hierarchy scope mismatch (Worker Redis connection refused), Python probe timeout timeoutSeconds: 1 (ReplicaSet rollout deadlock), HPA target name typo & missing requests.cpu (Unknown metrics starvation), and DaemonSet missing database taint toleration with Named Port Service 502 Bad Gateway.
* [**k8-troubleshoot-12:** Vortex Microservices Platform & Traefik Ingress Triage](./troubleshoot/k8-troubleshoot-12/README.md) — 5 cascading production tickets: Traefik Ingress Helm Controller non-root port 80 CrashLoopBackOff, Ingress pathType Exact & StripPrefix routing 404, Auth-Service Secret key typo & Redis DNS discovery, Payment-Service multi-zone TopologySpreadConstraint scheduling deadlock, and Notification-Dispatcher CronJob cgroup memory OOMKilled 137.
* [**k8-troubleshoot-13:** NovaEdge Real-Time Edge IoT & Ingress Gateway Triage](./troubleshoot/k8-troubleshoot-13/README.md) — 5 cascading production tickets: Edge Ingress Helm LoadBalancer targetPort mismatch, Ingress resource IngressClassName & backend port 80 resolution, Stream API container startup command path & buffer size validation crash, Edge Node DaemonSet Node-3 database taint & read-only volume permissions, and Stream Sync Worker async HTTP probe protocol & Redis channel mismatch.
* [**k8-troubleshoot-14:** AegisGrid Distributed Threat Intelligence & Security Telemetry Triage](./troubleshoot/k8-troubleshoot-14/README.md) — 5 strictly linear, bottom-up production tickets: Threat Feed Job `secretKeyRef` mismatch & CronJob suspend/Redis DNS drift, Helm `scanner-worker` InitContainer port & `startupProbe` budget starvation, `intel-api` readinessProbe port & ConfigMap upstream discovery failure, `Service/intel-api` selector/targetPort blackhole & `node-shield` DaemonSet `NoExecute` vs `NoSchedule` toleration, and Helm `aegis-gateway` Nginx 504/502/403 security token rejection with ConfigMap `subPath` reload.
* [**k8-troubleshoot-15:** QuantFlow Algorithmic Risk, Liquidity Engine & L7 Edge Gateway Triage](./troubleshoot/k8-troubleshoot-15/README.md) — 5 strictly linear, bottom-up production tickets: Ledger Bootstrap Job `secretKeyRef`/DB host mismatch & CronJob suspend/Redis port drift, Helm `liquidity-worker` InitContainer Redis host, cgroup `OOMKilled` (`137`) & `livenessProbe` path 404, `risk-engine` `env` vs `envFrom` override precedence & HPA target/CPU request starvation, `Service/risk-engine` selector/targetPort blackhole & `latency-probe` DaemonSet taint key/read-only VFS crash, and Helm `quant-gateway` LoadBalancer targetPort, `403` signature rejection with `subPath` reload & Ingress binding.
* [**k8-troubleshoot-16:** OmniCore Enterprise Order, Settlement, Telemetry & L7 Edge Platform (Grand Finale Capstone)](./troubleshoot/k8-troubleshoot-16/README.md) — 7-layer, 18-fault master review covering StatefulSet taint effect (`NoExecute` vs `NoSchedule`), CSI `WaitForFirstConsumer` & ext4 `lost+found` (`subPath: pgdata`), Redis Service `targetPort`, Batch `Job` immutability & `CronJob` suspension, Helm `InitContainer` port, cgroup `OOMKilled` (`137`) & `startupProbe` budget, 2-node hard `podAntiAffinity` deadlock & `env` vs `envFrom` precedence, HPA `requests.cpu` metric starvation & Service selector drift, DaemonSet taint key & read-only VFS crash, and L7 Gateway `subPath` reload & Ingress binding.
* [**k8-troubleshoot-17:** AetherMesh Distributed Global Payment, Real-Time Event Processing & Edge Telemetry Platform (Master Review)](./troubleshoot/k8-troubleshoot-17/README.md) — 7-layer, 18-fault comprehensive master review covering StatefulSet taint value matching (`workload=database:NoSchedule`), ext4 `lost+found` (`subPath: pgdata`), Redis Service `targetPort`, Batch `Job` secret key typo (`CreateContainerConfigError`) & immutability, `CronJob` suspension, Helm `stream-worker` InitContainer TCP portu, cgroup `OOMKilled` (`137`) & `startupProbe` warmup budget, 2-node hard `podAntiAffinity` scheduling deadlock & `env` vs `envFrom` precedence, HPA `requests.cpu` metric starvation & Service selector drift, DaemonSet taint key & read-only VFS crash, and L7 Gateway `subPath` reload & Ingress binding.
* [**k8-troubleshoot-18:** NovaStore v2.4 Storefront Live Crisis (AKS + Helm)](./troubleshoot/k8-troubleshoot-18/README.md) — 6-fault cascading production outage on AKS covering CSI StorageClass (`managed-csi`), Secret key matching, NetworkPolicy podSelector/port filtering, ImagePullBackOff tag fix, Nginx readiness/liveness probe paths, and Service selector/targetPort routing.
* [**k8-troubleshoot-19:** OmniPulse v3.0 Full-Stack Capstone on AKS (Master Object & Interview Review)](./troubleshoot/k8-troubleshoot-19/README.md) — 12-fault comprehensive Kubernetes object review on AKS (`StatefulSet`, Headless DNS, `PVC` `ReadWriteOnce` vs `ReadWriteMany` across multiple pods/nodes, `Job` immutability, `CronJob`, `DaemonSet`, `InitContainer`, `podAntiAffinity`, `OOMKilled`, `HPA`, `PDB`, `NetworkPolicy`, `Service`, and `Ingress`).
* [**k8-troubleshoot-20:** PayNexus v4.2.0 Real-Time Financial Settlement Platform Crisis on AKS](./troubleshoot/k8-troubleshoot-20/README.md) — Multi-workload enterprise outage following a major Helm rollout: PostgreSQL StatefulSet storage binding, DB migration Job immutability, multi-node shared report volume deadlock, Node security DaemonSet scheduling, and Web Ingress gateway routing.

---

### 3. Terraform Troubleshooting Labs (IaC Incident Response)
* [**tf-troubleshoot-1:** Drift, Import & Destroy Protection (Azure, free resources)](./troubleshoot/tf-troubleshoot-1/README.md) — Manual portal changes (NSG rule & tag drift), `-refresh-only`, unmanaged subnet `already exists` → `import {}` block, and `lifecycle.prevent_destroy`.
* [**tf-troubleshoot-2:** State Disasters (local)](./troubleshoot/tf-troubleshoot-2/README.md) — State lock contention & `force-unlock`, deleted `terraform.tfstate` recovery from backup, resource rename refactor with `moved {}` / `terraform state mv`.
* [**tf-troubleshoot-3:** Broken Code, Cycles & Replace (local)](./troubleshoot/tf-troubleshoot-3/README.md) — 5 validate/plan errors (type mismatch, undeclared variable, unsupported attribute, duplicate resource, dependency cycle) and targeted secret rotation with `-replace`.
* [**tf-troubleshoot-4:** ChronoPay Pipeline Outage (Terraform + Ansible)](./troubleshoot/tf-troubleshoot-4/README.md) — 5 sequential tickets: Terraform variable types, duplicate resource & undeclared outputs, inventory handoff & `0600` secret permissions, Ansible host group matching, raw command idempotency vs `file:` module, Jinja2 undefined variable, and handler notification name mismatch (`502 Bad Gateway`).
* [**tf-troubleshoot-5:** NexusVault Stateful Outage (State Disasters & Precedence)](./troubleshoot/tf-troubleshoot-5/README.md) — 5 sequential tickets: Missing `terraform.tfstate` recovery from `.backup`, protected resource refactoring (`prevent_destroy` + `moved {}`), targeted secret rotation with `-replace`, Ansible role variable precedence trap (`vars/` vs `group_vars/` vs `defaults/`), and conditional `when:` string-vs-int evaluation (`503 Vault Sealed`).
* [**tf-troubleshoot-6:** AegisCloud Multi-Tier Cluster Outage (Advanced Capstone)](./troubleshoot/tf-troubleshoot-6/README.md) — 5 sequential tickets: Cross-resource dependency cycle (`Error: Cycle`), dynamic inventory group mismatch, cross-host `slurp:` Base64 join token decoding (`| b64decode | trim`), `lineinfile` missing `regexp:` duplicate config bug, and Jinja2 LoadBalancer upstream loop routing to workers.

---

<br>

---

## 🇹🇷 Türkçe Versiyon / Turkish Version

# 🚀 Bulut-Yerel Kubernetes, DevOps & Kaos Mühendisliği Çalışma Alanı

Bu depo; temel konteyner orkestrasyonundan kurumsal DevSecOps, çoklu bulut topolojileri, çoklu veritabanı (polyglot data) mimarileri, GitOps, SRE gözlemlenebilirlik pratikleri, gerçek zamanlı arıza kurtarma (incident triage) ve üretim seviyesi **Kaos Mühendisliği (Chaos Engineering)** tatbikatlarına kadar uzanan uçtan uca bir **Platform Mühendisliği** çalışma alanıdır.

Tüm projeler ve sorun giderme laboratuvarları hem yerel kümelerde (**Minikube**), hem yönetilen genel bulut kümelerinde (**Oracle Cloud OKE**, **Azure AKS**), hem de Infrastructure-as-Code ile otomatik kurulan IaaS ortamlarında (**Azure RKE2 & K3s, Terraform + Ansible**) çalıştırılabilir şekilde tasarlanmıştır.

---

### 📂 Proje ve Laboratuvar Haritası

#### 1. Uygulamalı Platform Projeleri (Kurulum, Dağıtım & DevSecOps)
* [**k8-project-1:** Temel Kubernetes Nesneleri](./projects/k8-project-1/README.md) — Deployment, StatefulSet (MongoDB), DaemonSet, PV/PVC, StorageClass, Service ve Ingress temelleri.
* [**k8-project-2:** Çok Katmanlı Platform Güçlendirme (Minikube)](./projects/k8-project-2/README.md) — 5 node'lu kümede staging/production ayrımı, dedicated taint/toleration, NetworkPolicy, InitContainer, HPA, PDB ve RBAC.
* [**k8-project-3:** OCI OKE Üretim Ortamı Mimarisi](./projects/k8-project-3/README.md) — OCI Block Volume (oci-bv CSI), TopologySpread, OCI Flexible Load Balancer, Redis StatefulSet ve kontrollü node drain operasyonları.
* [**k8-project-4:** SRE Gözlemlenebilirlik ve Batch Süreçler](./projects/k8-project-4/README.md) — Custom Helm chart, optimize `kube-prometheus-stack`, Grafana panelleri, CronJob yedekleme, ServiceMonitor ve Alertmanager alarm kuralları.
* [**k8-project-5:** GitOps ve İlerici Dağıtım (ArgoCD & Argo Rollouts)](./projects/k8-project-5/README.md) — Deklaratif ArgoCD yönetimi, self-healing sürüklenme engelleme, Canary dağıtımları ve Prometheus metrik tabanlı otomatik rollback.
* [**k8-project-6:** Bulut-Yerel CI/CD ve DevSecOps Hattı](./projects/k8-project-6/README.md) — Dinamik GitLab Runner, rootless Buildah ile imaj derleme, Trivy güvenlik kapısı (vulnerability gating), SBOM üretimi ve GitOps köprüsü.
* [**rk2-azure-project-1:** 5 Node'lu Yüksek İzolasyonlu Manuel RKE2 Kümesi](./projects/rk2-azure-project-1/) — Azure üzerinde 1 Master (`Standard_B2s_v2`) + 4 Worker (`Standard_B1ms`: infra, pg, mongo, app), Taint/Toleration kalkanları, Local-Path Storage, CoreDNS servis ağı ve Ingress doğrulaması.
* [**rk2-azure-project-2:** Otomatik 5-Node RKE2 + Rancher Dashboard (Terraform & Ansible)](./projects/rk2-azure-project-2/README.md) — Azure altyapısının Terraform ile kurulması, Ansible ile RKE2 bootstrap, cert-manager, görsel Rancher Dashboard arayüzü, 3 veritabanı (Redis, PG, Mongo) ve FastAPI mikroservisinin tam otomasyonu.
* [**terraform-ansible-1:** Azure Üzerinde IaC Giriş](./projects/terraform-ansible-1/) — Terraform ile tek Azure VM (VNet, NSG, Public IP, NIC), Ansible ile containerd + K3s kurulumu, idempotency gösterimi ve Terraform tarafından otomatik üretilen Ansible inventory.
* [**terraform-ansible-2:** Azure Üzerinde Multi-Node K3s](./projects/terraform-ansible-2/) — Terraform ile 1 Master + 1 Worker, Ansible ile cluster join, Helm ile LoadBalancer/Ingress ve basit web uygulaması.
* [**devops-capstone-project-4:** StreamForge Kurumsal GitOps & DevOps Bitirme Projesi](./projects/devops-capstone-project-4/README.md) — Azure IaaS (Terraform), Ansible multi-node RKE2 kurulumu, Rancher Server, ArgoCD GitOps, 5s kazımalı `kube-prometheus-stack`, çoklu veritabanı (PostgreSQL, MongoDB, Redis) ve 4 aşamalı GitLab CI DevSecOps hattı.
* [**devops-capstone-project-5:** ResilienceStream SRE ve Kaos Mühendisliği Platformu](./projects/devops-capstone-project-5/README.md) — Apache Kafka KRaft olay akışı, RabbitMQ DLQ görev kuyruğu, Apache Cassandra LSM-tree zaman serisi, PostgreSQL ACID kayıt sistemi, Redis önbellek, Prometheus SLO alarmları, k6 Black Friday yük testi ve 9 Kaos Deneyi (Chaos Mesh Game Days).

---

#### 2. Nöbetçi SRE Olay Müdahale & Kaos Mühendisliği Laboratuvarları (Troubleshooting)
* [**chaos-troubleshooting-1:** SRE Incident & Kaos Mühendisliği Labı 1](./troubleshoot/chaos-troubleshooting-1/README.md) — **Uygulamalı Kaos Mühendisliği ve Kök Neden Analizi:** 3 sağlam kontrol deneyi (Pod Kill yük dengeleme, Redis DNS kesintisinde Graceful Degradation, Kafka 300ms ağ gecikmesi) + 3 kasıtlı patlayan arıza laboratuvarı (PostgreSQL gecikmesinde yanlış Liveness Probe yüzünden kaskad API çöküşü, tek replika `payment-worker` arızasında RabbitMQ kuyruk şişmesi, `analytics-consumer` cgroup bellek sınırı yetersizliğinde `OOMKilled 137` ve Kafka LAG artışı). Adım adım Chaos Mesh Web UI form doldurma rehberleri, sistem teşhis el kitabı ve final otomatik Chaos Workflow içerir.
* [**k8-troubleshoot-1:** ShopSphere E-Ticaret Arıza Kurtarma Labı](./troubleshoot/k8-troubleshoot-1/README.md) — 11 zincirleme bilet: StorageClass, Headless DNS, Service selector, Liveness probe, HPA, DaemonSet taint ve RBAC core apiGroups.
* [**k8-troubleshoot-2:** NovaMarket Canlı Kesinti Müdahale Labı](./troubleshoot/k8-troubleshoot-2/README.md) — 7 üretim arızası: Toleration NoExecute vs NoSchedule, ext4 lost+found initdb engeli, startupProbe bütçesi, `optional: true` sessiz hatası ve katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-3:** ApexPay Finansal Gateway Arıza Kurtarma Labı](./troubleshoot/k8-troubleshoot-3/README.md) — 7 sistem seviyesi arıza: NodeAffinity, non-root `fsGroup: 999`, gerçek dışı CPU isteği, VFS mount kod ezmesi, probe timeout ve `127.0.0.1` socket binding.
* [**k8-troubleshoot-4:** PulseMed Telemetri Servis & Port Arıza Labı](./troubleshoot/k8-troubleshoot-4/README.md) — 7 ağ ve port arızası: Taint key uyuşmazlığı, Headless DNS NXDOMAIN, `port` vs `targetPort`, Probe port uyuşmazlığı, ConfigMap port hatası ve Nginx `proxy_pass` port çatışması.
* [**k8-troubleshoot-5:** ApexPay Çekirdek Bankacılık & Servis Ağı Arıza Labı](./troubleshoot/k8-troubleshoot-5/README.md) — 5 derin Kubernetes Servis mimarisi arızası: Headless Service DNS sözleşmesi, selector etiket fazlalığı (empty endpoints), port / targetPort yönlendirme hatası, TCP vs UDP protokol çelişkisi ve externalTrafficPolicy Local paket kara delik (blackhole) arızası.
* [**k8-troubleshoot-6:** AeroOps Uçuş Radar & Servis Ağı Arıza Labı](./troubleshoot/k8-troubleshoot-6/README.md) — 8 zincirleme üretim arızası: Taint toleration yazım hatası, Headless DNS NXDOMAIN, Redis targetPort hatası, probe port çelişkisi CrashLoopBackOff, ConfigMap upstream port hatası, Service selector etiket sürüklenmesi, Nginx 502 Bad Gateway port çatışması ve katı anti-affinity 2-node kilitlenmesi.
* [**k8-troubleshoot-7:** NexusLogistics Otonom Sevkiyat Ağı Arıza Labı](./troubleshoot/k8-troubleshoot-7/README.md) — 8 zincirleme üretim arızası: CSI StorageClass & AccessMode reddi (PVC Pending), Secret key yazım hatası (CreateContainerConfigError), InitContainer hostname hatası, cgroup bellek sınırı (OOMKilled 137), küme içi RBAC 403 Forbidden, LoadBalancer seçici etiket sapması, NGINX upstream 502 Bad Gateway ve 2-node katı anti-affinity kilitlenmesi.
* [**k8-troubleshoot-8:** Helix Ledger Canlı Kesinti & İleri Düzey RBAC/Ağ Müdahale Labı](./troubleshoot/k8-troubleshoot-8/README.md) — 10 ileri düzey üretim arızası: Taint NoExecute vs NoSchedule uyuşmazlığı, ext4 lost+found initdb engeli, secretKeyRef optional sessiz hatası, startupProbe bütçesi tükenmesi, NetworkPolicy AND/OR seçici tuzağı, ServiceAccount token automount eksikliği, RoleBinding namespace kapsam hatası, RBAC core apiGroups uyuşmazlığı, NodeAffinity etiket hatası ve Service selector sürüklenmesi.
* [**k8-troubleshoot-9:** PayStream Ödeme ve Mutabakat Sistemi Arıza Labı](./troubleshoot/k8-troubleshoot-9/README.md) — 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Taint toleration ve ext4 lost+found engeli (Postgres), Blok depolamada ReadWriteMany vs RWO çelişkisi ve Service selector sapması (Redis), InitContainer port hatası ve Liveness probe çelişkisi, ConfigMap port uyuşmazlığı (Readiness hatası ve trafik kara deliği) ve NetworkPolicy Ingress seçici hatası ile Nginx trailing slash URI kırpma arızası.
* [**k8-troubleshoot-10:** Chronos Dağıtık Sipariş ve Stok Koordinasyon Platformu Arıza Labı](./troubleshoot/k8-troubleshoot-10/README.md) — Helm ve LoadBalancer mimarisi ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Python bellek sınırı yetersizliği (OOMKilled 137), 2-node katı podAntiAffinity zamanlama kilitlenmesi, ConfigMap vs extraEnv öncelik çatışması & 503 readiness hatası, Servis targetPort uyuşmazlığı & externalTrafficPolicy Local paket kara delik arızası ve L7 ağ geçidi güvenlik başlığı eksikliği ile ConfigMap sessiz yeniden yükleme (reload) engeli.
* [**k8-troubleshoot-11:** PulseStream Gerçek Zamanlı Analitik ve Raporlama Platformu Arıza Labı](./troubleshoot/k8-troubleshoot-11/README.md) — Job, Helm, ReplicaSet, HPA ve DaemonSet ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Veritabanı göç işinde Job zaman aşımı (activeDeadlineSeconds: 4) ve hedef host hatası (Job nesnesi değiştirilemezliği - Immutability), Helm values hiyerarşi/kapsam tuzağı (Worker Redis bağlantı reddi), 2.5s sağlık yanıtına karşılık Kubelet prob zaman aşımı timeoutSeconds: 1 (ReplicaSet rollout kilitlenmesi), HPA hedef isim hatası ve eksik requests.cpu tanımı (Metrik açlığı), ve DaemonSet veritabanı taint toleration eksikliği ile Named Port servis 502 Bad Gateway arızası.
* [**k8-troubleshoot-12:** Vortex Dağıtık Servisler & Traefik Ingress Platformu Arıza Labı](./troubleshoot/k8-troubleshoot-12/README.md) — Traefik Helm Ingress ve mikroservis mimarisi ile 5 zincirleme üretim arızası: Traefik Ingress Helm kontrolcüsünün yetkisiz (non-root) port 80 dinleme engeli (CrashLoopBackOff), Ingress pathType Exact ve StripPrefix yönlendirme hatası (HTTP 404), Auth-Service Secret anahtar adı uyuşmazlığı ve Redis servis keşif hatası, Payment-Service çoklu bölge TopologySpreadConstraint zamanlama kilitlenmesi, ve Notification-Dispatcher CronJob cgroup bellek sınırı yetersizliği (OOMKilled 137).
* [**k8-troubleshoot-13:** NovaEdge Gerçek Zamanlı Edge IoT & Ingress Akış Ağ Geçidi Arıza Labı](./troubleshoot/k8-troubleshoot-13/README.md) — Edge Ingress LoadBalancer, DaemonSet ve akış mikroservisleri ile 5 zincirleme üretim arızası: Edge Ingress Helm LoadBalancer targetPort yönlendirme hatası, Ingress kaynağında IngressClassName ve backend servis portu 80 uyuşmazlığı, Stream API konteyner başlatma komut yolu hatası ve bellek tamponu doğrulama engeli, Edge Node DaemonSet Node-3 veritabanı taint toleration ve salt okunur (read-only) dosya sistemi yazma engeli, ve Stream Sync Worker HTTP olmayan kuyruk işleyicide HTTP readiness probe hatası ile Redis kanal adı uyuşmazlığı.
* [**k8-troubleshoot-14:** AegisGrid Dağıtık Tehdit İstihbaratı & Güvenlik Telemetri Platformu Arıza Labı](./troubleshoot/k8-troubleshoot-14/README.md) — Job, CronJob, Helm, Service, DaemonSet ve Ingress/LoadBalancer ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Threat Feed Job `secretKeyRef` anahtar uyuşmazlığı & CronJob suspend/Redis DNS hatası, Helm `scanner-worker` InitContainer port hatası & `startupProbe` başlangıç bütçesi yetersizliği, `intel-api` readinessProbe port & ConfigMap upstream keşif hatası, `Service/intel-api` seçici etiket/targetPort yönlendirme kara deliği & `node-shield` DaemonSet `NoExecute` vs `NoSchedule` toleration hatası, ve Helm `aegis-gateway` Nginx 504/502/403 güvenlik anahtarı reddi ile ConfigMap `subPath` yeniden yükleme (reload) engeli.
* [**k8-troubleshoot-15:** QuantFlow Algoritmik Risk, Likidite Motoru & L7 Edge Gateway Arıza Labı](./troubleshoot/k8-troubleshoot-15/README.md) — Job, CronJob, Helm, HPA, PDB, Service, DaemonSet ve Ingress/LoadBalancer ile 5 kesinlikle doğrusal ve aşağıdan yukarıya (bottom-up) üretim arızası: Ledger Bootstrap Job `secretKeyRef`/DB host uyuşmazlığı & CronJob suspend/Redis port hatası, Helm `liquidity-worker` InitContainer Redis host, cgroup `OOMKilled` (`137`) & `livenessProbe` path 404 hatası, `risk-engine` `env` vs `envFrom` öncelik çatışması & HPA hedef/CPU request metrik açlığı, `Service/risk-engine` seçici/targetPort kara deliği & `latency-probe` DaemonSet taint anahtar/salt okunur VFS çökmesi, ve Helm `quant-gateway` LoadBalancer targetPort, `403` imza reddi (`subPath` reload) & Ingress bağlama hatası.
* [**k8-troubleshoot-16:** OmniCore Kurumsal Sipariş, Mutabakat, Telemetri & L7 Edge Platformu (Büyük Final / Genel Tekrar)](./troubleshoot/k8-troubleshoot-16/README.md) — 7 katmanlı, 18 alt arızalı kapsamlı genel tekrar: StatefulSet taint etkisi (`NoExecute` vs `NoSchedule`), CSI `WaitForFirstConsumer` & ext4 `lost+found` (`subPath: pgdata`), Redis Servis `targetPort`, Batch `Job` değişmezliği & `CronJob` askıya alma, Helm `InitContainer` portu, cgroup `OOMKilled` (`137`) & `startupProbe` bütçesi, 2-node katı `podAntiAffinity` kilitlenmesi & `env` vs `envFrom` önceliği, HPA `requests.cpu` metrik açlığı & Servis seçici sapması, DaemonSet taint anahtarı & salt okunur VFS çökmesi, ve L7 Gateway `subPath` reload & Ingress bağlama.
* [**k8-troubleshoot-17:** AetherMesh Dağıtık Küresel Ödeme, Gerçek Zamanlı Stream ve Edge Telemetri Platformu (Genel Tekrar Labı)](./troubleshoot/k8-troubleshoot-17/README.md) — 7 katmanlı, 18 alt arızalı kapsamlı genel tekrar: StatefulSet taint değer uyumu (`workload=database:NoSchedule`), ext4 `lost+found` (`subPath: pgdata`), Redis Servis `targetPort`, Batch `Job` secret key hatası (`CreateContainerConfigError`) & değişmezlik, `CronJob` askıya alma, Helm `stream-worker` InitContainer TCP portu, cgroup `OOMKilled` (`137`) & `startupProbe` bütçesi, 2-node katı `podAntiAffinity` zamanlama kilitlenmesi & `env` vs `envFrom` önceliği, HPA `requests.cpu` metrik açlığı & Servis seçici sapması, DaemonSet taint anahtarı & salt okunur VFS çökmesi, ve L7 Gateway `subPath` reload & Ingress bağlama.
* [**k8-troubleshoot-18:** NovaStore v2.4 Storefront Canlı Yayın Kesintisi (AKS + Helm)](./troubleshoot/k8-troubleshoot-18/README.md) — Dış dünyadan Ingress erişimli e-ticaret vitrini ve Redis oturum önbelleğinde 6 zincirleme prodüksiyon arızası: Geçersiz CSI StorageClass (`managed-csi-fast`), Secret anahtar adı uyuşmazlığı (`CACHE_TOKEN` vs `REDIS_PASSWORD`), NetworkPolicy podSelector ve port izolasyon engeli (`tier: backend` & `6380`), kırık container image tag (`ImagePullBackOff`), Nginx probe path uyumsuzluğu (`/healthz` vs `/ready`), ve Service selector/targetPort yönlendirme kara deliği (`503 Service Unavailable`).
* [**k8-troubleshoot-19:** OmniPulse v3.0 Canlı Yayın & Mülakat Genel Tekrar Labı (AKS + Terraform + Helm)](./troubleshoot/k8-troubleshoot-19/README.md) — Dış dünyadan Ingress IP ile canlı web sayfasına ulaşana kadar tüm temel Kubernetes objelerini (`StatefulSet`, Headless DNS, farklı node'lardaki birden fazla podun aynı `PVC`'yi bağlaması `ReadWriteOnce` vs `ReadWriteMany`, `Job` değişmezliği, `CronJob`, `DaemonSet`, `InitContainer`, `podAntiAffinity`, `OOMKilled`, `HPA`, `PDB`, `NetworkPolicy`, `Service` ve `Ingress`) uçtan uca kurcalatan 12 bağlantılı arıza senaryosu.
* [**k8-troubleshoot-20:** PayNexus v4.2.0 Gerçek Zamanlı Finans & Mutabakat Platformu Yayını Sonrası Tam Kesinti](./troubleshoot/k8-troubleshoot-20/README.md) — Helm ile tek pakette birleştirilmiş kurumsal finans sisteminde büyük canlı yayın kesintisi: PostgreSQL StatefulSet disk bağlama engeli, `paynexus-migrator` Job değişmezliği, tüm worker podlarının ortak okuduğu `paynexus-shared-html` paylaşımlı PVC arızası, küme geneli `DaemonSet` güvenlik ajanı ve Web Ingress yönlendirme kara deliği.
* [**Kubernetes L4/L7 Ingress ve Ağ Mimarisi Rehberi**](./K8S_INGRESS_TRAFFIC_ARCHITECTURE.md) — Dış dünyadan (Cloud LB) Ingress Controller'a, NodePort DNAT'tan API Gateway ve Backend Pod'larına kadar paket gidiş ve dönüş yolculuğu, Mermaid şeması ve port eşleştirme sözlüğü.

---

#### 3. Terraform ve Altyapı Sorun Giderme Laboratuvarları (IaC Incident Response)
* [**tf-troubleshoot-1:** Drift, Import ve Silme Koruması (Azure, ücretsiz kaynaklar)](./troubleshoot/tf-troubleshoot-1/README.md) — Portaldan elle yapılan NSG kural/etiket sapması, `-refresh-only`, yönetilmeyen subnet `already exists` → `import {}` bloğu ve `lifecycle.prevent_destroy`.
* [**tf-troubleshoot-2:** State Felaketleri (lokal)](./troubleshoot/tf-troubleshoot-2/README.md) — State lock çakışması ve `force-unlock`, silinen `terraform.tfstate` dosyasının backup ile kurtarılması, `moved {}` / `terraform state mv` ile yeniden adlandırma.
* [**tf-troubleshoot-3:** Bozuk Kod, Cycle ve Replace (lokal)](./troubleshoot/tf-troubleshoot-3/README.md) — 5 validate/plan hatası (tip uyuşmazlığı, tanımsız değişken, olmayan attribute, çift kaynak, döngüsel bağımlılık) ve `-replace` ile hedefli şifre rotasyonu.
* [**tf-troubleshoot-4:** ChronoPay Hattı Kesintisi (Terraform + Ansible)](./troubleshoot/tf-troubleshoot-4/README.md) — 5 sıralı arıza: Terraform değişken tipleri, mükerrer kaynak ve tanımsız çıktılar, envanter aktarımı & `0600` dosya izinleri, Ansible grup eşleşmesi, komut idempotency ihlali vs `file:` modülü, Jinja2 tanımsız değişken ve handler isim uyuşmazlığı (`502 Bad Gateway`).
* [**tf-troubleshoot-5:** NexusVault State ve Öncelik Kesintisi](./troubleshoot/tf-troubleshoot-5/README.md) — 5 sıralı arıza: Silinen `terraform.tfstate` dosyasının `.backup` üzerinden kurtarılması, korumalı kaynak refactoring (`prevent_destroy` + `moved {}`), `-replace` ile hedefli gizli anahtar rotasyonu, Ansible rol değişkeni öncelik tuzağı (`vars/` vs `group_vars/` vs `defaults/`) ve `when:` koşulunda tip dönüşümü (`503 Vault Kilitli`).
* [**tf-troubleshoot-6:** AegisCloud Çok Katmanlı Küme Kesintisi (İleri Seviye Bitirme)](./troubleshoot/tf-troubleshoot-6/README.md) — 5 sıralı arıza: Kaynaklar arası döngüsel bağımlılık (`Error: Cycle`), dinamik envanter grubu uyuşmazlığı, sunucular arası `slurp:` Base64 join token çözümü (`| b64decode | trim`), `lineinfile` `regexp:` eksikliği kaynaklı mükerrer satır hatası ve Jinja2 LoadBalancer worker döngüsü yönlendirmesi.
