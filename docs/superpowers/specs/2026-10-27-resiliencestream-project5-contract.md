# Proje 5 — ResilienceStream: Ortak Sözleşme (Tüm alt ajanlar buna uyar)

Kök dizin: `/home/ysf/k8sfundamentals/Projects/devops-capstone-project-5/`
Referans (çalışan, düzeltilmiş): `/home/ysf/k8sfundamentals/Projects/devops-capstone-project-4/`
Dil: tüm yorumlar ve dokümanlar **Türkçe**, öğretici, "neden prod'da böyle" açıklamalı.

## Kararlar (onaylı varsayılanlar)
- Seçenek A: 3 sunucu, toplam 6 vCPU, Azure `denmarkeast`, RG `rg-resiliencestream-5`, VNet `10.30.0.0/16`, subnet `10.30.1.0/24`.
  - `vm-master`  B2s_v2 (2 vCPU/8 GB)  10.30.1.4  Public IP #1  taint `CriticalAddonsOnly=true:NoSchedule`, label `tier=platform`
  - `vm-worker-data` B2s (2 vCPU/4 GB) 10.30.1.5  özel (NAT GW, Public IP #3)  taint `dedicated=data:NoSchedule`, label `tier=data`
  - `vm-worker-app`  B2s (2 vCPU/4 GB) 10.30.1.6  Public IP #2, taint yok, label `tier=app`
- MongoDB yok → **Cassandra** (tek node, `MAX_HEAP_SIZE=768M`, `HEAP_NEWSIZE=128M`).
- Uygulama FastAPI (Python 3.11).
- Admin şifresi: `AdminPassword2026!`; SSH user `ysf`, key `~/.ssh/id_rsa.pub`.
- Domainler: `rancher.<MASTER_IP>.nip.io`, `argocd.<MASTER_IP>.nip.io`, `grafana.<MASTER_IP>.nip.io`, `chaos.<MASTER_IP>.nip.io`, `app.<APP_IP>.nip.io`, `rabbitmq.<APP_IP>.nip.io`.

## Namespace'ler
`data` (kafka, cassandra, postgres) · `messaging` (rabbitmq, redis) · `app` · `monitoring` · `argocd` · `cattle-system` · `chaos-mesh` · `gitlab-runner`

## Servis DNS adları (uygulama env değişkenleri bunlara bağlanır)
| Bileşen | Helm release / chart | Servis | Port | Node |
|---|---|---|---|---|
| Kafka KRaft | `kafka` / bitnami/kafka (image `bitnamilegacy/kafka`) | `kafka.data.svc.cluster.local` | 9092 | data |
| Cassandra | `cassandra` / bitnami/cassandra (image `bitnamilegacy/cassandra`) | `cassandra.data.svc.cluster.local` | 9042 | data |
| PostgreSQL | `postgres` / bitnami/postgresql (`bitnamilegacy/postgresql`) | `postgres-postgresql.data.svc.cluster.local` | 5432 | data |
| RabbitMQ | `rabbitmq` / bitnami/rabbitmq (`bitnamilegacy/rabbitmq`) | `rabbitmq.messaging.svc.cluster.local` | 5672 (mgmt 15672) | app |
| Redis | `redis` / bitnami/redis (`bitnamilegacy/redis`) | `redis-master.messaging.svc.cluster.local` | 6379 | app |
Tüm Bitnami chart'larda: `global.security.allowInsecureImages: true`, `resourcesPreset: "none"`, açık requests/limits, auth şifresi `AdminPassword2026!`, kullanıcı `resilience` (pg/rabbit/cassandra), DB/keyspace `resilience`.

## Uygulama bileşenleri (namespace `app`, image `yusufk00/<isim>:<tag>`)
- `order-api` (FastAPI, port 8000, 2 replica): `POST /api/orders` → Postgres'e sipariş yazar, Kafka `orders.events` topic'ine event, RabbitMQ `payments` kuyruğuna task basar, Redis'te cache. `GET /`, `/healthz` (liveness, sadece process), `/readyz` (readiness, kritik bağımlılık Postgres), `/metrics`.
- `analytics-consumer`: Kafka `orders.events` → Cassandra `resilience.order_events`.
- `payment-worker`: RabbitMQ `payments` → Postgres `payments` tablosu; hatada 3 retry → DLQ `payments.dlq`.
- Tek repo, tek image: `yusufk00/resiliencestream` ; `APP_ROLE` env = `api|analytics|payment`.

## Metrik adları (Prometheus, prefix `rs_`)
- `rs_http_requests_total{method,endpoint,status}` (Counter)
- `rs_http_request_duration_seconds{endpoint}` (Histogram)
- `rs_dependency_up{dependency}` (Gauge; kafka|rabbitmq|cassandra|postgres|redis) — **arka plan thread'i her 5 sn günceller**
- `rs_dependency_latency_seconds{dependency}` (Histogram)
- `rs_circuit_breaker_state{dependency}` (0=closed,1=half-open,2=open)
- `rs_orders_created_total{result}`
- `rs_kafka_events_consumed_total`, `rs_kafka_consumer_lag`
- `rs_rabbitmq_messages_processed_total{result}` (success|retry|dlq)
- ServiceMonitor label: `release: monitoring`, interval 5s.

## Proje 4 dersleri (baştan dahil edilecek)
1. Master CPU bütçesi: platform pod CPU requests 10–25m.
2. `bitnamilegacy/*` imajları + `allowInsecureImages`.
3. Ingress NGINX admission webhook hazır olana kadar bekle.
4. local-path-provisioner helper-pod tüm taint'leri tolere etsin.
5. Grafana: limits 800m/1Gi, requests 50m/256Mi; datasource `timeInterval: 5s`; Prometheus `scrapeInterval/evaluationInterval: 5s`; dashboard'lar Helm `dashboardProviders` + `dashboards` ile (sidecar'a dashboard ConfigMap yığma YOK, `sidecar.dashboards.enabled: false`).
6. Health metriği scrape anında değil, arka plan thread'iyle güncellenir.
7. ArgoCD Application Ingress host'u küçük harf/geçerli olmalı (placeholder değil).
8. `.gitlab-ci.yml`: script satırlarında `: ` içeren komutlar tırnaklı/`- |` blok; `[skip ci]` sadece bot commit'inde; gitops_promote GitLab + GitHub'a (`GITHUB_ACCESS_TOKEN`) pushlar; `GITLAB_ACCESS_TOKEN:-$GIT_PUSH_TOKEN`.
9. GitLab Runner job pod requests küçük (100m), `concurrent = 1` (CPU sıkışmasın).
10. Chaos Mesh RKE2'de: `chaosDaemon.runtime=containerd`, `chaosDaemon.socketPath=/run/k3s/containerd/containerd.sock`.
