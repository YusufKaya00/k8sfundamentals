# INCIDENT #5108 — OmniPulse v3.0.0 Platform Yayını Sonrası Tam Kesinti

## Olay Özeti (Incident Report)
Bu sabah saat 08:30'da kurumsal telemetri ve durum vitrini platformumuz **`omnipulse`**, `v3.0.0` mimarisine yükseltildi. Yeni sürümle birlikte tüm temel Kubernetes iş yükü objeleri tek bir Helm paketinde birleştirildi:
1. Oturum ve şema durumu için kalıcı diskli (`StatefulSet` + Headless `Service`) Redis katmanı (`omnipulse-cache`) devreye alındı.
2. Başlangıç şema anahtarını ve ortak web arayüz sayfasını (`index.html`) üreten bir başlangıç işi (`Job`) ile periyodik kalp atışı (`CronJob`) eklendi.
3. Üretilen statik rapor sayfasının (`index.html`) tüm düğümlerdeki (`Node`) çoklu web podları tarafından ortak okunabilmesi için paylaşımlı bir `PersistentVolumeClaim` (`omnipulse-shared-html`) bağlandı.
4. Düğüm bazlı sağlık izlemesi için küme genelinde çalışan bir `DaemonSet` (`omnipulse-node-agent`) eklendi.
5. Önyüz katmanı (`omnipulse-web`), `HorizontalPodAutoscaler` (`HPA`), `PodDisruptionBudget` (`PDB`), `NetworkPolicy`, `Service` ve `Ingress` ile dış dünyaya açıldı.

**Mevcut Durum:** Dağıtım sonrasında dış dünyadan Ingress IP'sine erişilemiyor, iş yüklerinin büyük kısmı başlamıyor ve sistem tamamen hizmet dışı.

---

## Kurulum (Lab Ortamını Başlatma)
```bash
# 1. AKS Altyapısını ve Ingress Controller'ı Kur
cd terraform
terraform init
terraform apply -auto-approve

# 2. Kubeconfig Bağlantısını Al
$(terraform output -raw kubeconfig_command)

# 3. Bozuk v3.0.0 Sürümünü Dağıt
cd ../
kubectl create namespace omnipulse-prod
helm upgrade --install omnipulse ./helm/omnipulse -n omnipulse-prod
```

---

## Hedef ve Kabul Kriterleri (Verification)

Helm chart dosyalarını (`helm/omnipulse/`) düzenleyip güncelledikten sonra aşağıdaki tüm doğrulama kontrolleri hatasız geçmelidir:

### 1. Tüm Kubernetes Objelerinin Durumu
`omnipulse-prod` namespace'indeki tüm objeler sağlıklı olmalı:
* Her iki `PVC` (`cache-data-omnipulse-cache-0` ve `omnipulse-shared-html`) **`Bound`** durumunda olmalı.
* `StatefulSet` (`omnipulse-cache-0`) ve `Deployment` (`omnipulse-web`) podları **`1/1 Running`** (`READY`) olmalı, `Pending` veya `CrashLoopBackOff` pod kalmamalı.
* `DaemonSet` (`omnipulse-node-agent`) her 2 düğümde de aktif (**`DESIRED: 2, READY: 2`**) olmalı.
* `Job` (`omnipulse-seed`) **`Completed` (`1/1`)** olmalı ve `CronJob` (`omnipulse-heartbeat`) aktif (`SUSPEND: False`) çalışmalı.
* `HPA` (`omnipulse-web-hpa`) hedef CPU metriğini okuyabilmeli (`<unknown>` olmamalı) ve `PDB` kesintiye izin vermeli (`ALLOWED DISRUPTIONS >= 1`).

```bash
kubectl get pvc,pods,sts,ds,jobs,cronjobs,svc,ep,hpa,pdb,ingress -n omnipulse-prod
```

### 2. Canlı Web Sitesi Erişimi (Tarayıcı & Terminal Testi)
Aşağıdaki komutla Ingress Public IP adresini al ve hem tarayıcıdan hem de curl ile test et:
```bash
export GATEWAY_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Canlı Site Adresi: http://$GATEWAY_IP"

curl -i http://$GATEWAY_IP
```

**Beklenen Çıktı:** `HTTP/1.1 200 OK` ve ekranda `OmniPulse Production Gateway - STATUS: ONLINE (v3.0.0)` HTML sayfası.

### 3. Lab Sonu Temizlik (Maliyet Kontrolü)
```bash
cd terraform
terraform destroy -auto-approve
```

---

## Mülakat Notları ve Çözüm Anahtarı

<details>
<summary><b>🧠 Mülakat Mantık Notları & Obje Tekrar Rehberi (Çözümü Görmeden Kavramsal Hatırlatma İçin Tıkla)</b></summary>

1. **Mülakat Sorusu — Tek bir PVC aynı anda birden fazla Pod'a (farklı Node'larda) bağlanabilir mi? (`ReadWriteOnce` vs `ReadWriteMany`):**
   * **`ReadWriteOnce` (`RWO`):** Disk aynı anda **yalnızca tek bir Node** tarafından yazılabilir/okunabilir şekilde bağlanabilir. Bulut blok diskleri (Azure Disk `managed-csi`, AWS EBS `gp3`) doğası gereği `RWO` çalışır. Farklı node'lardaki podlar aynı `RWO` PVC'yi bağlamaya çalışırsa **`Multi-Attach error for volume`** hatası alınır. Sadece `accessModes: ["ReadWriteMany"]` yapmak da yetmez; çünkü blok depolama (`managed-csi`) `RWX` desteklemez (`ProvisioningFailed`).
   * **`ReadWriteMany` (`RWX`):** Birden fazla Node üzerindeki çok sayıda Pod'un aynı anda okuma/yazma yapabilmesi için ağ tabanlı dosya sistemi (NFS/SMB) kullanan bir StorageClass seçilmelidir (AKS'de **`azurefile-csi`**, AWS'de **EFS**).

2. **Mülakat Sorusu — `StatefulSet` neden bir Headless Service (`clusterIP: None`) ve `serviceName` alanına ihtiyaç duyar?**
   * Deployment podlarının isimleri rastgele hash içerirken (`web-6d4f...`), StatefulSet podları sıralı ve sabit kimliğe sahiptir (`omnipulse-cache-0`, `omnipulse-cache-1`).
   * Bir pod'a doğrudan `<pod-adi>.<serviceName>.<namespace>.svc.cluster.local` DNS adresiyle erişebilmek için StatefulSet içindeki `spec.serviceName` alanının, `clusterIP: None` olan Headless Service'in `metadata.name` değeriyle **birebir aynı** olması gerekir.

3. **Mülakat Sorusu — `HPA` (`HorizontalPodAutoscaler`) neden `TARGETS: <unknown>/70%` gösterir?**
   * HPA, CPU kullanım yüzdesini şu formülle hesaplar: $(\text{Anlık CPU Kullanımı} / \text{Pod } \texttt{requests.cpu}) \times 100$.
   * Eğer hedef Deployment içindeki container'da `resources.requests.cpu` tanımlanmamışsa paydayı bilemediği için `<unknown>` döner. Ayrıca `scaleTargetRef.name` alanının hedef Deployment adıyla birebir eşleşmesi şarttır.

4. **Mülakat Sorusu — 2 Node'lu kümede 3 Replikalı Deployment neden 2 `Running`, 1 `Pending` kalır? (`podAntiAffinity`):**
   * `requiredDuringSchedulingIgnoredDuringExecution` (Hard Anti-Affinity) ve `topologyKey: kubernetes.io/hostname` kullanıldığında, Kubernetes her Node'a **en fazla 1 pod** koymaya zorlanır. Kümede 2 Node varsa 3. pod için uygun Node kalmaz ve `Pending` bekler. Çözüm: Replikayı Node sayısına çekmek (`2`) veya `preferredDuringScheduling...` (Soft Anti-Affinity) kullanmaktır.

5. **Mülakat Sorusu — Bir Pod'da hem `envFrom` (`ConfigMap`) hem de `env` içinde aynı değişken varsa hangisi geçerli olur? Ve `Job` neden güncellenemez?**
   * Container içindeki açık `env` tanımı, `envFrom` (`ConfigMapRef` / `SecretRef`) ile gelen değeri **ezer (override eder)**.
   * Ayrıca Kubernetes'te `Job` objesinin `spec.template` alanı **değiştirilemezdir (immutable)**. Şablonu düzelttikten sonra eski Job'ı `kubectl delete job <isim>` ile silmeden `helm upgrade` yaparsan `field is immutable` hatası alırsın.

6. **Mülakat Sorusu — `DaemonSet` oluşturulduğunda neden `DESIRED: 0` görünür?**
   * DaemonSet'in `spec.template.spec.nodeSelector` (veya `nodeAffinity`) etiketleri kümedeki hiçbir Node'da bulunmuyorsa zamanlayıcı (Scheduler) hiçbir düğümü hedeflemez ve `DESIRED: 0` kalır.

</details>

<details>
<summary><b>🔑 Tam Çözüm Anahtarı (Sadece Takıldığında veya Bitirdiğinde Kontrol Etmek İçin Tıkla)</b></summary>

1. **Hata 1 — StatefulSet StorageClass (`Pending` PVC):**
   * **Kök Neden:** `values.yaml` içinde `cache.storageClassName: "managed-csi-ultra"` tanımlı; AKS'de böyle bir sınıf yok.
   * **Çözüm:** `values.yaml` içinde `cache.storageClassName: "managed-csi"` yap.

2. **Hata 2 — StatefulSet Secret Anahtarı (`CreateContainerConfigError`):**
   * **Kök Neden:** `config-and-secret.yaml` içinde Secret anahtarı `REDIS_PASSWORD` iken, `cache-statefulset.yaml` içinde `key: CACHE_AUTH_KEY` aranıyor.
   * **Çözüm:** `cache-statefulset.yaml` içindeki `secretKeyRef.key` değerini `REDIS_PASSWORD` yap.

3. **Hata 3 — StatefulSet `serviceName` DNS Uyuşmazlığı (`omnipulse-cache-0` DNS Çözümleme Hatası):**
   * **Kök Neden:** Headless Service adı `{{ .Release.Name }}-cache` iken, StatefulSet içinde `serviceName: {{ .Release.Name }}-redis-headless` yazılmış. Bu yüzden `omnipulse-cache-0.omnipulse-cache` DNS kaydı oluşmuyor.
   * **Çözüm:** `cache-statefulset.yaml` içindeki `serviceName` değerini `{{ .Release.Name }}-cache` yap.

4. **Hata 4 — Paylaşımlı PVC (`Multi-Attach error` & `ReadWriteOnce` vs `ReadWriteMany`):**
   * **Kök Neden:** `omnipulse-shared-html` PVC'si hem `seed` Job'ı hem de farklı node'lardaki `web` podları tarafından aynı anda bağlanıyor. Ancak `values.yaml` içinde `storageClassName: "managed-csi"` ve `accessMode: "ReadWriteOnce"` verilmiş.
   * **Çözüm:** `values.yaml` altında `sharedStorage.storageClassName: "azurefile-csi"` ve `sharedStorage.accessMode: "ReadWriteMany"` olarak güncelle.

5. **Hata 5 — NetworkPolicy Etiket ve Port Engeli (`Job` ve `InitContainer` Bağlantı Zaman Aşımı):**
   * **Kök Neden:** `network-and-ingress.yaml` içindeki `cache-isolation-policy` sadece `tier: backend` podlarından ve `6380` portundan gelen trafiğe izin veriyor. Oysa Redis `6379` portunda ve istemci podlar `tier: batch` ile `tier: frontend` etiketine sahip.
   * **Çözüm:** `network-and-ingress.yaml` içinde port değerini `6379` yap ve `from` listesinde `tier: frontend` ile `tier: batch` etiketlerine izin ver (`matchExpressions` `key: tier, operator: In, values: [frontend, batch]`).

6. **Hata 6 — Batch `Job` Ortam Değişkeni Ezilmesi (`env` vs `envFrom`) ve `Job` Immutability:**
   * **Kök Neden:** `batch-jobs.yaml` içinde `envFrom` ile `ConfigMap` (`REDIS_HOST: omnipulse-cache`) çekilmesine rağmen, altındaki `env` bloğunda `REDIS_HOST: "127.0.0.1"` tanımlanarak doğru adresi ezmiş.
   * **Çözüm:** `batch-jobs.yaml` içindeki satır içi `REDIS_HOST: "127.0.0.1"` tanımını sil. (`Job` immutable olduğu için yükseltme öncesi `kubectl delete job omnipulse-seed -n omnipulse-prod` çalıştır).

7. **Hata 7 — `CronJob` Askıda (`suspend: true`):**
   * **Kök Neden:** `values.yaml` içinde `cronjob.suspend: true` bırakılmış.
   * **Çözüm:** `values.yaml` içinde `cronjob.suspend: false` yap.

8. **Hata 8 — `DaemonSet` `DESIRED: 0` (`nodeSelector`) ve Salt-Okunur Disk (`Read-only file system`):**
   * **Kök Neden:** `node-daemonset.yaml` içinde node'larda bulunmayan `node-role.kubernetes.io/telemetry: "enabled"` etiketi aranıyor (`DESIRED: 0`) ve log dizini `readOnly: true` bağlanmış.
   * **Çözüm:** `node-daemonset.yaml` içinden `node-role.kubernetes.io/telemetry: "enabled"` satırını kaldır ve `readOnly: false` yap.

9. **Hata 9 — `Deployment` 2-Node Hard `podAntiAffinity` (`Pending`) ve `OOMKilled` (`4Mi` Bellek Sınırı):**
   * **Kök Neden:** 2 node'lu kümede `replicas: 3` ve zorunlu (`requiredDuringScheduling...`) hostname anti-affinity verildiği için 3. pod `Pending` kalıyor. Ayrıca `memory: "4Mi"` sınırı yüzünden Nginx container `OOMKilled` (`137`) oluyor.
   * **Çözüm:** `values.yaml` içinde `webapp.replicas: 2` yap; `webapp.resources` altına `requests: { cpu: "50m", memory: "64Mi" }` ve `limits: { cpu: "200m", memory: "128Mi" }` tanımla.

10. **Hata 10 — Liveness/Readiness Probe Yolu (`/healthz` vs `/ready`):**
    * **Kök Neden:** Nginx ayarında sağlık kontrolü `/ready` iken `values.yaml` içinde `probePath: /healthz` verilmiş.
    * **Çözüm:** `values.yaml` içinde `probePath: /ready` yap.

11. **Hata 11 — `HPA` Hedef Adı (`scaleTargetRef`) ve `PDB` (`minAvailable`):**
    * **Kök Neden:** `scaling-and-pdb.yaml` içinde HPA `{{ .Release.Name }}-frontend` adında var olmayan bir Deployment'ı hedefliyor ve `values.yaml` içinde `pdb.minAvailable: 3` verilmiş.
    * **Çözüm:** `scaling-and-pdb.yaml` içinde HPA `scaleTargetRef.name` değerini `{{ .Release.Name }}-web` yap; `values.yaml` içinde `pdb.minAvailable: 1` yap.

12. **Hata 12 — `Service` (`selector` & `targetPort`) ve `Ingress` (`className`):**
    * **Kök Neden:** `network-and-ingress.yaml` içinde Service `tier: web-ui` seçiyor (`Endpoints: <none>`) ve `targetPort: 80` yönlendiriyor (Nginx `8080`'de). Ayrıca `values.yaml` içinde `ingress.className: traefik` verilmiş.
    * **Çözüm:** `network-and-ingress.yaml` içinde Service selector'ını `tier: frontend`, `targetPort` değerini `{{ .Values.webapp.containerPort }}` (`8080`) yap; `values.yaml` içinde `ingress.className: nginx` olarak güncelle.

> **Not:** Kalıcı disk (`PVC`) ve değiştirilemez (`StatefulSet` / `Job`) alanları güncelledikten sonra temiz bir geçiş için:
> ```bash
> kubectl delete sts,pvc,job --all -n omnipulse-prod
> helm upgrade --install omnipulse ./helm/omnipulse -n omnipulse-prod
> ```

</details>
