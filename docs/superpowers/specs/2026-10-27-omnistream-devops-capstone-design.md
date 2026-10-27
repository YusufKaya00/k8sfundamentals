# OmniStream Enterprise DevSecOps, GitOps, Event-Driven (Kafka + 3 DB) & Observability Platform — Design Specification

**Date:** 2026-10-27  
**Target Directory:** `Projects/devops-capstone-project-4`  
**Cloud & Quota Profile:** Azure for Students (`denmarkeast`, 6 vCPU total = `1x Standard_B2s_v2` + `4x Standard_B1ms`, 3 Public IPs total)

---

## 1. Purpose & Learning Goals

Build a comprehensive, industry-standard 5-node RKE2 Kubernetes platform on Azure that integrates:
1. **Modular Terraform IaC** (`versions.tf`, `variables.tf`, `network.tf`, `compute.tf`, `outputs.tf`) with line-by-line Turkish architectural comments explaining *why* every resource and parameter is used in production.
2. **Production Ansible Automation** (`01-os-hardening.yml`, `02-rke2-control-plane.yml`, `03-rke2-workers.yml`, `04-cluster-labels-storage.yml`, `05-platform-stack.yml`) with detailed Turkish instructional comments explaining Linux kernel tuning, RKE2 bootstrap, webhook readiness synchronization, Taint/Toleration isolation, and Helm deployments.
3. **Polyglot Persistence & Event Streaming (`data` namespace):**
   - **Apache Kafka (KRaft mode — ZooKeeper-less)** + **Redis 7** on `vm-worker-stream` (`tier=stream`, Taint: `dedicated=stream:NoSchedule`).
   - **PostgreSQL 16** on `vm-worker-sql` (`tier=db-sql`, Taint: `dedicated=db-sql:NoSchedule`).
   - **MongoDB 7** on `vm-worker-nosql` (`tier=db-nosql`, Taint: `dedicated=db-nosql:NoSchedule`).
4. **Control Plane, Management & Observability (`vm-master` — 8 GB RAM):**
   - **Rancher UI** (`rancher.<MASTER_IP>.nip.io`) in `cattle-system`.
   - **ArgoCD** (`argocd.<MASTER_IP>.nip.io`) in `argocd`.
   - **Prometheus & Grafana (`kube-prometheus-stack`)** (`grafana.<MASTER_IP>.nip.io`) in `monitoring`.
5. **DevSecOps CI/CD & Event-Driven Application (`vm-worker-app` — `tier=app`):**
   - **Event-Driven FastAPI + Live Terminal Dashboard App (`omnistream-app`)**: Produces and consumes Kafka events, writes/reads PostgreSQL, MongoDB, and Redis, and exposes `/metrics` for Prometheus scraping.
   - **GitLab CI (`.gitlab-ci.yml`)**: Rootless Buildah image build -> **Trivy** vulnerability scan -> **Docker Hub** push -> GitOps Helm `values.yaml` tag bump -> automatic **ArgoCD** sync.

---

## 2. Directory Structure

```text
Projects/devops-capstone-project-4/
├── README.md                                 # Step-by-step master guide with architecture explanations
├── .gitlab-ci.yml                            # 4-stage DevSecOps pipeline (Buildah -> Trivy -> DockerHub -> GitOps)
├── terraform/
│   ├── versions.tf                           # Terraform & provider version constraints
│   ├── variables.tf                          # Parameterized inputs with validation & descriptions
│   ├── network.tf                            # VNet, Subnet, NAT Gateway (Outbound IP), NSG & Security Rules
│   ├── compute.tf                            # 1 Master (B2s_v2) + 4 Workers (B1ms) via for_each
│   ├── outputs.tf                            # Dynamic Ansible inventory generation + URLs
│   └── templates/
│       └── hosts.ini.tftpl                   # Terraform template for Ansible inventory with ProxyCommand
├── ansible/
│   ├── ansible.cfg                           # Pipelining, SSH multiplexing, host key config
│   ├── site.yml                              # Master playbook orchestrating all phases
│   └── playbooks/
│       ├── 01-os-hardening.yml               # Swap off, kernel modules, sysctl (inotify, vm.max_map_count for Kafka)
│       ├── 02-rke2-master.yml                # RKE2 Server, Ingress Webhook wait, Helm, Local-Path CSI + Toleration patch
│       ├── 03-rke2-workers.yml               # Join token slurp & 4 worker RKE2 Agent bootstrap
│       ├── 04-node-isolation.yml             # Node labels & Taints for 5-node workload isolation
│       └── 05-platform-services.yml          # Cert-Manager, Rancher UI, ArgoCD, Prometheus+Grafana, Kafka+DBs, App
├── helm-values/
│   ├── rancher-values.yaml                   # Pinned to vm-master (8GB RAM)
│   ├── argocd-values.yaml                    # Pinned to vm-master + Ingress enabled
│   ├── monitoring-values.yaml                # kube-prometheus-stack tuned for 8GB master + Grafana Ingress
│   ├── kafka-values.yaml                     # Bitnami Kafka KRaft mode, JVM heap 400m, pinned to vm-worker-stream
│   ├── redis-values.yaml                     # Bitnami Redis standalone, pinned to vm-worker-stream
│   ├── postgres-values.yaml                  # Bitnami PostgreSQL 16, pinned to vm-worker-sql
│   ├── mongo-values.yaml                     # Bitnami MongoDB 7, pinned to vm-worker-nosql
│   └── gitlab-runner-values.yaml             # Kubernetes executor runner pinned to vm-worker-app
├── gitops/
│   └── argocd-application.yaml               # Declarative ArgoCD Application watching omnistream-chart
└── app/
    ├── Dockerfile                            # Production multi-stage / non-root Python FastAPI image
    ├── requirements.txt                      # fastapi, uvicorn, confluent-kafka/kafka-python, psycopg2-binary, pymongo, redis, prometheus-client
    ├── app.py                                # Live Kafka Producer/Consumer + PG + Mongo + Redis + Prometheus /metrics + Terminal UI
    └── omnistream-chart/                     # Helm Chart deployed by ArgoCD
        ├── Chart.yaml
        ├── values.yaml
        └── templates/
            ├── deployment.yaml
            ├── service.yaml
            ├── ingress.yaml
            └── servicemonitor.yaml
```

---

## 3. Resource & Node Allocation Matrix (Zero OOM / Zero CPU Starvation)

| Node | Azure SKU | vCPU / RAM | Public IP | Labels | Taints | Workloads |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `vm-master` | `Standard_B2s_v2` | 2 vCPU / 8 GB | PIP #1 | `node-role.kubernetes.io/control-plane=true` | `CriticalAddonsOnly=true:NoSchedule` | RKE2 Control Plane, Rancher UI, ArgoCD, Prometheus, Grafana |
| `vm-worker-stream` | `Standard_B1ms` | 1 vCPU / 2 GB | Via NAT GW (PIP #3) | `tier=stream` | `dedicated=stream:NoSchedule` | Apache Kafka (KRaft, `cpu: 100m`, `mem: 512Mi`) + Redis (`cpu: 50m`, `mem: 128Mi`) |
| `vm-worker-sql` | `Standard_B1ms` | 1 vCPU / 2 GB | Via NAT GW (PIP #3) | `tier=db-sql` | `dedicated=db-sql:NoSchedule` | PostgreSQL 16 (`cpu: 100m`, `mem: 256Mi`) |
| `vm-worker-nosql` | `Standard_B1ms` | 1 vCPU / 2 GB | Via NAT GW (PIP #3) | `tier=db-nosql` | `dedicated=db-nosql:NoSchedule` | MongoDB 7 (`cpu: 100m`, `mem: 256Mi`) |
| `vm-worker-app` | `Standard_B1ms` | 1 vCPU / 2 GB | PIP #2 | `tier=app` | *None* | `omnistream-app` (`cpu: 100m`, `mem: 128Mi`), GitLab Runner |
