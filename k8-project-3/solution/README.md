# OCI OKE Production Laboratuvarı — Kapsamlı Çözüm Rehberi

Bu doküman; **Oracle Cloud Infrastructure (OCI) Container Engine for Kubernetes (OKE)** üzerinde çalışan **3 worker node'lu (VM.Standard.E5.Flex, Oracle Linux 9, k8s v1.37.0)** gerçek bir üretim kümesinde uygulanmak üzere hazırlanan 13 adımlık müfredatın uçtan uca komutlarını, mimari gerekçelerini, doğrulama adımlarını ve OCI üretim ortamı hata giderme (Troubleshooting) rehberini içerir.

> Tüm manifestolar bu dizinde (`solution/`) yer almaktadır. Komutlar `solution/` dizini içerisinden veya proje kök dizininden çalıştırılabilir.

---

## 1. Adım: OKE Worker Node Keşfi, Etiketleme ve Taint Yönetimi

### Mimari Gerekçe
Üretim ortamlarında veri tabanı gibi I/O yoğun ve kritik stateful iş yükleri ile ön yüz web servisleri aynı fiziksel kaynakları tüketmemelidir. 
- **Taint (`workload=database:NoSchedule`):** Özel toleration tanımı taşımayan hiçbir pod'un (örneğin web pod'ları, batch işler vb.) 3. worker node'a çizelgelenmesine izin vermez.
- **Label (`tier=database` ve `tier=web`):** İlgili iş yüklerinin `nodeSelector` veya `nodeAffinity` kurallarıyla tam olarak hedef node grubuna yönlendirilmesini sağlar.

### Uygulama Komutları

```bash
# 1. Mevcut OKE worker node'larını listeleyin ve isimlerini doğrulayın
kubectl get nodes -o wide

# 2. Node isimlerini otomatik olarak bash değişkenlerine atayın
NODE1=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
NODE2=$(kubectl get nodes -o jsonpath='{.items[1].metadata.name}')
NODE3=$(kubectl get nodes -o jsonpath='{.items[2].metadata.name}')

echo "Web Node 1 : $NODE1"
echo "Web Node 2 : $NODE2"
echo "DB Node    : $NODE3"

# 3. 3. Node'a veritabanı izolasyon taint'i ve etiketini ekleyin
kubectl taint nodes "$NODE3" workload=database:NoSchedule --overwrite
kubectl label nodes "$NODE3" tier=database --overwrite

# 4. 1. ve 2. Node'lara web katmanı etiketini ekleyin
kubectl label nodes "$NODE1" "$NODE2" tier=web --overwrite
```

### Doğrulama Komutları

```bash
# Node etiketlerini doğrulayın
kubectl get nodes -L tier,workload

# 3. Node üzerindeki taint tanımını kontrol edin
kubectl describe node "$NODE3" | grep -i taints
# Beklenen Çıktı: Taints: workload=database:NoSchedule

# Taint özet tablosunu yazdırın
kubectl get nodes -o custom-columns=NAME:.metadata.name,TIER:.metadata.labels.tier,TAINTS:.spec.taints
```

---

## 2. Adım: Çoklu Kiracılık, Namespace İzolasyonu ve Kaynak Kotaları

### Mimari Gerekçe
OKE üzerinde çok kiracılı veya üretim/test ortamı paylaşımlı kümelerde kontrolsüz kaynak kullanımı, noisy-neighbor sendromuna ve kümenin kaynaklarının tükenmesine yol açar.
- **ResourceQuota:** `production` namespace'i için toplam CPU (4 req / 8 lim), RAM (8Gi req / 16Gi lim), pod sayısı (20) ve OCI Block Volume depolama tavanını (200Gi) sabitler.
- **LimitRange:** Pod tanımında CPU/Memory belirtmeyi unutan geliştirici hatalarına karşı otomatik varsayılan (default) ve asgari (min) değerler enjekte eder.

### Uygulama Komutu

```bash
kubectl apply -f ./02-namespaces-and-quotas.yaml
```

### Doğrulama Komutları

```bash
# Namespace durumunu kontrol edin
kubectl get ns production

# ResourceQuota limit ve mevcut kullanım değerlerini inceleyin
kubectl describe resourcequota production-quota -n production

# LimitRange kural setini doğrulayın
kubectl describe limitrange production-limit-range -n production
```

---

## 3. Adım: Dedicated Node Scheduling ve İş Yükü Ayrımı (Mimari Tasarım)

### Mimari Gerekçe
Kubernetes varsayılan zamanlayıcısı (kube-scheduler), iş yüklerini boştaki kaynaklara göre dağıtır. Üretim standardında şu iki yönlü kural zorunlu kılınmıştır:
1. **İtme (Repel) Mekanizması:** 3. worker node'daki `workload=database:NoSchedule` taint'i sayesinde, PostgreSQL dışındaki pod'lar (örneğin web pod'ları veya redis) toleration içermediği için bu node'a **asla yerleşemez**.
2. **Çekme (Attract) Mekanizması:** PostgreSQL pod'u hem bu taint için `toleration` taşır hem de `nodeSelector: { tier: database }` kuralı sayesinde **kesinlikle 3. node üzerinde** çalışır. Web API pod'ları ise `nodeSelector: { tier: web }` ile 1. ve 2. node'lara yönlendirilir.

### Doğrulama (Negatif Test)

```bash
# Toleration'ı olmayan geçici bir test pod'unu DB node'una zorlamayı deneyin:
kubectl run test-fail -n production --image=busybox:1.36 --overrides='{"spec": {"nodeSelector": {"tier": "database"}}}' --restart=Never -- sleep 60

# Pod durumunu kontrol edin (Taint tolere edilemediği için Pending kalmalıdır):
kubectl get pod test-fail -n production
kubectl describe pod test-fail -n production | grep -E "(FailedScheduling|untolerated taint)"

# Test pod'unu temizleyin
kubectl delete pod test-fail -n production --force --grace-period=0
```

---

## 4. Adım: Güvenli Konfigürasyon ve Secret Yönetimi

### Mimari Gerekçe
12-Factor App prensiplerine göre kod, konfigürasyon ve gizli bilgiler kesinlikle birbirinden ayrılmalıdır.
- Veritabanı kullanıcı adı ve parolası Kubernetes `Secret` nesnesinde tutularak ortam değişkeni olarak güvenli şekilde aktarılır.
- Host, port, log seviyesi ve ortam adı gibi çalışma zamanı parametreleri `ConfigMap` üzerinden pod'a bağlanır.

### Uygulama Komutu

```bash
kubectl apply -f ./04-config-and-secret.yaml
```

### Doğrulama Komutları

```bash
# Secret ve ConfigMap nesnelerini listeleyin
kubectl get secret,configmap -n production

# Secret içerisindeki veriyi base64 decode ederek teyit edin
kubectl get secret postgres-secret -n production -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo
# Beklenen Çıktı: okeadmin

# ConfigMap içeriğini görüntüleyin
kubectl describe configmap app-config -n production
```

---

## 5. Adım: OCI Block Volume ile Kalıcı PostgreSQL Dağıtımı

### Mimari Gerekçe
Yerel diskler (hostPath, emptyDir) node göçlerinde veya arızalarında veri kaybına yol açar. OCI OKE ortamında:
- `storageClassName: oci-bv` kullanılarak **Oracle Cloud Native Block Volume CSI Driver** tetiklenir ve OCI veri merkezinde bağımsız bir Block Volume dinamik olarak oluşturulur.
- OCI Block Volume hizmetinde bir diskin bağlanabileceği asgari kota 50 GiB'dir; PVC `50Gi` olarak talep edilmiştir.
- Pod güncellemesinde OCI Block Volume tek bir VM'e bağlanabildiğinden (ReadWriteOnce), Deployment stratejisi `Recreate` olarak ayarlanmıştır.

### Uygulama Komutu

```bash
kubectl apply -f ./05-postgres-pvc-deployment.yaml
```

### Doğrulama Komutları

```bash
# 1. PVC durumunu takip edin (Pending -> Bound olmalıdır)
kubectl get pvc -n production -w

# 2. PV detayını ve OCI Volume OCID bilgisini inceleyin
kubectl get pv

# 3. PostgreSQL pod'unun 3. node (DB node) üzerinde çalıştığını doğrulayın
kubectl get pods -n production -l app=postgres -o wide

# 4. Veritabanının hazır olduğunu container içinden doğrulayın
kubectl exec -n production deploy/postgres -c postgres -- pg_isready -U okeadmin -d productiondb
# Beklenen Çıktı: /var/run/postgresql:5432 - accepting connections

# 5. Tablo oluşturup örnek veri yazın
kubectl exec -n production deploy/postgres -c postgres -- psql -U okeadmin -d productiondb -c "
CREATE TABLE IF NOT EXISTS system_metrics (id SERIAL PRIMARY KEY, metric_name VARCHAR(50), recorded_at TIMESTAMPTZ DEFAULT NOW());
INSERT INTO system_metrics (metric_name) VALUES ('oke_cluster_ready'), ('block_volume_mounted');
SELECT * FROM system_metrics;
"
```

---

## 6. ve 7. Adım: Yüksek Erişilebilirlikli Web API Dağıtımı

### Mimari Gerekçe
Web servislerinin üretim ortamında kesintisiz çalışması için 4 kritik mühendislik standardı uygulanmıştır:
1. **InitContainer (`wait-for-postgres`):** Web API ayağa kalkmadan önce veritabanının 5432 portunu `pg_isready` ile yoklar. Veritabanı hazır olmadan ana container'ın başlayıp CrashLoopBackOff'a düşmesini engeller.
2. **Sağlık Kontrolleri:**
   - `startupProbe`: Uygulama başlatma evresindeyken liveness'ın pod'u erken öldürmesini engeller.
   - `readinessProbe`: Hazır olmayan pod'un OCI Load Balancer havuzundan otomatik çıkarılmasını sağlar.
   - `livenessProbe`: Kilitlenen veya yanıt vermeyen container'ları yeniden başlatır.
3. **Anti-Affinity ve Topology Spread:** 2 replika web pod'unun aynı worker node'a düşmesini engellemek için `podAntiAffinity` ve `topologySpreadConstraints` (maxSkew: 1, topologyKey: hostname) kuralları uygulanır. Pod'lar iki web node'una (1. ve 2. node) 1'er adet dağılır.
4. **Graceful Shutdown (`lifecycle.preStop` sleep 10):** Pod silinirken Kubernetes eşzamanlı olarak endpoint'i siler ve pod'a SIGTERM gönderir. `preStop` kancası 10 saniye bekleyerek OCI Load Balancer'ın pod'u hedef listesinden çıkarmasına ve mevcuttaki açık TCP bağlantılarının başarıyla tamamlanmasına (connection draining) imkan tanır.

### Uygulama Komutu

```bash
kubectl apply -f ./06-07-web-deployment.yaml
```

### Doğrulama Komutları

```bash
# 1. Pod'ların dağılımını izleyin (Farklı web node'larında çalışmalıdır)
kubectl get pods -n production -l app=web-api -o wide

# 2. InitContainer'ın loglarını inceleyerek DB kontrolünü teyit edin
kubectl logs -n production -l app=web-api -c wait-for-postgres --tail=10

# 3. Pod'un sağlık kontrolü endpoint'lerini sorgulayın
kubectl exec -n production deploy/web-api -c web-api -- wget -qO- http://localhost:8080/healthz
# Beklenen Çıktı: {"status": "healthy", "pod": "web-api-..."}

# 4. Web API üzerinden veritabanı bağlantısını sorgulayın
kubectl exec -n production deploy/web-api -c web-api -- wget -qO- http://localhost:8080/db
# Beklenen Çıktı: {"pod": "...", "db_host": "postgres", "db_port": 5432, "db_connected": true}
```

---

## 8. Adım: Mikro Segmentasyon ve Ağ Güvenliği (NetworkPolicy)

### Mimari Gerekçe
Kubernetes varsayılan olarak açık (flat network) bir ağ modeline sahiptir; herhangi bir namespace'teki herhangi bir pod doğrudan PostgreSQL portuna bağlanabilir.
- `08-network-policy.yaml` manifestosu `app: postgres` pod'unu izole eder (Default-Deny Ingress).
- Sadece `production` namespace'indeki `app: web-api` etiketli pod'lardan gelen 5432/TCP trafiğine izin verilir. Diğer tüm trafik OCI CNI seviyesinde düşürülür.

### Uygulama Komutu

```bash
kubectl apply -f ./08-network-policy.yaml
```

### Doğrulama Komutları

```bash
# NetworkPolicy kuralını görüntüleyin
kubectl describe networkpolicy postgres-allow-web-api-only -n production

# 1. İZİN VERİLEN ERİŞİM: Web API pod'u üzerinden veritabanı testi (Başarılı olmalı)
kubectl exec -n production deploy/web-api -c web-api -- wget -qO- http://localhost:8080/db

# 2. ENGELLENEN ERİŞİM: Aynı namespace'te fakat etiketsiz bir pod ile doğrudan bağlantı testi
kubectl run unauthorized-client -n production --rm -it --restart=Never --image=postgres:16-alpine -- pg_isready -h postgres -p 5432 -t 3
# Beklenen Çıktı: postgres:5432 - no response (Bağlantı engellenir ve zaman aşımına uğrar)
```

---

## 9. Adım: OCI Native Flexible Load Balancer Entegrasyonu

### Mimari Gerekçe
Kubernetes'te `LoadBalancer` tipi servis oluşturulduğunda OCI Cloud Controller Manager (CCM) arka planda gerçek bir OCI Load Balancer provizyon eder.
- `service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"`: Sabit şekiller (100Mbps, 400Mbps) yerine kaynak tasarrufu sağlayan OCI esnek mimarisini seçer.
- `shape-flex-min: "10"` ve `shape-flex-max: "40"`: Yük dengeleyicinin 10 Mbps ile 40 Mbps arasında otomatik ölçeklenmesini sağlar.
- `security-list-management-mode: "All"`: OCI VCN Güvenlik Listelerine gerekli Port 80 Ingress kurallarını otomatik ekler.

### Uygulama Komutu

```bash
kubectl apply -f ./09-web-loadbalancer-service.yaml
```

### Doğrulama Komutları

```bash
# 1. LoadBalancer servisinin OCI Public IP almasını takip edin (~1-2 dakika sürer)
kubectl get svc web-api-lb -n production -w

# 2. Servis anotasyonlarını ve OCI Load Balancer OCID bilgisini kontrol edin
kubectl describe svc web-api-lb -n production

# 3. Alınan External IP adresine dış dünyadan istek atın
LB_IP=$(kubectl get svc web-api-lb -n production -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "OCI Load Balancer IP: $LB_IP"

# Dış dünya erişim testi
curl -i "http://${LB_IP}/"
curl -s "http://${LB_IP}/db" | jq .
```

---

## 10. Adım: OCI Block Volume Destekli Redis StatefulSet Dağıtımı

### Mimari Gerekçe
Önbellek ve kuyruk yönetiminde çalışan Redis replikalarının sabit ağ kimliklerine ve bağımsız kalıcı disklere ihtiyacı vardır:
- **Headless Service (`clusterIP: None`):** DNS sorgularında sanal IP yerine doğrudan pod IP'lerini döner (`redis-0.redis-headless.production.svc.cluster.local`).
- **`volumeClaimTemplates`:** Her bir replika pod için (`redis-0` ve `redis-1`) OCI CSI üzerinden bağımsız birer 10Gi `oci-bv` Block Volume dinamik olarak üretilir (`redis-data-redis-0`, `redis-data-redis-1`).
- `nodeSelector: { tier: web }` ile veritabanı node'u dışındaki web node'larında barındırılır.

### Uygulama Komutu

```bash
kubectl apply -f ./10-redis-statefulset.yaml
```

### Doğrulama Komutları

```bash
# 1. StatefulSet ve Pod'ların durumunu inceleyin
kubectl get statefulset,pods -n production -l app=redis -o wide

# 2. Her pod için bağımsız açılan OCI Block Volume PVC'lerini listeleyin
kubectl get pvc -n production -l app=redis

# 3. redis-0 üzerine anahtar yazın
kubectl exec -n production redis-0 -c redis -- redis-cli set oke:cluster "production-active"

# 4. redis-0 üzerinden veriyi okuyun
kubectl exec -n production redis-0 -c redis -- redis-cli get oke:cluster
# Beklenen Çıktı: "production-active"

# 5. Pod silindiğinde aynı diski bağlayarak veriyi koruduğunu doğrulayın
kubectl delete pod redis-0 -n production
kubectl wait --for=condition=Ready pod/redis-0 -n production --timeout=120s
kubectl exec -n production redis-0 -c redis -- redis-cli get oke:cluster
# Beklenen Çıktı: "production-active" (Veri kalıcıdır)
```

---

## 11. Adım: Otomatik Yatay Ölçeklendirme (HPA) ve Kesinti Bütçesi (PDB)

### Mimari Gerekçe
- **HorizontalPodAutoscaler (HPA):** OKE Metrics Server üzerinden CPU kullanımını izler. Ortalama kullanım %60'ı aştığında pod sayısını dinamik olarak 8'e kadar artırır.
- **PodDisruptionBudget (PDB):** Node bakımı, kubernetes sürüm yükseltme veya drain işlemleri sırasında `minAvailable: 1` kuralı sayesinde servis kesintisini engeller.

### Uygulama Komutu

```bash
kubectl apply -f ./11-hpa-and-pdb.yaml
```

### Doğrulama ve Yük Testi Komutları

```bash
# HPA ve PDB durumunu kontrol edin
kubectl get hpa,pdb -n production

# Web API üzerindeki CPU tüketim endpoint'ine (/burn) yük oluşturucu başlatın
kubectl run load-generator -n production --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://web-api:8080/burn > /dev/null; done"

# HPA'nın CPU artışına tepki vererek replika sayısını artırmasını izleyin
kubectl get hpa web-api-hpa -n production -w

# Yük testini sonlandırın
kubectl delete pod load-generator -n production
```

---

## 12. Adım: En Az Yetki Prensibi (RBAC) ve In-Cluster API İstemcisi

### Mimari Gerekçe
Konteynerlerin varsayılan geniş yetkili token'larla çalışması ciddi güvenlik açığıdır (Lateral Movement riski).
- `ServiceAccount (`api-client-sa`)`: Yalnızca `production` namespace'i ile sınırlandırılmıştır.
- `Role (`pod-event-reader`)`: Yalnızca `pods` ve `events` nesnelerini `get` ve `list` edebilir; silme, değiştirme veya secret okuma yetkisi yoktur.
- `Pod (`api-client-pod`)`: OKE Kubernetes API Server'a CA sertifikası ve Bearer token ile HTTPS sorgusu atarak yetkisini kanıtlar.

### Uygulama Komutu

```bash
kubectl apply -f ./12-rbac-and-client-pod.yaml
```

### Doğrulama Komutları

```bash
# 1. RBAC yetkilerini kubectl can-i ile doğrulayın
kubectl auth can-i list pods -n production --as=system:serviceaccount:production:api-client-sa
# Beklenen Çıktı: yes

kubectl auth can-i list events -n production --as=system:serviceaccount:production:api-client-sa
# Beklenen Çıktı: yes

kubectl auth can-i get secrets -n production --as=system:serviceaccount:production:api-client-sa
# Beklenen Çıktı: no (Yetkisiz)

kubectl auth can-i list pods -n default --as=system:serviceaccount:production:api-client-sa
# Beklenen Çıktı: no (Farklı namespace yetkisiz)

# 2. İstemci pod'unun loglarını inceleyerek API çıktısını teyit edin
kubectl logs -n production api-client-pod -c curl | head -n 40
```

---

## 13. Adım: Planlı Bakım ve Güvenli Drenaj Operasyonu (Maintenance & Drain)

### Mimari Gerekçe
Üretim ortamlarında worker node'ların kernel güncellemeleri, OCI işletim sistemi yamaları veya donanım bakımları için güvenli biçimde boşaltılması (drain) gerekir. Bu adımda:
- Web pod'unun çalıştığı node tespit edilir.
- `kubectl drain` çalıştırıldığında `web-api-pdb` devreye girer; tahliye edilen pod diğer web node'unda ayağa kalkıp Ready olmadan mevcut pod kapatılmaz. Servis sıfır kesintiyle çalışmaya devam eder.

### Uygulama ve Doğrulama Adımları

```bash
# 1. Web pod'larının hangi node'larda çalıştığını listeleyin
kubectl get pods -n production -l app=web-api -o wide

# 2. Drene edilecek web node'unu seçin (Örneğin NODE1)
TARGET_NODE=$(kubectl get pods -n production -l app=web-api -o jsonpath='{.items[0].spec.nodeName}')
echo "Bakıma alınacak hedef node: $TARGET_NODE"

# 3. Node'u yeni çizelgelemeye kapatın (Cordon)
kubectl cordon "$TARGET_NODE"
kubectl get nodes

# 4. Node üzerindeki pod'ları güvenli biçimde tahliye edin (Drain)
# PDB kuralları gereği en az 1 web pod'u daima ayakta kalarak servis kesintisini önler
kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s

# 5. Pod'ların diğer web node'una kesintisiz aktarıldığını doğrulayın
kubectl get pods -n production -l app=web-api -o wide
kubectl get pdb web-api-pdb -n production

# 6. Dış dünyadan servisin kesintisiz yanıt verdiğini teyit edin
curl -s "http://${LB_IP}/healthz"

# 7. Bakım tamamlandı: Node'u tekrar çizelgelemeye açın (Uncordon)
kubectl uncordon "$TARGET_NODE"
kubectl get nodes

# 8. Web dağıtımını yeniden başlatarak pod'ların tekrar 2 node'a dengeli dağılmasını sağlayın
kubectl rollout restart deployment web-api -n production
kubectl rollout status deployment web-api -n production
kubectl get pods -n production -l app=web-api -o wide
```

---

## OCI Üretim İpuçları ve Sorun Giderme (Troubleshooting Runbook)

### 1. OCI Block Volume (`oci-bv`) Hataları ve Kota Aşımı
- **Hata:** `FailedAttachVolume: Multi-Attach error for volume ... volume is already exclusively attached to one node`
  - **Neden:** OCI Block Volume diskleri `ReadWriteOnce` modundadır. Rolling update esnasında yeni pod eski pod kapanmadan diski takmaya çalıştığında oluşur.
  - **Çözüm:** Stateful iş yükleri ve tekil PostgreSQL Deployment tanımlarında `strategy.type: Recreate` kullanılmalıdır.
- **Hata:** `The volume size must be at least 50 GB`
  - **Neden:** OCI Block Volume depolama servisi minimum 50 GiB boyutunu zorunlu kılar.
  - **Çözüm:** PVC tanımlarında `storage: 50Gi` veya üzeri değerler belirtilmelidir.
- **Hata:** `Service limit reached for Block Volume in Availability Domain`
  - **Neden:** OCI kiracılığınızdaki (Tenancy) Block Volume GB kotası dolmuştur.
  - **Çözüm:** OCI Console -> Governance & Administration -> Limits, Quotas and Usage ekranından Block Volume kotanızı kontrol edin veya kullanılmayan eski PVC/PV'leri silin.

### 2. OCI IAM & Instance Principal Yetkileri
- OKE worker node'larının OCI API'leriyle (Block Volume ekleme, Load Balancer oluşturma) konuşabilmesi için OCI IAM üzerinde bir **Dynamic Group** ve ilgili **Policy** tanımlı olmalıdır:
  ```text
  Allow dynamic-group <oke-node-pool-dynamic-group> to manage volume-family in compartment <compartment-name>
  Allow dynamic-group <oke-node-pool-dynamic-group> to manage load-balancers in compartment <compartment-name>
  Allow dynamic-group <oke-node-pool-dynamic-group> to use subnets in compartment <compartment-name>
  ```

### 3. OCI Flexible Load Balancer "Pending" Durumunda Kalması
- **Belirti:** `kubectl get svc web-api-lb` komutunda `EXTERNAL-IP` değeri sürekli `<pending>` kalıyor.
- **Olası Nedenler ve Çözüm Adımları:**
  1. **Subnet Tipi:** Load Balancer'ın kurulacağı subnet'in Public Subnet olduğundan ve Internet Gateway'e yönlenen bir Route Table kaydı (`0.0.0.0/0 -> Internet Gateway`) içerdiğinden emin olun.
  2. **Security List / NSG:** Subnet Security List'inde 80/TCP Ingress portunun ve OCI Health Check IP aralıklarının açık olduğunu kontrol edin.
  3. **CCM Logları:** Sorunu derinlemesine incelemek için kube-system içerisindeki cloud-controller-manager loglarını inceleyin:
     ```bash
     kubectl logs -n kube-system -l k8s-app=oci-cloud-controller-manager --tail=100
     ```

### 4. OCI VCN-Native CNI ve NetworkPolicy Uyumluluğu
- OKE kümeleri iki farklı CNI ile kurulabilir: **OCI VCN-Native CNI** veya **Flannel**.
- NetworkPolicy kurallarının Kubernetes kernel seviyesinde uygulanabilmesi için OKE cluster oluşturulurken NetworkPolicy eklentisinin (Calico / OCI Network Policy engine) aktif edilmiş olması gerekir. Eğer cluster NetworkPolicy desteklemiyorsa kurallar hata vermeden uygulanır fakat paketleri filtrelemez.

### 5. PDB ve Drain Kilitlenmesi (`Cannot evict pod: Disruption budget violated`)
- Eğer `minAvailable: 1` tanımlı bir deployment'ın tüm replikaları sağlıksız (Unready) duruma düşerse veya tek replika kalmışsa `kubectl drain` komutu sonsuz döngüde bekleyebilir.
- **Çözüm:** PDB tanımına `unhealthyPodEvictionPolicy: AlwaysAllow` eklenmiştir. Bu sayede zaten yanıt vermeyen pod'lar drenaj sürecini kilitlemez. Acil durumlarda `--disable-eviction=true` parametresi kullanılabilir.
