# 🚀 Lab 5: Enterprise GitOps, Progressive Delivery & Automated Rollbacks (ArgoCD & Argo Rollouts)

This lab guides you through the transition from manual YAML deployments (*ClickOps*) to modern **GitOps** workflows, covering **ArgoCD Self-Healing Drift Remediation**, **Declarative Helm Chart Orchestration (Zero-Fork Strategy)**, and **Progressive Delivery with Argo Rollouts and Prometheus Metric-Based Automated Rollbacks**.

> **Solutions / Çözümler:** For step-by-step commands, architectural rationale, and outputs:  
> **👉 [Explore Solution Guide (solution/README.md)](./solution/README.md)**

---

## 📋 Infrastructure & Environment Constraints

- **3 Worker Node Topology:**
  - 1 x Dedicated Database Node (`workload=database:NoSchedule`, `tier=database`)
  - 2 x Web / Worker Nodes (`tier=web`)
- **Enterprise Container Runtimes (Oracle Linux 9 / OCI OKE):** All images specify fully qualified domain names (`docker.io/...`, `quay.io/...`).
- **Resource Footprint Optimization:** ArgoCD and Argo Rollouts controllers are tuned with minimal resource configurations (disabling heavy Dex and notification sidecars) to operate seamlessly within quota boundaries.

---

## 📋 Curriculum Steps (10 Steps)

### Phase 1: GitOps Core & ArgoCD Architecture

* **Step 1: Resource-Optimized ArgoCD Deployment via Helm**  
  Deploy the official `argo/argo-cd` chart to the `argocd` namespace using `solution/01-argocd-values.yaml`. Ensure Redis runs in standalone single-replica mode, disable unused Dex/notification daemons, and schedule controllers strictly on `tier=web` worker nodes.

* **Step 2: Secure ArgoCD Authentication & Access Verification**  
  Extract the initial admin secret (`argocd-initial-admin-secret`), forward port `8080:443`, and authenticate into the ArgoCD Web UI.

* **Step 3: Declarative GitOps Application (`Application` CRD)**  
  Rather than using ClickOps, define a declarative `Application` resource binding a microservice (e.g., `guestbook`) to the `production` namespace with `automated.prune` and `automated.selfHeal` enabled.

* **Step 4: Configuration Drift Detection & Self-Healing Remediation**  
  SRE Scenario: Simulate an unauthorized manual drift via `kubectl scale --replicas=5`. Observe how ArgoCD detects the divergence and automatically rolls back the replica count to match Git within seconds.

---

### Phase 2: Declarative Helm Orchestration

* **Step 5: Upstream Helm Management with Zero-Fork Strategy**  
  Deploy an external upstream Helm chart (e.g., `podinfo`) declaratively via ArgoCD with custom parameter values and security policies, eliminating the need to fork or mirror the source chart repository.

---

### Phase 3: Progressive Delivery with Argo Rollouts

* **Step 6: Argo Rollouts Controller & Live Visual Dashboard**  
  Install `argo/argo-rollouts` via Helm. Enable the built-in web dashboard on port 3100 to visualize real-time canary traffic steps and pod states.

* **Step 7: Migration from Deployment to Rollout Primitive**  
  Transition from `kind: Deployment` to `kind: Rollout`. Attach dedicated `payment-service-stable` and `payment-service-canary` Services, and launch the stable blue baseline (`rollouts-demo:blue`) with 4 replicas.

---

### Phase 4: Metric Analysis & Automated Rollback

* **Step 8: Prometheus SLO AnalysisTemplate Design**  
  Construct an `AnalysisTemplate` querying Prometheus HTTP metrics. Enforce an error rate ceiling (requiring $\ge 95\%$ success rate) as an automated gate between canary promotion phases.

* **Step 9: Successful Canary Rollout (Happy Path)**  
  Promote healthy v2 green version (`rollouts-demo:green`). Monitor automated progression: 25% traffic -> Analysis -> 50% traffic -> Analysis -> 100% full promotion with zero downtime.

* **Step 10: Synthetic Failure Injection & Zero-Touch Automated Rollback**  
  Production disaster test: Deploy a faulty v3 build (`rollouts-demo:bad-red`) intentionally emitting 80% HTTP 500 errors. Watch the `AnalysisTemplate` fail, aborting the rollout and instantly reverting traffic back to the healthy v2 pods without human intervention (*Zero-Touch Automated Rollback*).

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# Enterprise GitOps, Progressive Delivery & Automated Rollbacks (ArgoCD & Argo Rollouts)

Bu laboratuvar; ham YAML yazımı ve manuel CLI işlemlerinden modern **GitOps** felsefesine geçişi, **ArgoCD ile sürüklenme engelleme (Self-Healing)**, **Helm chart'larının GitOps ile orkestrasyonu** ve **Argo Rollouts ile Prometheus metrik tabanlı otomatik geri alma (Automated Rollback)** süreçlerini uçtan uca simüle eder.

> 📖 **Adım adım komutlar, mimari gerekçeler ve çözümler için:**  
> 👉 **[Çözüm Kılavuzunu İnceleyin (solution/README.md)](./solution/README.md)**

---

## Altyapı ve Kaynak Kısıtları

* **3 Worker Node Mimarisi:**
  * 1 x DB Node (`workload=database:NoSchedule`, `tier=database`)
  * 2 x Web/Worker Node (`tier=web`)
* **Oracle Linux 9 / OKE Uyumu:** Tüm imaj referanslarında tam FQDN (`docker.io/...`, `quay.io/...`) kullanılmalıdır.
* **Trial/Kota Tasarrufu:** ArgoCD ve Argo Rollouts controller'ları hafifletilmiş kaynak limitleri ile (gereksiz ağır Dex ve bildirim servisleri kapatılarak) çalıştırılmalıdır.

---

## Laboratuvar Müfredatı (10 Adım)

### Faz 1: GitOps Çekirdeği ve ArgoCD Mimarisi

* **Adım 1: ArgoCD Kurulumu ve Kaynak Optimizasyonu (Helm ile Kurulum)**  
  `argo/argo-cd` resmi Helm chart'ını OKE 3-node kümesine uygun biçimde hafifletilmiş `values` ile `argocd` namespace'ine kurun. Redis'in tek replika çalıştığından, Dex ve ağır bildirim modüllerinin kapalı olduğundan ve pod'ların yalnızca `tier=web` node'larına yerleştiğinden emin olun.

* **Adım 2: ArgoCD Güvenli Erişim ve Giriş Doğrulaması**  
  ArgoCD `initial-admin-secret` nesnesinden şifreyi çözün, Web arayüzünü port-forward ile yerel tarayıcınıza açın ve admin girişi yapın.

* **Adım 3: İlk Deklaratif GitOps Uygulaması (`Application` CRD)**  
  Tıklayarak (*ClickOps*) uygulama oluşturmak yerine, Git reposundaki bir mikroservisi (örn: `guestbook`) `production` namespace'ine bağlayan beyana dayalı bir `Application` nesnesi tanımlayın. `automated.prune` ve `automated.selfHeal` ayarlarını aktif edin.

* **Adım 4: Sürüklenme Tespiti ve Otomatik İyileştirme Testi (Drift Remediation)**  
  SRE senaryosu: Bir mühendisin acil müdahale amacıyla terminalden `kubectl scale` ile pod sayısını elle artırdığını simüle edin. ArgoCD'nin bu sapmayı algılayıp sistemi saniyeler içinde Git'teki orijinal haline nasıl döndürdüğünü gözlemleyin.

---

### Faz 2: Paket Yönetimi ve Deklaratif Helm Orkestrasyonu

* **Adım 5: Upstream Helm Chart'ını GitOps ile Yönetme (Zero-Fork Stratejisi)**  
  Dış kaynaklı resmi bir Helm chart'ını (örn: `podinfo`), chart dosyalarını forklayıp değiştirmeden doğrudan ArgoCD üzerinden `values` değerleriyle beyana dayalı olarak deploy edin.

---

### Faz 3: Kör Dağıtımdan İlerici Dağıtıma Geçiş (Progressive Delivery)

* **Adım 6: Argo Rollouts Controller ve Görsel Dashboard Kurulumu**  
  Canary dağıtımlarını yönetecek olan `argo/argo-rollouts` Helm chart'ını kurun. Dağıtım aşamalarını canlı kutucuklarla izlemek için dahili Rollouts Dashboard'unu aktif edin.

* **Adım 7: Standart Deployment'tan Rollout Mimarisine Geçiş**  
  Klasik `kind: Deployment` yerine `kind: Rollout` nesnesi tanımlayın. Canlı üretim trafiğini yöneten `payment-service-stable` ve canary testi için ayrılan `payment-service-canary` servislerini bağlayın. Başlangıçta kararlı mavi sürümü (`rollouts-demo:blue`) 4 replika ile devreye alın.

---

### Faz 4: Prometheus Metrik Analizi ve Otomatik Geri Alma (Automated Rollback)

* **Adım 8: Prometheus SLO Metrik Analiz Şablonu Tasarımı (`AnalysisTemplate`)**  
  Canary sürümün sağlığını yalnızca pod'un ayakta kalmasıyla değil; Prometheus üzerinden HTTP 5xx hata oranını sorgulayan bir `AnalysisTemplate` oluşturun. Başarı kriteri olarak en az %95 başarı oranını şart koşun.

* **Adım 9: Başarılı Canary Dağıtımı ve Kademeli Trafik Geçişi (Happy Path)**  
  Uygulamanın sağlıklı v2 yeşil sürümünü (`rollouts-demo:green`) deploy edin. Trafiğin %25 -> Analiz -> %50 -> Analiz -> %100 şeklinde sıfır kesintiyle yükseldiğini gözlemleyin.

* **Adım 10: Sentetik Hata Simülasyonu ve Otomatik Geri Alma (Chaos / Bad Deployment)**  
  Üretim felaketi testi: Kasıtlı olarak %80 oranında HTTP 500 hatası üreten hatalı bir v3 sürümü (`rollouts-demo:bad-red`) deploy edin. `AnalysisTemplate`'in hatayı yakalamasını ve sistemin hiçbir insan müdahalesi olmadan saniyeler içinde dağıtımı iptal edip kararlı sürüme geri çekildiğini (*Zero-Touch Automated Rollback*) kanıtlayın.

---

## Dizin Yapısı

```text
k8-project-5/
├── README.md                                  # Laboratuvar müfredatı ve görev hedefleri (bu dosya)
└── solution/
    ├── README.md                              # Detaylı adım adım çözümlü rehber ve çıktılar
    ├── 01-argocd-values.yaml                  # ArgoCD hafifletilmiş OKE konfigürasyonu
    ├── 03-guestbook-gitops-app.yaml           # Temel GitOps senkronizasyon uygulaması
    ├── 05-helm-kustomize-app.yaml             # Declarative Helm ArgoCD Application
    ├── 06-rollouts-values.yaml                # Argo Rollouts hafifletilmiş OKE değerleri
    ├── 07-payment-rollout.yaml                # Stable/Canary Service ve Rollout manifesti
    ├── 08-analysis-template.yaml              # Prometheus SLO metrik analiz şablonu
    ├── 09-v2-success-rollout.yaml             # Başarılı v2 yeşil sürüm canary manifesti
    └── 10-v3-failure-rollout.yaml             # Sentetik hatalı v3 otomatik geri alma testi
```
