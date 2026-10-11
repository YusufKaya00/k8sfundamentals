# Kubernetes-Native CI/CD & DevSecOps Platform (GitLab Runner, Rootless Buildah & Trivy)

Bu laboratuvar; klasik statik CI sunucularından bulut-yerel mimariye geçişi, **Kubernetes üzerinde dinamik ölçeklenen GitLab Runner mimarisini**, unprivileged container içinde güvenli imaj derlemeyi (**Rootless Buildah**), **Trivy ile otomatik güvenlik kapısı (Vulnerability Gating) ve SBOM üretimini** ve tüm bu sürecin **Lab 5'teki ArgoCD GitOps motoruna bağlanarak** uçtan uca kurumsal bir "Commit-to-Production" hattına dönüşmesini simüle eder.

> 📖 **Adım adım komutlar, mimari gerekçeler ve çözümler için:**  
> 👉 **[Çözüm Kılavuzunu İnceleyin (solution/README.md)](./solution/README.md)**

---

## Altyapı ve Kaynak Kısıtları

* **3 Worker Node Mimarisi:**
  * 1 x DB Node (`workload=database:NoSchedule`, `tier=database`)
  * 2 x Web/Worker Node (`tier=web`)
* **Oracle Linux 9 / OKE Uyumu:** Tüm imaj referanslarında tam FQDN (`docker.io/...`, `quay.io/...`) kullanılmalıdır.
* **Trial/Kota Tasarrufu:** GitLab Runner Manager pod'u hafifletilmiş kaynak limitleri ile çalışmalı, her CI işi için açılan geçici (ephemeral) pod'ların CPU/Bellek limitleri `01-gitlab-runner-values.yaml` üzerinden sınırlandırılmalıdır.

---

## Laboratuvar Müfredatı (10 Adım)

### Faz 1: Dinamik CI/CD Altyapısı (Kubernetes Executor)

* **Adım 1: En Az Yetki Prensibi (Least-Privilege RBAC) Tanımlaması**  
  Runner yöneticisinin küme genelinde yetki sahibi olmasını engellemek için yalnızca `gitlab-runner` namespace'i içinde pod ve secret yönetebilen izole bir `ServiceAccount`, `Role` ve `RoleBinding` oluşturun (`03-runner-rbac-and-namespace.yaml`).

* **Adım 2: GitLab Runner Helm Kurulumu (Kubernetes Executor)**  
  `gitlab/gitlab-runner` Helm chart'ını OKE 3-node kümesine uygun biçimde hafifletilmiş `values` ile kurun. Pod'ların `tier=web` node'larına yerleşmesini ve `privileged: false` kuralını güvenceye alın (`01-gitlab-runner-values.yaml`).

* **Adım 3: Dinamik Pod Yaşam Döngüsünün Doğrulanması**  
  GitLab üzerinde bir test işi tetikleyerek `gitlab-runner` namespace'inde anlık olarak bir build podunun açıldığını, işi bitirip silindiğini terminalden canlı izleyin (`kubectl get pods -n gitlab-runner -w`).

---

### Faz 2: Konteyner İçi Güvenli İmaj Derleme (Rootless Build)

* **Adım 4: Güvenli İmaj Derleme Mimarisi (Neden DinD Terk Edildi?)**  
  `docker.sock` bağlamanın getirdiği kernel erişim risklerini ve Kaniko'nun Haziran 2025'te neden arşivlendiğini kavrayın; unprivileged pod standartlarını inceleyin.

* **Adım 5: Rootless Buildah ile OCI İmajı Derleme ve Push**  
  Pod Security Standards Restricted seviyesine tam uyumlu olarak, unprivileged bir pod içinde `Buildah` kullanarak uygulamanın Dockerfile'ını derleyin ve container registry'ye yükleyin (`05-buildah-build.gitlab-ci.yml`).

---

### Faz 3: DevSecOps Güvenlik Kapısı ve Tedarik Zinciri

* **Adım 6: Trivy ile Otomatik Zafiyet Taraması ve Güvenlik Kapısı (Gating)**  
  Derlenen imajı tarayan ve düzeltilmemiş **CRITICAL (Kritik)** seviyede güvenlik açığı bulunması durumunda `exit code 1` vererek dağıtımı derhal durduran bir Trivy denetimi yapılandırın (`06-trivy-scan.gitlab-ci.yml`).

* **Adım 7: CycloneDX Formatında SBOM Üretimi**  
  Modern yazılım tedarik zinciri standartlarına uygun olarak, uygulamanın içerdiği tüm açık kaynak kütüphanelerin dökümünü içeren bir **Yazılım Malzeme Listesi (SBOM - Software Bill of Materials)** üretin ve CI artifact'ı olarak saklayın.

---

### Faz 4: Uçtan Uca Entegrasyon (CI'dan GitOps'a Köprü)

* **Adım 8: CI'dan GitOps'a Otomatik Köprü (ArgoCD Promotion)**  
  Tüm güvenlik ve test adımlarından başarıyla geçen yeni imaj etiketini (`$CI_COMMIT_SHA`), Lab 5'te kurduğumuz GitOps deposuna otomatik commit ederek ArgoCD'nin canlı dağıtımını tetikleyin (`08-gitops-bridge.gitlab-ci.yml`).

* **Adım 9: Uçtan Uca "Commit-to-Production" Canlı Testi**  
  Geliştiricinin kod değişikliği yapmasından başlayıp; K8s içinde pod açılması, imajın derlenmesi, güvenlik taramasından geçmesi ve ArgoCD ile Canary Rollout olarak canlıya alınması döngüsünü uçtan uca doğrulayın (`09-complete-pipeline.gitlab-ci.yml`).

* **Adım 10: Hatalı Kod Simülasyonu (Security Gate Failure)**  
  Kasıtlı olarak kritik güvenlik açığı (CRITICAL CVE) barındıran eski bir imajı taratarak Trivy'nin pipeline'ı nasıl kırdığını ve zafiyetli kodun Kubernetes kümesine girmesini nasıl engellediğini kanıtlayın (`10-vulnerable-simulation.gitlab-ci.yml`).

---

## Dizin Yapısı

```text
k8-project-6/
├── README.md                                  # Laboratuvar müfredatı ve görev hedefleri (bu dosya)
└── solution/
    ├── README.md                              # Detaylı adım adım çözümlü rehber ve çıktılar
    ├── 01-gitlab-runner-values.yaml           # OKE Kubernetes Executor Runner Helm değerleri
    ├── 02-gitlab-agent-values.yaml            # Güvenli gRPC tüneli için GitLab Agentk Helm değerleri
    ├── 03-runner-rbac-and-namespace.yaml      # En az yetki prensipli Runner RBAC manifesti
    ├── 05-buildah-build.gitlab-ci.yml         # Rootless Buildah imaj derleme CI görevi
    ├── 06-trivy-scan.gitlab-ci.yml            # Trivy güvenlik kapısı ve CycloneDX SBOM görevi
    ├── 08-gitops-bridge.gitlab-ci.yml         # ArgoCD GitOps reposuna otomatik commit köprüsü
    ├── 09-complete-pipeline.gitlab-ci.yml     # Uçtan uca kurumsal DevSecOps .gitlab-ci.yml hattı
    └── 10-vulnerable-simulation.gitlab-ci.yml # Güvenlik kapısının durdurma gücünü kanıtlayan test
```
