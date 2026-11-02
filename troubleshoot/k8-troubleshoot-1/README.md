# 🚨 SRE Incident Lab 1: ShopSphere E-Commerce Platform Outage Triage

> 📟 **URGENT PAGERDUTY INCIDENT ALERT:**  
> The ShopSphere production e-commerce platform has suffered a cascading multi-tier outage! Customers are unable to access the frontend, databases are unmounted, backend services are crashing in cyclic restart loops, and automated backups are failing silently.  
>  
> You are the On-Call Senior SRE (Site Reliability Engineer). Bring the platform back to full operational health and resolve all 11 incident tickets!

---

## 🎯 Lab Objectives & Architecture

This lab develops deep production troubleshooting skills across logs, events, internal DNS networking, storage classes, probes, and kernel constraints.
The environment exercises **over 17 integrated Kubernetes object types**:
* **Workloads:** Deployment, StatefulSet, DaemonSet
* **Networking & Traffic:** ClusterIP, NodePort, Headless Service, NetworkPolicy
* **Storage & Config:** PersistentVolumeClaim, ConfigMap, Secret
* **Autoscaling & Batch:** HorizontalPodAutoscaler (HPA), CronJob
* **Security & Authorization:** ServiceAccount, ClusterRole, ClusterRoleBinding

> 📖 **Root Cause Analyses (RCA), diagnostic runbooks, and fixed YAMLs:**  
> 👉 **[Explore Senior SRE Solution Guide (solution/README.md)](./solution/README.md)**

---

## 🚀 Environment Initialization (Deploying the Broken Cluster)

Spin up the broken environment on your cluster (Minikube, Kind, or OKE) with a single command:

```bash
kubectl apply -f manifests/
```

Inspect initial cluster health:
```bash
kubectl get all,pvc,hpa,cronjob,netpol -n ecom-prod
```
*Multiple pods are stuck in `Pending`, `CrashLoopBackOff`, `CreateContainerConfigError`, Service Endpoints report `<none>`, and HPA shows `<unknown>/50%`!*

---

## 🎫 On-Call SRE Incident Tickets

Resolve the tickets sequentially. Fixing one blocker will uncover downstream dependencies:

---

### 🎫 Ticket #1 (Frontend): "Web users receive connection failures; frontend pods fail to schedule!"
* **Reported by:** L1 Operations / Web Team
* **Symptom:** `frontend-web` pods remain indefinitely in `Pending`, unable to be assigned to any worker node.
* **Hint:** Inspect events with `kubectl describe pod -n ecom-prod -l app=frontend-web`. Check `nodeSelector`. Does the target label exist on any cluster node?

---

### 🎫 Ticket #2 (Gateway): "Frontend started, but requests to Catalog return 503 Service Unavailable!"
* **Reported by:** Frontend Engineers
* **Symptom:** `catalog-service` ClusterIP is unreachable. Even though pods are running, no traffic routes to them.
* **Hint:** Run `kubectl get endpoints catalog-service -n ecom-prod`. Why does it report `<none>`? Compare the Service `spec.selector` against the Pod `metadata.labels`!

---

### 🎫 Ticket #3 (Catalog): "Catalog pods crash repeatedly; restart count increases every minute!"
* **Reported by:** Backend Engineering
* **Symptom:** Pods initially encounter `CreateContainerConfigError`. Even after Secret keys are aligned, pods crash into `CrashLoopBackOff` after a few seconds.
* **Hint:** 
  1. Does the Secret key referenced in `env` match the actual key defined in `ecom-secret`?
  2. If the container startup takes 10 seconds, why is the `livenessProbe` checking at second 2? Is there a `startupProbe` buffer?

---

### 🎫 Ticket #4 (Orders): "Placing an order returns 'Connection Refused' immediately!"
* **Reported by:** Mobile App Team
* **Symptom:** `order-service` Endpoints are populated and the pod is `Running`. However, HTTP requests to port 80 are rejected with TCP RST (Connection Refused).
* **Hint:** Does the port listened to inside the container (`containerPort`) match the `targetPort` configured on `order-service`?

---

### 🎫 Ticket #5 (Database): "PostgreSQL pod will not start; PersistentVolumeClaim fails to bind!"
* **Reported by:** Database Administrator (DBA)
* **Symptom:** `postgres-pvc` remains stuck in `Pending`, blocking PostgreSQL pod startup.
* **Hint:** Run `kubectl describe pvc postgres-pvc -n ecom-prod`. Does the requested `storageClassName` exist on your cluster?

---

### 🎫 Ticket #6 (Cache): "Order service cannot resolve Redis: 'Hostname not found (NXDOMAIN)'!"
* **Reported by:** Platform Engineering
* **Symptom:** Redis StatefulSet pod is `Running` (`redis-0`), but `redis-0.redis-service` fails DNS resolution.
* **Hint:** Does the StatefulSet `spec.serviceName` match the exact `metadata.name` of the Headless Service?

---

### 🎫 Ticket #7 (Network Security): "DNS hostnames exist, but inter-service requests hang and timeout after 30 seconds!"
* **Reported by:** SecOps
* **Symptom:** `catalog-api` cannot connect to `postgres-service`; all DNS queries hang.
* **Hint:** In `ecom-network-policy`, does the egress rule explicitly allow UDP traffic to CoreDNS on port 53 in `kube-system`?

---

### 🎫 Ticket #8 (Autoscaling): "Load test running, but Catalog pods fail to scale up!"
* **Reported by:** Performance Engineering
* **Symptom:** `kubectl get hpa catalog-hpa -n ecom-prod` reports CPU target as `<unknown>/50%`.
* **Hint:** What resource specification (`resources.requests.cpu`) is mandatory on the Deployment container for HPA to compute utilization percentages?

---

### 🎫 Ticket #9 (Monitoring): "Node log collector DaemonSet fails to run on control-plane nodes!"
* **Reported by:** SRE Observability Team
* **Symptom:** `node-log-collector` runs on worker nodes but fails to schedule on control-plane / master nodes.
* **Hint:** Does the DaemonSet pod template contain a toleration for the control-plane `NoSchedule` taint?

---

### 🎫 Ticket #10 (Security): "Cluster auditor pod receives '403 Forbidden' querying Kubernetes API!"
* **Reported by:** Compliance & Security Audit
* **Symptom:** `ecom-auditor-pod` logs: `User cannot list resource pods in API group ""`.
* **Hint:** 
  1. For core Kubernetes resources (Pods, Services), what must `apiGroups` be in the `ClusterRole`? (`"core"` or `""`?)
  2. Does the `subjects` block in the `ClusterRoleBinding` specify the `namespace` of the ServiceAccount?

---

### 🎫 Ticket #11 (Backup): "Database backups fail; CronJob does not trigger or produces empty 0-byte dumps!"
* **Reported by:** Disaster Recovery Team
* **Symptom:** `db-backup-cronjob` fails to run on schedule, or manual executions output empty `.sql` files.
* **Hint:** 
  1. How many fields are in `spec.schedule`? Does Kubernetes expect standard 5-field cron syntax?
  2. How does the kubelet parse `$(date)` in command strings, and how do you escape shell variables?
  3. What happens if multiple arguments are passed following `/bin/sh -c`?

---

## 🏆 Definition of Done (Platform Recovery Verification)

Once all tickets are resolved, the following command must report a completely healthy platform:

```bash
kubectl get all,pvc,hpa,cronjob -n ecom-prod
```
* ✅ All Pods: `Running 1/1` or `Running 2/2`
* ✅ `catalog-service` and `order-service`: Endpoints populated with healthy pod IPs
* ✅ `postgres-pvc`: `Bound`
* ✅ `catalog-hpa`: Reading live CPU metrics (e.g., `1%/50%`)
* ✅ `ecom-auditor-pod`: Successfully listing cluster pods instead of 403 Forbidden errors

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

# ShopSphere E-Ticaret Platformu — SRE Troubleshooting & Arıza Kurtarma Laboratuvarı

> 🚨 **ACİL DURUM ÇAĞRISI (PAGERDUTY ALERT):**  
> ShopSphere e-ticaret platformunun canlı ortamında çok katmanlı bir sistem çöküşü yaşandı! Müşteriler web sitesine erişemiyor, veritabanı kilitlenmiş durumda, arka uç servisleri çökmüş ve yedekleme mekanizması çalışmıyor.  
> 
> Nöbetçi Kıdemli SRE (Site Reliability Engineer) sensin. Sistemin ayağa kalkması ve tüm biletlerin (tickets) yeşile dönmesi senin elinde!

---

## Laboratuvarın Amacı ve Kapsamı

Bu laboratuvar; ezbere komut yazmaktan çıkarıp **gerçek bir üretim krizinde log, event, network ve storage analizi yapma yeteneğini** kazandırır.
Laboratuvar içinde **17'den fazla farklı Kubernetes nesnesi** birbirine entegre halde çalışmaktadır:
* **İş Yükleri:** Deployment, StatefulSet, DaemonSet
* **Ağ & Trafik:** ClusterIP, NodePort, Headless Service, NetworkPolicy
* **Depolama & Konfigürasyon:** PersistentVolumeClaim, ConfigMap, Secret
* **Oto-Ölçekleme & Batch:** HorizontalPodAutoscaler (HPA), CronJob
* **Güvenlik & Yetkilendirme:** ServiceAccount, ClusterRole, ClusterRoleBinding

> 📖 **Kök neden analizleri (RCA), doğru komutlar ve çözümlü YAML'lar için:**  
> 👉 **[Kıdemli SRE Çözüm Rehberini İnceleyin (solution/README.md)](./solution/README.md)**

---

## Ortamı Başlatma (Bozuk Sistemi Ayağa Kaldır)

Laboratuvarı yerel Kubernetes kümenizde (Minikube, Kind veya OKE) başlatmak için tek bir komut çalıştırmanız yeterlidir:

```bash
kubectl apply -f manifests/
```

Şimdi durumu gözlemleyin:
```bash
kubectl get all,pvc,hpa,cronjob,netpol -n ecom-prod
```
*Gördüğünüz gibi birçok pod `Pending`, `CrashLoopBackOff`, `CreateContainerConfigError` durumunda, servislerin endpoint'leri boş ve HPA `<unknown>` gösteriyor!*

---

## Canlı Destek Biletleri (On-Call SRE Tickets)

Sırasıyla aşağıdaki biletleri çözerek zinciri kurtarın. Bir bileti çözdüğünüzde arkasındaki diğer problem gün yüzüne çıkacaktır:

---

### 🎫 Bilet #1 (Frontend): "Kullanıcılar web arayüzüne hiç erişemiyor, podlar başlamıyor!"
* **Bildiren:** Web Ekibi / L1 Support
* **Belirti:** `frontend-web` podları dakikalardır `Pending` durumunda bekliyor, hiçbir worker node'a atanamıyor.
* **İpucu:** `kubectl describe pod -n ecom-prod -l app=frontend-web` çıktısındaki **Events** ve `nodeSelector` alanını incele. Kümede böyle bir etiket var mı?

---

### 🎫 Bilet #2 (Gateway): "Frontend podunu ayağa kaldırdık ama Catalog servisine istek atarken '503 Service Unavailable' alıyoruz!"
* **Bildiren:** Frontend Geliştiricisi
* **Belirti:** `catalog-service` ClusterIP adresi yanıt vermiyor. Podlar çalışıyor görünmesine rağmen servise trafik akmıyor.
* **İpucu:** `kubectl get endpoints catalog-service -n ecom-prod` çıktısına bak. Neden `<none>` görünüyor? Servisin `selector`'ü ile podun `metadata.labels` değerlerini karşılaştır!

---

### 🎫 Bilet #3 (Catalog): "Catalog podları sürekli çöküyor ve restart sayısı dakikada bir artıyor!"
* **Bildiren:** Backend Ekibi
* **Belirti:** Podlar önce `CreateContainerConfigError` veriyor, Secret düzeltilse bile birkaç saniye sonra `CrashLoopBackOff` döngüsüne giriyor.
* **İpucu:** 
  1. Podun aradığı Secret key adı ile `ecom-secret` içindeki gerçek key adı uyuşuyor mu?
  2. Podun açılması 10 saniye sürerken `livenessProbe` kaçıncı saniyede kontrol yapıyor? `startupProbe` koruması var mı?

---

### 🎫 Bilet #4 (Sipariş): "Sipariş ver butonuna basınca 'Connection Refused' hatası alıyoruz!"
* **Bildiren:** Mobil Uygulama Ekibi
* **Belirti:** `order-service` endpoint'leri dolu ve pod `Running` durumunda. Ancak servisin 80 portuna atılan HTTP istekleri TCP RST (Connection Refused) ile reddediliyor.
* **İpucu:** Container'ın içinde dinlenen port (`containerPort`) ile `order-service`'in yönlendirdiği `targetPort` eşleşiyor mu?

---

### 🎫 Bilet #5 (Veritabanı): "PostgreSQL podu bir türlü açılmıyor, disk bağlanamadı!"
* **Bildiren:** Veritabanı Yöneticisi (DBA)
* **Belirti:** `postgres-pvc` dakikalardır `Pending` durumunda ve `postgres-db` podu diski bekliyor.
* **İpucu:** `kubectl describe pvc postgres-pvc -n ecom-prod` komutunu çalıştır. İstenen `storageClassName` yerel kümenizde mevcut mu?

---

### 🎫 Bilet #6 (Önbellek): "Order servisi Redis'e bağlanamıyor, 'Hostname not found (NXDOMAIN)' hatası var!"
* **Bildiren:** Platform Ekibi
* **Belirti:** Redis StatefulSet podu ayakta (`redis-0`), ancak `redis-0.redis-service` adresi DNS üzerinden çözülemiyor.
* **İpucu:** StatefulSet'in `spec.serviceName` alanı ile Headless Service'in `metadata.name` alanı birebir aynı mı?

---

### 🎫 Bilet #7 (Ağ Güvenliği): "DNS adları doğru ama servisler arası istekler 30 saniye donup zaman aşımına uğruyor!"
* **Bildiren:** Güvenlik Operasyonları (SecOps)
* **Belirti:** `catalog-api` podundan `postgres-service`'e erişmeye çalışırken DNS sorguları yanıt vermiyor.
* **İpucu:** `ecom-network-policy` egress kuralında CoreDNS'in çalıştığı `kube-system` namespace'indeki `53/UDP` portuna izin verilmiş mi?

---

### 🎫 Bilet #8 (Ölçekleme): "Yük testi yapıyoruz ama Catalog podları otomatik ölçeklenmiyor!"
* **Bildiren:** Performans Test Mühendisi
* **Belirti:** `kubectl get hpa catalog-hpa -n ecom-prod` çıktısında CPU hedefi `<unknown>/50%` olarak görünüyor.
* **İpucu:** HPA'nın yüzde hesabı yapabilmesi için Deployment container'ında hangi kaynak tanımının (`resources.requests.cpu`) mutlaka bulunması gerekir?

---

### 🎫 Bilet #9 (İzleme): "Düğüm log toplayıcı podları master/control-plane sunucusunda çalışmıyor!"
* **Bildiren:** SRE Observability Ekibi
* **Belirti:** `node-log-collector` DaemonSet'i yalnızca worker node'larda çalışıyor, master/control-plane sunucularında pod açılmıyor.
* **İpucu:** Master node'larda bulunan `NoSchedule` taint'i tolere eden `tolerations` bloğu DaemonSet pod şablonunda var mı?

---

### 🎫 Bilet #10 (Güvenlik): "Cluster denetçisi (Auditor Pod) Kubernetes API'sinden '403 Forbidden' hatası alıyor!"
* **Bildiren:** Uyumluluk & Denetim Ekibi
* **Belirti:** `ecom-auditor-pod` loglarında `User cannot list resource pods in API group ""` hatası var.
* **İpucu:** 
  1. `ClusterRole` içinde core kaynaklar için `apiGroups` ne olmalıdır? (`"core"` mu yoksa `""` mi?)
  2. `ClusterRoleBinding` içindeki `ServiceAccount` referansında `namespace` belirtilmiş mi?

---

### 🎫 Bilet #11 (Yedekleme): "Gece veritabanı yedeği alınmıyor, CronJob ya hiç tetiklenmiyor ya da içi boş dosya üretiyor!"
* **Bildiren:** Yedekleme & Felaket Kurtarma Ekibi
* **Belirti:** `db-backup-cronjob` zamanı geldiğinde tetiklenmiyor veya manuel tetiklendiğinde yedek dosyası oluşmuyor.
* **İpucu:** 
  1. `spec.schedule` alanında kaç alan (field) var? Kubernetes standart 5-alanlı cron mu bekliyor?
  2. Kubelet `$(date)` ifadesini neye dönüştürüyor? Shell değişkenini nasıl korursun?
  3. `/bin/sh -c` komutundan sonra birden fazla dizi argümanı yazarsan ne olur?

---

## Başarı Kriteri: Sistem Ne Zaman Kurtarılmış Sayılır?

Tüm biletleri düzelttiğinde şu komutun çıktısı kusursuz olmalıdır:

```bash
kubectl get all,pvc,hpa,cronjob -n ecom-prod
```
* ✅ Tüm Podlar `Running 1/1` veya `Running 2/2`
* ✅ `catalog-service` ve `order-service` Endpoints listeleri dolu
* ✅ `postgres-pvc` `Bound` durumunda
* ✅ `catalog-hpa` anlık CPU yüzdesini başarıyla okuyor (Örn: `1%/50%`)
* ✅ `ecom-auditor-pod` loglarında 403 hatası yerine pod listesi başarıyla listeleniyor

Başarılar SRE, sistem senin ellerinde! 🛠️
