**Çözümler — Modern Kubernetes Platform Laboratuvarı (Minikube)**

> Tüm komutlar `k8-project-2/` dizini içerisinden çalıştırılır (manifestolar `./yaml/` altındadır).
>
> Minikube varsayılan profilinde node isimleri: `minikube` (control-plane), `minikube-m02`, `minikube-m03`, `minikube-m04`, `minikube-m05` (worker).

***
**1:** 5 node'lu (1 Control-Plane + 4 Worker) bir Minikube cluster'ı kurun ve metric-server ile ingress eklentilerini aktif hale getirin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

NetworkPolicy'lerin (4. adım) gerçekten uygulanabilmesi için cluster, NetworkPolicy destekleyen bir CNI (Calico) ile kurulur. Minikube'un multi-node varsayılan CNI'ı (kindnet) NetworkPolicy uygulamaz.

```
$ minikube start --nodes=5 --cni=calico --cpus=2 --memory=2048 --driver=docker

$ minikube addons enable metrics-server

$ minikube addons enable ingress

$ kubectl label node minikube-m02 minikube-m03 minikube-m04 minikube-m05 node-role.kubernetes.io/worker=

$ kubectl get nodes -o wide

$ kubectl get pods -n ingress-nginx

$ kubectl get pods -n kube-system -l k8s-app=metrics-server

$ kubectl top nodes
```

`kubectl top nodes` komutunun metrik döndürmesi metrics-server açıldıktan sonra ~1 dakika sürebilir.
</details>

***
**2:** "staging" ve "production" adlarında 2 farklı namespace oluşturun.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

```
$ kubectl create namespace staging

$ kubectl create namespace production

$ kubectl get namespaces
```
</details>

***
**3:** Cluster'daki 2 worker node'u sadece "production" kritik iş yükleri için ayırın:
- Bu iki node'a "dedicated=production:NoSchedule" taint'i ekleyin.
- Aynı node'lara "environment=production" label'ı verin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Taint, toleration'ı olmayan pod'ların bu node'lara yerleşmesini engeller; label ise production pod'larının `nodeAffinity` ile **sadece** bu node'ları seçmesini sağlar. İkisi birlikte kullanıldığında node'lar production'a tamamen ayrılmış olur.

```
$ kubectl taint nodes minikube-m04 minikube-m05 dedicated=production:NoSchedule

$ kubectl label nodes minikube-m04 minikube-m05 environment=production

$ kubectl get nodes -L environment

$ kubectl describe node minikube-m04 | grep -i taints

$ kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```
</details>

***
**4:** Güvenlik katmanı: "staging" namespace'inde öyle bir NetworkPolicy oluşturun ki PostgreSQL pod'una yalnızca aynı namespace içerisindeki etiketli web uygulaması erişebilsin, dışarıdan veya diğer pod'lardan gelen erişimler engellensin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Policy `app=postgres` pod'unu seçer ve yalnızca aynı namespace'teki `app=web, db-access=true` etiketli pod'lardan 5432/TCP trafiğine izin verir. Policy tarafından seçilen bir pod'a, listelenmeyen tüm kaynaklardan gelen ingress trafiği otomatik olarak reddedilir.

```
$ kubectl apply -f ./yaml/network-policy.yaml

$ kubectl describe networkpolicy postgres-allow-web-only -n staging
```

Doğrulama (6. adımda stack deploy edildikten sonra):

```
# İZİN VERİLİR: etiketli web pod'u -> PostgreSQL ("db_reachable": true)
$ kubectl exec -n staging deploy/web -c web -- wget -qO- http://localhost:8080/db

# ENGELLENİR: aynı namespace'te etiketsiz bir pod ("no response")
$ kubectl run np-test -n staging --rm -it --restart=Never --image=postgres:16-alpine -- pg_isready -h postgres -p 5432 -t 5

# ENGELLENİR: farklı namespace'ten gelen istek ("no response")
$ kubectl run np-test -n default --rm -it --restart=Never --image=postgres:16-alpine -- pg_isready -h postgres.staging.svc.cluster.local -p 5432 -t 5
```
</details>

***
**5:** ConfigMap ve Secret ayrımı:
- Veritabanı kullanıcı adı ve şifresini içeren bir Secret ("postgres-creds") oluşturun.
- Uygulama ayarlarını (LOG_LEVEL, PORT, CACHE_ENABLED) tutan bir ConfigMap ("app-config") hazırlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Hassas bilgiler YAML dosyalarına yazılmaz; `postgres-secrets.txt` env-file'ından Secret üretilir. Hassas olmayan ayarlar ise ConfigMap'te tutulur.

```
$ kubectl create secret generic postgres-creds --from-env-file=./yaml/postgres-secrets.txt -n staging

$ kubectl create secret generic postgres-creds --from-env-file=./yaml/postgres-secrets.txt -n production

$ kubectl apply -f ./yaml/app-configmap.yaml

$ kubectl get secret postgres-creds -n production

$ kubectl get secret postgres-creds -n production -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo

$ kubectl describe configmap app-config -n staging

$ kubectl describe configmap app-config -n production
```
</details>

***
**6:** Init-Container destekli Web + PostgreSQL Stack:
- "production" ve "staging" namespace'lerinde PostgreSQL 16 veritabanını PVC ile deploy edin.
- Web uygulamasının (ör: Python/Node.js REST API) pod tanımına bir Init-Container ekleyin; bu init container veritabanı portu (5432) dinlemeye başlayana kadar (netcat / pg_isready ile) ana web container'ının başlamasını bekletsin.
- "production" pod'ları 3. adımdaki taint'e uygun toleration ve nodeAffinity ile işaretlenmiş node'larda çalışsın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Web uygulaması, kodu ConfigMap'ten mount edilen ve sadece Python standart kütüphanesini kullanan bir REST API'dir (`/`, `/healthz`, `/db`, `/burn`). `wait-for-postgres` init container'ı `pg_isready` başarılı olana kadar ana container'ı bekletir. Production manifestosundaki tüm pod'lar `dedicated=production:NoSchedule` toleration'ı ve `environment=production` nodeAffinity'si taşır.

```
$ kubectl apply -f ./yaml/staging-stack.yaml

$ kubectl apply -f ./yaml/prod-stack.yaml

$ kubectl get pods -n production -w

$ kubectl get pods -n staging -o wide

$ kubectl get pods -n production -o wide

$ kubectl get pvc -n staging

$ kubectl get pvc -n production

$ kubectl logs -n production deploy/web -c wait-for-postgres

$ kubectl exec -n production deploy/web -c web -- wget -qO- http://localhost:8080/
```

Production pod'larının `NODE` sütununda yalnızca `minikube-m04` ve `minikube-m05` görülmelidir.

Init-Container davranışını gözlemlemek için (staging):

```
$ kubectl scale deployment postgres -n staging --replicas=0

$ kubectl rollout restart deployment web -n staging

$ kubectl get pods -n staging -l app=web

$ kubectl logs -n staging -l app=web -c wait-for-postgres -f

$ kubectl scale deployment postgres -n staging --replicas=1

$ kubectl get pods -n staging -l app=web -w
```

Web pod'u `Init:0/1` durumunda bekler, PostgreSQL hazır olduğunda `Running` durumuna geçer.

Yedekleme adımında (8. adım) anlamlı bir dump alınabilmesi için production veritabanına örnek veri eklenir:

```
$ kubectl exec -n production deploy/postgres -- psql -U labadmin -d appdb -c "CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, item TEXT NOT NULL, created_at TIMESTAMPTZ DEFAULT now());"

$ kubectl exec -n production deploy/postgres -- psql -U labadmin -d appdb -c "INSERT INTO orders (item) VALUES ('kubernetes-kitabi'), ('minikube-kupa');"

$ kubectl exec -n production deploy/postgres -- psql -U labadmin -d appdb -c "SELECT * FROM orders;"
```
</details>

***
**7:** Ingress ile Path ve Host Tabanlı Yönlendirme:
- "staging" ortamı için "staging.lab.internal" hostu,
- "production" ortamı için "api.lab.internal" hostu ve "/metrics" yolu için farklı bir backend servisine yönlenen güncel "networking.k8s.io/v1" Ingress kuralı tanımlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Ingress nesneleri yalnızca kendi namespace'lerindeki servislere yönlendirme yapabildiğinden her ortam için ayrı bir Ingress tanımlanmıştır. Production'da `/metrics` yolu `postgres-exporter` servisine, diğer tüm yollar `web` servisine gider.

```
$ kubectl apply -f ./yaml/app-ingress.yaml

$ kubectl get ingress -A

$ kubectl describe ingress api-ingress -n production

$ echo "$(minikube ip) staging.lab.internal api.lab.internal" | sudo tee -a /etc/hosts

$ curl http://staging.lab.internal/

$ curl http://api.lab.internal/

$ curl -s http://api.lab.internal/metrics | grep -E "^pg_up"
```

`/etc/hosts` dosyasını değiştirmeden test etmek için:

```
$ curl --resolve "api.lab.internal:80:$(minikube ip)" http://api.lab.internal/

$ curl -s --resolve "api.lab.internal:80:$(minikube ip)" http://api.lab.internal/metrics | grep -E "^pg_up"

$ curl --resolve "staging.lab.internal:80:$(minikube ip)" http://staging.lab.internal/
```

macOS/Windows üzerinde docker driver kullanılıyorsa ayrı bir terminalde `minikube tunnel` çalıştırılıp `/etc/hosts` kaydında `127.0.0.1` kullanılmalıdır.
</details>

***
**8:** Veritabanı Yedekleme CronJob'u (Batch Processing):
- Her gece 02:00'de (test için elle tetiklenebilir biçimde) çalışıp veritabanından dump alıp shared bir PVC'ye yazan veya stdout'a başarılı log üreten bir CronJob ("db-backup-job") tanımlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

`batch/v1` CronJob her gece 02:00'de (`timeZone: Europe/Istanbul`) çalışır, `pg_dump` çıktısını gzip'leyerek `db-backup-pvc` PVC'sine yazar, dosya bütünlüğünü `gzip -t` ile doğrular, 7 günden eski yedekleri siler ve stdout'a `SUCCESS` logu basar.

```
$ kubectl apply -f ./yaml/db-backup-cronjob.yaml

$ kubectl get cronjob db-backup-job -n production

$ kubectl get pvc db-backup-pvc -n production

$ kubectl create job db-backup-manual-1 --from=cronjob/db-backup-job -n production

$ kubectl wait --for=condition=complete job/db-backup-manual-1 -n production --timeout=180s

$ kubectl logs -n production job/db-backup-manual-1

$ kubectl get jobs -n production
```

Beklenen log çıktısı:

```
[db-backup] 2026-10-07T02:00:01+03:00 yedekleme basladi -> postgres:5432/appdb
postgres:5432 - accepting connections
[db-backup] SUCCESS: /backup/appdb-20261007-020001.sql.gz olusturuldu (4.0K)
[db-backup] Mevcut yedekler:
...
```
</details>

***
**9:** Horizontal Pod Autoscaler (HPA) ve Pod Disruption Budget (PDB):
- Production web deployment'ı için CPU kullanımı %60'ı aştığında pod sayısını min 2, max 8 yapacak bir HPA tanımlayın.
- Bakım anlarında en az 1 pod'un daima ayakta kalmasını garanti eden PodDisruptionBudget (PDB) kuralı uygulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

```
$ kubectl apply -f ./yaml/autoscale-hpa.yaml

$ kubectl apply -f ./yaml/app-pdb.yaml

$ kubectl get hpa web-hpa -n production

$ kubectl get pdb web-pdb -n production

$ kubectl top pods -n production
```

Yük testi (`/burn` endpoint'i CPU yoğun bir hesaplama yapar):

```
$ kubectl run load-generator -n production --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://web/burn > /dev/null; done"

$ kubectl get hpa web-hpa -n production -w

$ kubectl get pods -n production -l app=web -o wide

$ kubectl delete pod load-generator -n production

$ kubectl get hpa web-hpa -n production -w
```

CPU kullanımı %60'ı aştığında replika sayısı artar (en fazla 8); yük kalktıktan sonra `scaleDown` stabilizasyon süresinin ardından tekrar 2'ye iner. Tüm yeni pod'lar yine yalnızca production node'larına yerleşir.
</details>

***
**10:** Cluster-Wide Log DaemonSet:
- Node'ların "/var/log" dizinini hostPath ile mount eden ve production taint'ini tolere ederek tüm worker'larda çalışan bir "fluent-bit" DaemonSet'i yapılandırın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

DaemonSet `dedicated=production:NoSchedule` taint'ini tolere eder ve `node-role.kubernetes.io/control-plane DoesNotExist` nodeAffinity'si ile yalnızca 4 worker node'da çalışır. `/var/log` salt-okunur hostPath olarak mount edilir; loglar Kubernetes metadata'sı ile zenginleştirilip stdout'a yazılır.

```
$ kubectl apply -f ./yaml/daemonset.yaml

$ kubectl get daemonset fluent-bit -n logging

$ kubectl get pods -n logging -o wide

$ kubectl logs -n logging -l app=fluent-bit --tail=5

$ kubectl exec -n logging ds/fluent-bit -- ls /var/log/containers
```

`DESIRED/READY` değeri `4` olmalı ve pod'lar `minikube-m02` ... `minikube-m05` node'larında (production node'ları dahil) çalışmalıdır.
</details>

***
**11:** StatefulSet ile 2 Replikalı Redis Cluster / Replica:
- "volumeClaimTemplates" kullanan, headless service arkasında stabil network kimliğine sahip 2 replikalı bir Redis StatefulSet'i deploy edin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

`redis-0` master, `redis-1` replica olarak başlar. Her pod `volumeClaimTemplates` ile kendi PVC'sine (`data-redis-0`, `data-redis-1`) ve `redis-headless` servisi sayesinde stabil bir DNS kimliğine sahiptir. Her pod'da ayrıca bir Sentinel sidecar'ı çalışır.

```
$ kubectl apply -f ./yaml/redis-sentinel-statefulset.yaml

$ kubectl get statefulset redis -n staging

$ kubectl get pods -n staging -l app=redis -o wide

$ kubectl get pvc -n staging -l app=redis

$ kubectl logs -n staging redis-0 -c config-init

$ kubectl logs -n staging redis-1 -c config-init

$ kubectl exec -n staging redis-0 -c redis -- redis-cli info replication

$ kubectl exec -n staging redis-0 -c redis -- redis-cli set lab:mesaj "merhaba-k8s"

$ kubectl exec -n staging redis-1 -c redis -- redis-cli get lab:mesaj

$ kubectl exec -n staging redis-1 -c redis -- redis-cli set lab:yaz "deneme"

$ kubectl exec -n staging redis-0 -c sentinel -- redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

$ kubectl run dns-test -n staging --rm -it --restart=Never --image=busybox:1.36 -- nslookup redis-headless.staging.svc.cluster.local
```

`redis-1` üzerinde yazma denemesi `READONLY You can't write against a read only replica.` hatası verir.

Stabil kimlik ve kalıcı depolama doğrulaması:

```
$ kubectl delete pod redis-1 -n staging

$ kubectl get pods -n staging -l app=redis -w

$ kubectl exec -n staging redis-1 -c redis -- redis-cli get lab:mesaj
```

Yeniden oluşan pod aynı isimle (`redis-1`), aynı PVC'ye (`data-redis-1`) bağlanır ve replika rolüne geri döner.
</details>

***
**12:** In-Cluster API İstemcisi ve ServiceAccount:
- Sadece bulunduğu namespace içerisindeki Job ve Pod nesnelerini listeleyebilen ("get", "list") bir ServiceAccount ve Role/RoleBinding oluşturun.
- Bu ServiceAccount'ı kullanan bir curl pod'u üzerinden cluster API'sine (/api/v1/namespaces/{ns}/pods) HTTPS isteği atarak çalışan pod listesini JSON olarak çekin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

```
$ kubectl apply -f ./yaml/k8s-api-debug.yaml

$ kubectl get serviceaccount,role,rolebinding -n production -l app=api-client

$ kubectl auth can-i list pods -n production --as=system:serviceaccount:production:api-reader

$ kubectl auth can-i get jobs.batch -n production --as=system:serviceaccount:production:api-reader

$ kubectl auth can-i delete pods -n production --as=system:serviceaccount:production:api-reader

$ kubectl auth can-i list pods -n staging --as=system:serviceaccount:production:api-reader

$ kubectl wait --for=condition=Ready pod/api-client -n production --timeout=120s

$ kubectl logs -n production api-client
```

İlk iki `can-i` sorgusu `yes`, son ikisi `no` döner.

Pod içinden HTTPS ile API sorgusu (pod listesi JSON):

```
$ kubectl exec -n production api-client -- sh -c 'SA=/var/run/secrets/kubernetes.io/serviceaccount; curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" https://kubernetes.default.svc/api/v1/namespaces/production/pods'
```

Job listesi:

```
$ kubectl exec -n production api-client -- sh -c 'SA=/var/run/secrets/kubernetes.io/serviceaccount; curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" https://kubernetes.default.svc/apis/batch/v1/namespaces/production/jobs'
```

Yetki dışı istek (başka namespace) `403 Forbidden` döner:

```
$ kubectl exec -n production api-client -- sh -c 'SA=/var/run/secrets/kubernetes.io/serviceaccount; curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" https://kubernetes.default.svc/api/v1/namespaces/staging/pods'
```
</details>

***
**13:** Planlı Bakım ve Güvenli Drenaj (Maintenance):
- Üzerinde pod çalışan bir worker node'u drain ederek mevcut pod'ların PDB kurallarına uygun şekilde diğer node'lara taşınmasını sağlayın. Node'u cordon ve uncordon döngüsüyle doğrulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Production web pod'ları `podAntiAffinity` sayesinde `minikube-m04` ve `minikube-m05` arasında dağılmıştır. `minikube-m04` drain edildiğinde pod'lar, toleration/nodeAffinity kurallarına uyan tek diğer node olan `minikube-m05`'e taşınır. `web-pdb` (minAvailable: 1) tahliye sırasında en az bir web pod'unun daima ayakta kalmasını garanti eder; gerekirse drain, PDB izin verene kadar tahliyeyi bekletir.

```
$ kubectl get pods -n production -o wide

$ kubectl cordon minikube-m04

$ kubectl get nodes

$ kubectl drain minikube-m04 --ignore-daemonsets --delete-emptydir-data --timeout=300s

$ kubectl get pods -n production -o wide

$ kubectl get pdb web-pdb -n production

$ kubectl get pods -A -o wide --field-selector spec.nodeName=minikube-m04

$ kubectl uncordon minikube-m04

$ kubectl get nodes

$ kubectl rollout restart deployment web -n production

$ kubectl get pods -n production -l app=web -o wide
```

- `cordon` sonrası `kubectl get nodes` çıktısında node `Ready,SchedulingDisabled` görünür.
- Drain sırasında `Cannot evict pod as it would violate the pod's disruption budget` mesajı görülebilir; bu, PDB'nin çalıştığını gösterir ve drain yeni pod hazır olduğunda devam eder.
- Drain sonrası node üzerinde yalnızca DaemonSet pod'ları (fluent-bit, calico-node, kube-proxy) kalır.
- `uncordon` sonrası node tekrar `Ready` olur; `rollout restart` ile web pod'ları iki production node'a yeniden dağıtılır.

> **Not:** Minikube'un `standard` StorageClass'ı (hostpath-provisioner) veriyi node'un yerel diskinde tutar. PostgreSQL pod'u başka bir node'a taşındığında farklı bir dizinle başlar. Gerçek ortamlarda node'dan bağımsız (ağ tabanlı / CSI) depolama kullanılmalıdır.
</details>

***
**Temizlik**
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

```
$ minikube delete
```
</details>
