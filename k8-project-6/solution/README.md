# 💡 Lab 6 Solutions: Kubernetes-Native DevSecOps Platform (GitLab Runner, Rootless Buildah & Trivy)

This solution guide details the implementation of an enterprise-grade cloud-native DevSecOps platform on a 3-worker node OKE cluster: **GitLab Runner (Kubernetes Executor), Unprivileged Buildah (Rootless OCI compilation), Trivy Vulnerability Gating, CycloneDX SBOM Generation, and GitOps Promotion to ArgoCD**.

---

## 🇬🇧 English Solutions

### Directory Structure & File Roles

| File | Purpose & Architecture |
|---|---|
| `01-gitlab-runner-values.yaml` | Production-tuned GitLab Runner Helm configuration enforcing `privileged: false`, ephemeral resource limits, and web node affinities. |
| `02-gitlab-agent-values.yaml` | GitLab Agent for Kubernetes (`agentk`) Helm values establishing an outbound mTLS gRPC tunnel without requiring inbound firewall openings. |
| `03-runner-rbac-and-namespace.yaml` | Least-privilege RBAC role restricting runner pod lifecycle management exclusively to the `gitlab-runner` namespace. |
| `05-buildah-build.gitlab-ci.yml` | Rootless Buildah task compiling OCI images in an unprivileged container without Docker-in-Docker or host socket mounts. |
| `06-trivy-scan.gitlab-ci.yml` | Security gate scanning compiled images for CRITICAL vulnerabilities (`--exit-code 1`) and exporting CycloneDX SBOMs. |
| `08-gitops-bridge.gitlab-ci.yml` | Automated GitOps promotion bridge updating image tags in the Lab 5 GitOps repository to trigger live canary deployments. |
| `09-complete-pipeline.gitlab-ci.yml` | Unified, end-to-end enterprise CI/CD pipeline combining Test, Build, Scan, SBOM, and Deploy stages. |
| `10-vulnerable-simulation.gitlab-ci.yml` | Controlled chaos simulation verifying that known vulnerable images are blocked from deployment by the security gate. |

---

### Step-by-Step Execution & Verification

#### Step 1: Runner Namespace & Least-Privilege RBAC
```bash
kubectl apply -f solution/03-runner-rbac-and-namespace.yaml

# Verify ServiceAccount and RoleBinding
kubectl get sa,role,rolebinding -n gitlab-runner
```

---

#### Step 2: Deploy GitLab Runner via Helm (Kubernetes Executor)
```bash
# 1. Add GitLab Helm repository
helm repo add gitlab https://charts.gitlab.io
helm repo update

# 2. Install Runner with registration token from GitLab project
# (GitLab UI -> Settings -> CI/CD -> Runners -> New Project Runner)
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  -f solution/01-gitlab-runner-values.yaml \
  --set runnerRegistrationToken="YOUR_RUNNER_TOKEN_HERE" \
  --set gitlabUrl="https://gitlab.com/"

# 3. Verify Runner Manager pod is Running
kubectl get pods -n gitlab-runner -o wide
```

---

#### Step 3: Verify Dynamic Ephemeral Pod Lifecycle
Trigger a pipeline job in GitLab and monitor the `gitlab-runner` namespace in real time:
```bash
kubectl get pods -n gitlab-runner -w
```
*Observe the worker pod spin up (`Pending -> Running`), execute the task, and terminate immediately upon job completion.*

---

#### Step 4: The Security Paradigm (Why DinD & Kaniko Were Deprecated)
- **Docker-in-Docker (DinD):** Mandates `privileged: true`, granting the container root capabilities over the host Linux kernel (severe container breakout risk).
- **Kaniko:** Officially archived and deprecated by Google Container Tools in June 2025.
- **Rootless Buildah:** Compiles images inside unprivileged Linux user namespaces without requiring root daemon permissions.

---

#### Step 5: Rootless OCI Image Builds with Buildah
Add `solution/05-buildah-build.gitlab-ci.yml` to your pipeline. Verify:
- Build pod executes with `securityContext.privileged: false`.
- Image compiles via `buildah bud` and pushes to the container registry.

---

#### Step 6: Automated Vulnerability Scanning & Security Gating
```bash
# Trivy command syntax executed in pipeline:
trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed <IMAGENAME>
```
*Passes cleanly (`exit code 0`) if no unfixed CRITICAL CVEs exist; breaks the pipeline (`exit code 1`) if critical flaws are present.*

---

#### Step 7: CycloneDX SBOM Generation
```bash
trivy image --format cyclonedx --output sbom-cyclonedx.json <IMAGENAME>
```
*The resulting `sbom-cyclonedx.json` is preserved as a downloadable CI pipeline artifact.*

---

#### Step 8: Automated GitOps Promotion Bridge (Lab 5 ArgoCD Integration)
Successful images automatically trigger a commit to the GitOps repository:
```bash
sed -i "s|image: .*|image: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA|g" k8-project-5/solution/07-payment-rollout.yaml
git commit -m "chore(release): promote to $CI_COMMIT_SHA [skip ci]"
git push origin main
```
*ArgoCD detects the Git commit and initiates a Canary Rollout on the Kubernetes cluster!*

---

#### Step 9: End-to-End "Commit-to-Production" Lifecycle
Deploy `solution/09-complete-pipeline.gitlab-ci.yml`. Push a code change to verify:
1. **Test stage:** Unit tests succeed.
2. **Build stage:** Buildah compiles rootless container image.
3. **Security stage:** Trivy validates vulnerabilities and generates SBOM.
4. **Deploy stage:** GitOps repository is updated with new container digest.
5. **OKE Cluster:** `kubectl get rollout -n production -w` confirms ArgoCD canary progression.

---

#### Step 10: Security Gate Failure Simulation
Run `solution/10-vulnerable-simulation.gitlab-ci.yml` against an insecure legacy base image:
- Trivy flags multiple CRITICAL CVEs.
- Trivy returns `exit code 1`, failing the job immediately.
- **Outcome:** The vulnerable container image is strictly prohibited from reaching production.

---

#### Cleanup
```bash
helm uninstall gitlab-runner -n gitlab-runner
kubectl delete -f solution/03-runner-rbac-and-namespace.yaml
```

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# Kubernetes-Native DevSecOps Platform — Çözüm Kılavuzu

Bu çözüm kılavuzu; **Oracle Cloud Infrastructure (OCI) Container Engine for Kubernetes (OKE)** üzerinde çalışan 3 worker node'lu kümede (v1.37.0) **GitLab Runner (Kubernetes Executor), Unprivileged Buildah (Rootless OCI Derleme), Trivy Güvenlik Kapısı (Vulnerability Gating), CycloneDX SBOM Üretimi ve Lab 5 ArgoCD GitOps Köprüsü** süreçlerini uçtan uca uygulamak için hazırlanmıştır.

---

## Dizin Dosyaları ve Görevleri

| Dosya | Görevi / Açıklaması |
|---|---|
| `01-gitlab-runner-values.yaml` | OKE 3-node kümesine özel, dinamik pod kaynak sınırları belirlenmiş, `privileged: false` ayarlı GitLab Runner Helm değerleri. |
| `02-gitlab-agent-values.yaml` | Dışarıya inbound port açmadan, küme içinden GitLab'a şifreli gRPC tüneli kuran `agentk` Helm değerleri. |
| `03-runner-rbac-and-namespace.yaml` | Runner'ın yalnızca `gitlab-runner` namespace'i içinde pod açıp kapatabilmesini sağlayan en az yetki prensipli (Least-Privilege) RBAC manifesti. |
| `05-buildah-build.gitlab-ci.yml` | `docker.sock` bağlamadan, K8s unprivileged pod içinde OCI imajı derleyen Buildah CI konfigürasyonu. |
| `06-trivy-scan.gitlab-ci.yml` | Derlenen imajı tarayan, CycloneDX formatında SBOM üreten ve kritik CVE varsa pipeline'ı durduran (`--exit-code 1`) Trivy güvenlik kapısı. |
| `08-gitops-bridge.gitlab-ci.yml` | Güvenlik testini geçen imaj tag'ini Lab 5'teki GitOps deposuna otomatik commit ederek ArgoCD'yi tetikleyen köprü. |
| `09-complete-pipeline.gitlab-ci.yml` | Test, Buildah, Trivy ve GitOps aşamalarını birleştiren uçtan uca kurumsal `.gitlab-ci.yml` boru hattı. |
| `10-vulnerable-simulation.gitlab-ci.yml` | Kasıtlı olarak zafiyetli bir imaj taratarak güvenlik kapısının pipeline'ı durdurduğunu gösteren simülasyon. |

---

## Adım Adım Kurulum ve Doğrulama

### Adım 1: GitLab Runner Namespace ve RBAC Tanımlaması

Runner podunun cluster-admin yetkisine sahip olması ciddi bir güvenlik açığıdır. Yalnızca kendi namespace'inde pod açıp kapatabileceği bir ServiceAccount ve Role tanımlayın:

```bash
kubectl apply -f solution/03-runner-rbac-and-namespace.yaml

# ServiceAccount ve Rolü doğrulayın
kubectl get sa,role,rolebinding -n gitlab-runner
```

---

### Adım 2: GitLab Runner Helm Kurulumu (Kubernetes Executor)

GitLab resmi Helm reposunu ekleyin ve `01-gitlab-runner-values.yaml` ile OKE kümesine kurun:

```bash
# 1. GitLab Helm reposunu ekleyin
helm repo add gitlab https://charts.gitlab.io
helm repo update

# 2. GitLab projenizden aldığınız Registration Token ile kurulumu yapın:
# (GitLab UI -> Settings -> CI/CD -> Runners -> New Project Runner)
helm install gitlab-runner gitlab/gitlab-runner \
  --namespace gitlab-runner \
  -f solution/01-gitlab-runner-values.yaml \
  --set runnerRegistrationToken="YOUR_RUNNER_TOKEN_HERE" \
  --set gitlabUrl="https://gitlab.com/"

# 3. Runner Manager podunun ayakta olduğunu doğrulayın
kubectl get pods -n gitlab-runner -o wide
```

> **Mimari Not:** Runner Manager podu sürekli olarak sadece 50-100MB RAM tüketir. Asıl derleme işleri başladığında Kubernetes API'sini arayarak geçici (ephemeral) podlar ayağa kaldırır ve iş bitince siler.

---

### Adım 3: Dinamik Pod Yaşam Döngüsünün Doğrulanması

Runner'ın Kubernetes üzerinde dinamik pod açtığını canlı gözlemleyin:
1. GitLab projenizde basit bir pipeline tetikleyin.
2. Terminalinizden `gitlab-runner` namespace'ini izleyin:
   ```bash
   kubectl get pods -n gitlab-runner -w
   ```
3. `runner-xxxx-build-xxxx` adında bir podun saniyeler içinde açıldığını (`Pending -> Running`), derlemeyi tamamlayıp (`Completed`) otomatik olarak yok olduğunu gözlemleyin.

---

### Adım 4: Neden Docker-in-Docker (DinD) ve Kaniko Terk Edildi?

* **DinD Tehlikesi:** Pod'a `securityContext.privileged: true` verilmesini gerektirir. Pod root kullanıcısı ana makinenin Linux çekirdeğine erişebilir (Container Breakout riski).
* **Kaniko Durumu:** Google Container Tools ekibi tarafından **Haziran 2025'te resmen arşivlenmiş ve geliştirilmesi durdurulmuştur**.
* **Modern Standart (Buildah):** Tamamen unprivileged pod içinde, Linux user namespace ve chroot izolasyonu ile Dockerfile derler.

---

### Adım 5: Rootless Buildah ile İmaj Derleme Testi

Projenizin `.gitlab-ci.yml` dosyasına `solution/05-buildah-build.gitlab-ci.yml` içeriğini ekleyin. Pipeline çalıştığında:
* Build podunun `securityContext.privileged: false` ile çalıştığını,
* İmajın `buildah bud` ile derlenip başarıyla container registry'ye yüklendiğini doğrulayın.

---

### Adım 6: Trivy ile Zafiyet Taraması ve Güvenlik Kapısı (Gating)

İmaj derlendikten hemen sonra devreye giren `solution/06-trivy-scan.gitlab-ci.yml` işini çalıştırın:
```bash
# Trivy'nin komut mantığı:
trivy image --exit-code 1 --severity CRITICAL --ignore-unfixed <IMAGENAME>
```
* Eğer imajda düzeltilebilir **CRITICAL (Kritik)** seviyede açık yoksa işlem başarılı (`exit code 0`) olur ve bir sonraki aşamaya geçer.
* Eğer kritik açık varsa pipeline anında durdurulur (`exit code 1`).

---

### Adım 7: CycloneDX Formatında SBOM Üretimi

Yazılım Tedarik Zinciri Güvenliği gereği her derleme için bir **Yazılım Malzeme Listesi (SBOM - Software Bill of Materials)** üretilir:
```bash
trivy image --format cyclonedx --output sbom-cyclonedx.json <IMAGENAME>
```
Pipeline tamamlandığında GitLab Job Artifacts bölümünden `sbom-cyclonedx.json` dosyasını indirip uygulamanızın kullandığı tüm paket ve kütüphane envanterini inceleyin.

---

### Adım 8: CI'dan GitOps'a Köprü (Lab 5 ArgoCD Entegrasyonu)

Güvenlik taramasından başarıyla geçen yeni imaj tag'i (`$CI_COMMIT_SHA`), `solution/08-gitops-bridge.gitlab-ci.yml` adımı ile Lab 5'te hazırladığımız GitOps deposuna commit edilir:
```bash
# Pipeline içinde çalışan bot:
sed -i "s|image: .*|image: $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA|g" k8-project-5/solution/07-payment-rollout.yaml
git commit -m "chore(release): promote to $CI_COMMIT_SHA [skip ci]"
git push origin main
```
**Sonuç:** Kod commit edildiğinde Lab 5'teki ArgoCD değişikliği algılar ve Kubernetes üzerinde **Canary Rollout** sürecini otomatik başlatır!

---

### Adım 9: Uçtan Uca "Commit-to-Production" Canlı Testi

Uçtan uca birleştirilmiş pipeline dosyasını (`solution/09-complete-pipeline.gitlab-ci.yml`) uygulayın:
1. Kaynak kodda küçük bir değişiklik yapıp `git push` edin.
2. GitLab UI üzerinden sırasıyla:
   * **Test** aşamasının geçtiğini,
   * **Build** aşamasında Buildah'ın rootless imaj bastığını,
   * **Security** aşamasında Trivy'nin SBOM üretip zafiyet taramasını tamamladığını,
   * **Deploy** aşamasında GitOps deposunun güncellendiğini izleyin.
3. OKE kümenizde `kubectl get rollout -n production -w` komutuyla ArgoCD'nin yeni sürümü aşamalı olarak (%25 -> %50 -> %100) canlıya aldığını doğrulayın.

---

### Adım 10: Hatalı Kod Simülasyonu (Security Gate Failure)

DevSecOps'un gücünü kanıtlamak için bilerek güvenlik açığı olan bir imaj taratın (`solution/10-vulnerable-simulation.gitlab-ci.yml`):
1. Test işini manuel tetikleyin.
2. Trivy'nin onlarca **CRITICAL CVE** yakaladığını konsolda görün.
3. Trivy'nin `exit code 1` vererek **pipeline'ı derhal kırdığını (Failed)** gözlemleyin.
4. **Kanıt:** Güvenlik açığı bulunan imaj GitOps aşamasına geçememiş ve Kubernetes kümesine girmesi fiziksel olarak engellenmiştir!

---

## Temizlik

Laboratuvarı tamamladıktan sonra kümedeki bileşenleri kaldırmak için:

```bash
helm uninstall gitlab-runner -n gitlab-runner
kubectl delete -f solution/03-runner-rbac-and-namespace.yaml
```
