# INCIDENT #7204 — PayNexus v4.2.0 Gerçek Zamanlı Finans & Mutabakat Platformu Yayını Sonrası Tam Kesinti

## Olay Özeti (Incident Report)
Bu sabah saat 08:30'da kurumsal ödeme ağ geçidi, finansal defter ve anlık mutabakat platformumuz **`paynexus`**, `v4.2.0` mimarisine yükseltildi. Yeni sürümle birlikte mikroservis altyapısındaki tüm temel Kubernetes iş yükü objeleri tek bir kurumsal Helm paketinde birleştirildi:

1. **İşlem Defteri & Kalıcı Veritabanı:** Oturum ve bakiye durumu için kalıcı diskli (`StatefulSet` + Headless `Service`) PostgreSQL veri tabanı katmanı (`paynexus-db`) devreye alındı.
2. **Şema Göçü ve Genesis Bloğu:** Veritabanında işlem tablolarını açan ve ilk blok kaydını (`#TX-1000000`) işleyerek canlı durum raporunu (`index.html`) üreten bir başlangıç işi (`Job`: `paynexus-migrator`) ile dakikalık mutabakat denetleyicisi (`CronJob`: `paynexus-auditor`) eklendi.
3. **Paylaşımlı Rapor Deposu:** Üretilen statik finansal durum vitrininin (`index.html`) tüm düğümlerdeki (`Node`) web podları tarafından ortak okunabilmesi için paylaşımlı bir `PersistentVolumeClaim` (`paynexus-shared-html`) bağlandı.
4. **Düğüm Güvenlik ve Uyumluluk Ajanı:** Her düğümde çalışan denetim podu için küme genelinde bir `DaemonSet` (`paynexus-security-agent`) eklendi.
5. **Önyüz & Ağ Geçidi:** Müşteri ödeme arayüzü (`paynexus-web`), `HorizontalPodAutoscaler` (`HPA`), `PodDisruptionBudget` (`PDB`), `NetworkPolicy`, `Service` ve `Ingress` ile dış dünyaya açıldı.

**Mevcut Durum:** Dağıtımın hemen ardından Ingress Gateway IP adresine gidildiğinde müşteriler `502 Bad Gateway` veya `503 Service Temporarily Unavailable` hatası alıyor, podların çoğu `CrashLoopBackOff`, `Init:0/1` veya `Pending` durumunda takılmış durumda ve finansal mutabakat tamamen durmuş vaziyette.

---

## Kurulum (Lab Ortamını Başlatma)
```bash
# 1. AKS Altyapısını ve Ingress Controller'ı Kur
cd terraform
terraform init
terraform apply -auto-approve

# 2. Kubeconfig Bağlantısını Al
$(terraform output -raw kubeconfig_command)

# 3. Bozuk v4.2.0 Sürümünü Dağıt
cd ../
kubectl create namespace paynexus-prod
helm upgrade --install paynexus ./helm/paynexus -n paynexus-prod
```

---

## Hedef ve Kabul Kriterleri (Verification)

Helm chart dosyalarını (`helm/paynexus/`) düzenleyip güncelledikten sonra aşağıdaki tüm doğrulama kontrolleri hatasız geçmelidir:

### 1. Tüm Kubernetes Objelerinin Durumu
`paynexus-prod` namespace'indeki tüm objeler sağlıklı olmalıdır:
* Her iki `PVC` (`db-data-paynexus-db-0` ve `paynexus-shared-html`) **`Bound`** durumunda olmalı.
* `StatefulSet` (`paynexus-db-0`) ve `Deployment` (`paynexus-web`) podları **`1/1 Running`** (`READY`) olmalı, `Pending` veya `CrashLoopBackOff` pod kalmamalıdır.
* `DaemonSet` (`paynexus-security-agent`) her 2 düğümde de aktif (**`DESIRED: 2, READY: 2`**) olmalıdır.
* `Job` (`paynexus-migrator`) **`Completed` (`1/1`)** olmalı ve `CronJob` (`paynexus-auditor`) aktif (**`SUSPEND: False`**) çalışmalıdır.
* `HPA` (`paynexus-web-hpa`) hedef CPU metriğini okuyabilmeli (`<unknown>` olmamalı) ve `PDB` kesintiye izin vermelidir (**`ALLOWED DISRUPTIONS >= 1`**).

```bash
kubectl get pvc,pods,sts,ds,jobs,cronjobs,svc,ep,hpa,pdb,ingress -n paynexus-prod
```

### 2. Canlı Web Sitesi Erişimi (Tarayıcı & Terminal Testi)
Aşağıdaki komutla Ingress Public IP adresini al ve hem tarayıcıdan hem de curl ile test et:
```bash
export GATEWAY_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Canlı Site Adresi: http://$GATEWAY_IP"

curl -i http://$GATEWAY_IP
```

**Beklenen Çıktı:** `HTTP/1.1 200 OK` ve ekranda `PayNexus Production Gateway - STATUS: ONLINE (v4.2.0)` HTML sayfası.

### 3. Lab Sonu Temizlik (Maliyet Kontrolü)
```bash
cd terraform
terraform destroy -auto-approve
```

---

## Mülakat Notları ve Çözüm Anahtarı

<details>
<summary><b>🧠 Mülakat Mantık Notları & Obje Tekrar Rehberi (Çözümü Görmeden Kavramsal Hatırlatma İçin Tıkla)</b></summary>

1. **Mülakat Sorusu — Kubernetes'te bir Pod API Server'a istek atarken neden `403 Forbidden` alır? (`ServiceAccount` & `RBAC`):**
   * Pod içerisinde açıkça bir `serviceAccountName` belirtilmezse, pod bulunduğu namespace'in `default` ServiceAccount'unu kullanır.
   * `default` ServiceAccount varsayılan olarak API server üzerinde hiçbir pod/service listeleme veya okuma yetkisine sahip değildir.
   * İlgili işlemler için özel bir `ServiceAccount` açılmalı, bir `Role` veya `ClusterRole` yazılarak `RoleBinding` ile bağlanmalı ve Pod spec içinde `serviceAccountName: <ad>` şeklinde atanmalıdır.

2. **Mülakat Sorusu — Tek bir PVC aynı anda birden fazla Pod'a (farklı Node'larda) bağlanabilir mi? (`ReadWriteOnce` vs `ReadWriteMany`):**
   * **`ReadWriteOnce` (`RWO`):** Bulut sağlayıcıların blok diskleri (Azure Disk `managed-csi`, AWS EBS) doğası gereği yalnızca tek bir sanal sunucuya (Node) eklenebilir. İki farklı node'daki pod aynı diski isterse **`Multi-Attach error for volume`** hatası verir.
   * **`ReadWriteMany` (`RWX`):** Birden fazla sunucudaki podların aynı dosya sistemine okuma/yazma yapabilmesi için NFS/SMB protokolü kullanan paylaşımlı ağ depolama sınıfları (AKS'de **`azurefile-csi`**, AWS'de **EFS**) seçilmelidir.

3. **Mülakat Sorusu — `NetworkPolicy` ile gelen trafik kısıtlandığında podlar neden bağlantı zaman aşımına (`Timeout`) düşer?**
   * Bir pod için `NetworkPolicy` tanımlandığında, o pod izole edilmiş sayılır.
   * Eğer veritabanı podunun policy'sinde `from` altında yalnızca `tier: backend` izinliyse, `tier: frontend` veya `tier: batch` etiketli podlar TCP handshake yapamaz ve SYN paketleri sessizce düşürülür (`i/o timeout`).

4. **Mülakat Sorusu — `StatefulSet` neden `serviceName` alanına ihtiyaç duyar ve Headless Service adı ile eşleşmezse ne olur?**
   * StatefulSet podlarının sabit ve öngörülebilir ağ kimlikleri vardır (`<pod-adi>.<serviceName>.<namespace>.svc.cluster.local`).
   * Eğer `spec.serviceName` değeri, `clusterIP: None` olan Headless Service'in `metadata.name` değeri ile birebir uyuşmazsa CoreDNS ilgili A kaydını oluşturmaz ve podlar birbirini DNS ile çözemez (`Name does not resolve`).

5. **Mülakat Sorusu — 2 Düğümlü bir kümede 3 Replikalı Deployment neden 1 `Pending` kalır? (`podAntiAffinity`):**
   * `requiredDuringSchedulingIgnoredDuringExecution` (Hard Anti-Affinity) kuralı, zamanlayıcıya "bu pod ile aynı etikete sahip başka bir podun bulunduğu node'a beni ASLA koyma" talimatı verir.
   * Kümede yalnızca 2 node varsa, ilk 2 pod iki node'a yerleşir. 3. pod için uygun boş node kalmadığından pod sonsuza kadar `Pending` bekler. Çözüm replikayı node sayısına eşitlemek (`2`) veya `preferredDuringScheduling...` (Soft Anti-Affinity) kullanmaktır.

6. **Mülakat Sorusu — Kubernetes `Job` objesinin `spec.template` alanı neden değiştirilemezdir (immutable)?**
   * Kubernetes mimarisinde tamamlanmış veya çalışan bir `Job`'ın pod şablonu geçmiş veri tutarlılığı için kilitlenir. Bir parametreyi düzelttikten sonra `helm upgrade` yapabilmek için eski Job'ın `kubectl delete job <job-adi>` ile kümeden temizlenmesi şarttır.

7. **Mülakat Sorusu — `HPA` neden `TARGETS: <unknown>/70%` gösterir?**
   * HPA hedef podun CPU kullanım yüzdesini hesaplayabilmek için `Pod Anlık CPU / Pod requests.cpu` oranını kullanır. Pod içinde `resources.requests.cpu` tanımlanmamışsa yüzde hesaplanamaz ve `<unknown>` döner. Ayrıca HPA `scaleTargetRef.name` alanının hedef Deployment ile birebir uyuşması zorunludur.

</details>

---

<details>
<summary><b>🔑 Tam Çözüm Anahtarı (Sadece Takıldığında veya Bitirdiğinde Kontrol Etmek İçin Tıkla)</b></summary>

Sistemde birbiri ardına tetiklenen **12 gerçekçi prodüksiyon hatası** bulunmaktadır:

1. **Hata 1 — StatefulSet StorageClass (`Pending` PVC & Pod):**
   * **Kök Neden:** `values.yaml` içinde `db.storageClassName: "managed-csi-premium-v2"` tanımlanmış; AKS'de böyle bir sınıf bulunmuyor.
   * **Çözüm:** `values.yaml` içinde `db.storageClassName: "managed-csi"` yap.

2. **Hata 2 — StatefulSet Secret Anahtar Uyuşmazlığı (`CreateContainerConfigError`):**
   * **Kök Neden:** `config-and-secret.yaml` içinde Secret anahtarı `POSTGRES_PASSWORD` iken, `db-statefulset.yaml` içinde `key: DB_MASTER_PASS` aranıyor.
   * **Çözüm:** `db-statefulset.yaml` içindeki `secretKeyRef.key` değerini `POSTGRES_PASSWORD` yap.

3. **Hata 3 — StatefulSet `serviceName` DNS Uyuşmazlığı (`paynexus-db-0` DNS Hatası):**
   * **Kök Neden:** Headless Service adı `{{ .Release.Name }}-db` iken, StatefulSet içinde `serviceName: {{ .Release.Name }}-postgres-headless` yazılmış.
   * **Çözüm:** `db-statefulset.yaml` içindeki `serviceName` değerini `{{ .Release.Name }}-db` yap.

4. **Hata 4 — Paylaşımlı Disk Modu (`Multi-Attach error` & `RWO` vs `RWX`):**
   * **Kök Neden:** `paynexus-shared-html` PVC'si hem `migrator` Job'ı hem de farklı düğümlerdeki `web` podları tarafından aynı anda bağlanıyor; ancak `values.yaml` içinde `managed-csi` ve `ReadWriteOnce` verilmiş.
   * **Çözüm:** `values.yaml` altında `sharedStorage.storageClassName: "azurefile-csi"` ve `sharedStorage.accessMode: "ReadWriteMany"` yap.

5. **Hata 5 — Migration Job: ServiceAccount & RBAC İzni Eksikliği (`403 Forbidden`):**
   * **Kök Neden:** `migration-job.yaml` içinde pod spec'inde `serviceAccountName` belirtilmediği için `default` ServiceAccount kullanılıyor ve pod bilgisi sorgulanamıyor.
   * **Çözüm:** `migration-job.yaml` içine `spec.template.spec` altına `serviceAccountName: {{ .Release.Name }}-migrator-sa` satırını ekle (veya yorum satırını kaldır).

6. **Hata 6 — Migration Job: Ortam Değişkeni Ezilmesi (`env` vs `envFrom`) & Job Immutability:**
   * **Kök Neden:** `migration-job.yaml` içinde `envFrom` ile ConfigMap çekilmesine rağmen, altındaki `env` bloğunda `DB_HOST: "127.0.0.1"` yazılmış.
   * **Çözüm:** `migration-job.yaml` içindeki satır içi `DB_HOST: "127.0.0.1"` tanımını kaldır veya `{{ .Release.Name }}-db` yap. (`Job` immutable olduğu için yükseltme öncesinde `kubectl delete job paynexus-migrator -n paynexus-prod` çalıştır).

7. **Hata 7 — NetworkPolicy İstemci Etiket Engeli (`Database Connection Timeout`):**
   * **Kök Neden:** `network-and-ingress.yaml` içindeki `db-isolation-policy` yalnızca `tier: backend` etiketine izin veriyor. Oysa istemciler `tier: frontend` (web) ve `tier: batch` (migrator/auditor) etiketine sahip.
   * **Çözüm:** `network-and-ingress.yaml` içinde `ingress.from` kısmına `tier: frontend` ve `tier: batch` etiketlerini ekle.

8. **Hata 8 — Auditor `CronJob` Askıda (`suspend: true`):**
   * **Kök Neden:** `values.yaml` içinde `cronjob.suspend: true` bırakılmış.
   * **Çözüm:** `values.yaml` içinde `cronjob.suspend: false` yap.

9. **Hata 9 — `DaemonSet` `DESIRED: 0` (`nodeSelector`) ve Salt-Okunur Mount (`Read-only file system`):**
   * **Kök Neden:** `security-daemonset.yaml` içinde node'larda bulunmayan `security.azure.com/agent-v4: "enabled"` etiketi aranıyor ve log dizini `readOnly: true` bağlanmış.
   * **Çözüm:** `security-daemonset.yaml` içinden `security.azure.com/agent-v4: "enabled"` satırını kaldır ve `readOnly: false` yap.

10. **Hata 10 — `Deployment` 2-Node Hard `podAntiAffinity` (`Pending`) ve `4Mi` Bellek Sınırı (`OOMKilled`):**
    * **Kök Neden:** 2 node'lu kümede `replicas: 3` ve zorunlu (`requiredDuringScheduling...`) hostname anti-affinity verildiği için 3. pod `Pending` kalıyor. Ayrıca `memory: "4Mi"` sınırı yüzünden Nginx `OOMKilled` (`137`) oluyor.
    * **Çözüm:** `values.yaml` içinde `webapp.replicas: 2` yap; `webapp.resources` altına `requests: { cpu: "50m", memory: "64Mi" }` ve `limits: { cpu: "200m", memory: "128Mi" }` tanımla.

11. **Hata 11 — Liveness/Readiness Probe Yolu (`/status` vs `/ready`):**
    * **Kök Neden:** Nginx konfigürasyonunda sağlık kontrolü `/ready` iken `values.yaml` içinde `probePath: /status` verilmiş (404 hatası ve pod restartları).
    * **Çözüm:** `values.yaml` içinde `probePath: /ready` yap.

12. **Hata 12 — Service Selector & TargetPort (`502 Bad Gateway` / `<none>` Endpoints) ve Ingress Class:**
    * **Kök Neden:** `network-and-ingress.yaml` içinde Service `tier: gateway` seçiyor (`Endpoints: <none>`) ve `targetPort: 80` yönlendiriyor (Nginx `8080`'de). Ayrıca `values.yaml` içinde `ingress.className: traefik` verilmiş.
    * **Çözüm:** `network-and-ingress.yaml` içinde Service selector'ını `tier: frontend`, `targetPort` değerini `{{ .Values.webapp.containerPort }}` (`8080`) yap; `values.yaml` içinde `ingress.className: nginx` yap.

13. **Hata 13 — `HPA` Hedef Adı (`scaleTargetRef`) ve `PDB` (`minAvailable`):**
    * **Kök Neden:** `scaling-and-pdb.yaml` içinde HPA `{{ .Release.Name }}-api-server` adında var olmayan bir Deployment'ı hedefliyor ve `values.yaml` içinde `pdb.minAvailable: 3` verilmiş.
    * **Çözüm:** `scaling-and-pdb.yaml` içinde HPA `scaleTargetRef.name` değerini `{{ .Release.Name }}-web` yap; `values.yaml` içinde `pdb.minAvailable: 1` yap.

---

> **Temiz Geçiş İpucu:**
> Değiştirilemez (`Job` / `StatefulSet`) ve depolama (`PVC`) tanımlarını güncelledikten sonra temiz bir dağıtım için:
> ```bash
> kubectl delete sts,pvc,job --all -n paynexus-prod
> helm upgrade --install paynexus ./helm/paynexus -n paynexus-prod
> ```

</details>
