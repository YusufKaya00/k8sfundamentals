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
