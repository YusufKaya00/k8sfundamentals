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
