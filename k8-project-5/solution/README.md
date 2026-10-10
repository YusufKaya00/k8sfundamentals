# Enterprise GitOps, Progressive Delivery & Automated Rollback — Çözüm Kılavuzu

Bu çözüm kılavuzu; **Oracle Cloud Infrastructure (OCI) Container Engine for Kubernetes (OKE)** üzerinde çalışan 3 worker node'lu kümede (v1.37.0) **ArgoCD, GitOps Self-Healing, Helm Entegrasyonu, Argo Rollouts (Canary) ve Prometheus Tabanlı Otomatik Geri Alma (Automated Rollback)** süreçlerini uçtan uca uygulamak için hazırlanmıştır.

---

## Dizin Dosyaları ve Görevleri

| Dosya | Görevi / Açıklaması |
|---|---|
| `01-argocd-values.yaml` | OKE 3-node ve trial kaynak sınırlarına göre optimize edilmiş, tek replikalı hafifletilmiş ArgoCD Helm konfigürasyonu. |
| `03-guestbook-gitops-app.yaml` | `production` namespace'ine bağlanan, `selfHeal: true` ve `prune: true` direktifli ilk deklaratif ArgoCD Application nesnesi. |
| `05-helm-kustomize-app.yaml` | Dış kaynaklı bir Helm chart'ını fork'lamadan, ArgoCD üzerinde değerler ve güvenlik yamalarıyla çalıştıran deklaratif Helm Application. |
| `06-rollouts-values.yaml` | OKE kümesi için optimize edilmiş Argo Rollouts Controller ve görsel Rollouts Dashboard Helm konfigürasyonu. |
| `07-payment-rollout.yaml` | Stable ve Canary Servis ikilisi ile ilk kararlı mavi sürümü (`rollouts-demo:blue`) dağıtan Rollout nesnesi. |
| `08-analysis-template.yaml` | Prometheus SLO metriklerini (HTTP başarı oranı $\ge$ %95) ve web sağlık testini denetleyen `AnalysisTemplate`. |
| `09-v2-success-rollout.yaml` | Metrik analizini geçen, aşamalı (%25 -> %50 -> %100) başarılı yeşil sürüm (`rollouts-demo:green`) yükseltmesi. |
| `10-v3-failure-rollout.yaml` | Kasıtlı olarak %80 hata üreten kırmızı sürüm (`rollouts-demo:bad-red`) ve sistemin otomatik geri çekilme kanıtı. |

---

## Adım Adım Kurulum ve Doğrulama

### Adım 1: ArgoCD Helm Kurulumu ve Kaynak Optimizasyonu

ArgoCD'nin resmi topluluk reposunu ekleyin ve `01-argocd-values.yaml` ile hafifletilmiş olarak kurun:

```bash
# 1. ArgoCD Helm reposunu ekleyin
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# 2. argocd namespace'ini olusturun
kubectl create namespace argocd

# 3. Hafifletilmis values ile kurulumu yapin
helm install argocd argo/argo-cd \
  --namespace argocd \
  -f solution/01-argocd-values.yaml

# 4. Pod'larin calistigini dogrulayin
kubectl get pods -n argocd -o wide
```

> **Mimari Not:** Varsayılan ArgoCD kurulumunda Dex, Notifications ve Redis HA (Sentinel) gibi birçok bileşen ayağa kalkar. `01-argocd-values.yaml` ile bu bileşenler kapatılarak bellek ayak izi 300MB civarına çekilmiştir.

---

### Adım 2: ArgoCD Güvenli Erişim ve Giriş Doğrulaması

1. İlk admin parolasını secret içerisinden çekin:
   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
   ```
2. ArgoCD Web arayüzünü yerel makinenize port-forward edin:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
3. Tarayıcıdan `https://localhost:8080` adresine gidin:
   * **Kullanıcı Adı:** `admin`
   * **Şifre:** Yukarıdaki komutla elde ettiğiniz parola.

---

### Adım 3: İlk Deklaratif GitOps Uygulaması

ArgoCD arayüzünden butonlara tıklamak (*ClickOps*) yerine, GitOps felsefesine uygun olarak deklaratif bir `Application` CRD'si uygulayın:

```bash
kubectl apply -f solution/03-guestbook-gitops-app.yaml
```

ArgoCD senkronizasyonunu kontrol edin:
```bash
# Uygulama durumunu izleyin
kubectl get application guestbook-service -n argocd

# Production namespace'inde acilan pod ve servisi kontrol edin
kubectl get pods,svc -n production
```

---

### Adım 4: Sürüklenme Tespiti ve Otomatik İyileştirme Testi (Self-Healing)

GitOps'un en büyük gücü, terminalden yapılan kazara veya kötü niyetli değişiklikleri anında ezerek Git durumuna geri döndürmesidir.

```bash
# 1. Bir muhendisin terminalden pod sayisini elle 5'e cikardigini varsayin:
kubectl scale deployment guestbook-ui -n production --replicas=5

# 2. Pod sayisini izleyin:
kubectl get pods -n production -l app=guestbook-ui

# 3. ArgoCD'nin durumu nasil aninda algilayip pod sayisini tekrar 1'e indirdigini gozlemleyin:
kubectl get events -n production --sort-by='.metadata.creationTimestamp' | tail -n 10
```
> **SRE Çıkarımı:** `selfHeal: true` kuralı sayesinde kümedeki durum asla Git'ten sapamaz.

---

### Adım 5: Upstream Helm Chart ve Declarative GitOps

Dış kaynaklı resmi bir Helm chart'ını (örneğin Stefan Prodan'ın `podinfo` mikroservisini) ArgoCD üzerinden beyana dayalı olarak kurun:

```bash
kubectl apply -f solution/05-helm-kustomize-app.yaml

# ArgoCD uzerinde uygulamanin sync oldugunu dogrulayin
kubectl get application secured-helm-app -n argocd
kubectl get pods -n production -l app.kubernetes.io/name=podinfo
```

---

### Adım 6: Argo Rollouts Controller ve Dashboard Kurulumu

Canary dağıtımlarını ve otomatik geri alma motorunu yönetecek olan Argo Rollouts'u kurun:

```bash
# 1. Argo Rollouts reposu
helm install argo-rollouts argo/argo-rollouts \
  --namespace argo-rollouts \
  --create-namespace \
  -f solution/06-rollouts-values.yaml

# 2. Controller pod'unu dogrulayin
kubectl get pods -n argo-rollouts

# 3. Rollouts Dashboard'u yerel makineye acin:
kubectl port-forward svc/argo-rollouts-dashboard -n argo-rollouts 3100:3100
```
Tarayıcıdan `http://localhost:3100` adresini açarak görsel dağıtım panelini izlemeye hazır hale getirin.

---

### Adım 7: Standart Deployment'tan Rollout Mimarisine Geçiş

Canlı kullanıcı trafiğini karşılayan `payment-service-stable` ve canary testi için ayrılan `payment-service-canary` servisleri ile başlangıç mavi sürümünü (`rollouts-demo:blue`) dağıtın:

```bash
kubectl apply -f solution/07-payment-rollout.yaml

# Rollout durumunu izleyin
kubectl get rollout payment-service -n production

# Argo Rollouts CLI veya port-forward ile mavi rengi gorun
kubectl port-forward svc/payment-service-stable -n production 8081:80
```
Tarayıcıda `http://localhost:8081` adresinde mavi kutucukların aktığını doğrulayın.

---

### Adım 8: Prometheus Analiz Şablonu Tasarımı (`AnalysisTemplate`)

Canary sürümün sağlığını yalnızca pod'un ayağa kalkmasıyla değil, dönen HTTP 5xx oranına bakarak doğrulayacak şablonu uygulayın:

```bash
kubectl apply -f solution/08-analysis-template.yaml

kubectl get analysistemplate -n production
```

---

### Adım 9: Başarılı Canary Dağıtımı (Happy Path Rollout)

Sağlıklı v2 (Green) sürümünü devreye alın:

```bash
kubectl apply -f solution/09-v2-success-rollout.yaml

# Canli canary adimlarini terminalden izleyin:
kubectl argo rollouts get rollout payment-service -n production --watch
```

**Gözlemlenecek Adımlar:**
1. Podların %25'i (1 pod) yeşil sürüme geçer.
2. `payment-success-rate` analizi çalışır ve başarıyla geçer.
3. Trafik %50'ye çıkar.
4. İkinci analiz adımından sonra %100'e ulaşır ve eski mavi podlar kapatılır.

---

### Adım 10: Hata Simülasyonu ve Otomatik Geri Alma (Automated Rollback)

Şimdi üretim felaketi simülasyonu yapıyoruz: Kasıtlı olarak %80 oranında HTTP 500 hatası üreten `bad-red` sürümünü deploy ediyoruz:

```bash
kubectl apply -f solution/10-v3-failure-rollout.yaml

# Rollout durumunu canlı izleyin:
kubectl argo rollouts get rollout payment-service -n production --watch
```

**Gözlemlenecek SRE Mucizesi:**
1. Sistem trafiğin %25'ini kırmızı pod'a verir.
2. `AnalysisTemplate` Prometheus / Web üzerinden hata oranının tavan yaptığını yakalar.
3. Analiz **FAIL** durumuna düşer.
4. Argo Rollouts anında dağıtımı **ABORTED** eder.
5. Kırmızı pod derhal kapatılır ve canlı trafik anında kararlı yeşil pod'lara (v2) geri aktarılır.
6. Hiçbir mühendis müdahale etmeden **Zero-Touch Automated Rollback** gerçekleşmiş olur!

---

## Doğrulama ve Temizlik

Tüm testleri tamamladıktan sonra laboratuvar ortamını temizlemek için:

```bash
kubectl delete -f solution/10-v3-failure-rollout.yaml
kubectl delete -f solution/08-analysis-template.yaml
kubectl delete -f solution/05-helm-kustomize-app.yaml
kubectl delete -f solution/03-guestbook-gitops-app.yaml
helm uninstall argo-rollouts -n argo-rollouts
helm uninstall argocd -n argocd
kubectl delete ns argocd argo-rollouts
```
