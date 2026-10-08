**Çözümler — OCI OKE Production Kubernetes Laboratuvarı**

> Komutlar `k8-project-3/solution/` dizini içerisinden çalıştırılabilir.
> Küme: 3 Worker Node (VM.Standard.E5.Flex, Oracle Linux 9, k8s v1.37.0)

***
**1:** 3 worker node'lu OKE cluster'ındaki node'ları listeleyin. 3. node'a `workload=database:NoSchedule` taint'i ve `tier=database` label'ı, diğer 2 worker node'a `tier=web` label'ı atayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Taint, toleration taşımayan pod'ların DB node'una yerleşmesini engeller. Label ise `nodeSelector` ile iş yüklerinin ilgili node'lara çekilmesini sağlar.

```bash
$ kubectl get nodes -o wide

$ NODE1=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
$ NODE2=$(kubectl get nodes -o jsonpath='{.items[1].metadata.name}')
$ NODE3=$(kubectl get nodes -o jsonpath='{.items[2].metadata.name}')

$ kubectl taint nodes "$NODE3" workload=database:NoSchedule --overwrite
$ kubectl label nodes "$NODE3" tier=database --overwrite

$ kubectl label nodes "$NODE1" "$NODE2" tier=web --overwrite

# Doğrulama:
$ kubectl get nodes -L tier
$ kubectl describe node "$NODE3" | grep -i taints
```
</details>

***
**2:** "production" namespace'i oluşturun ve CPU, bellek, pod ve storage kotalarını belirleyen ResourceQuota ile varsayılan limitleri atayan LimitRange tanımlarını uygulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

ResourceQuota ve LimitRange ile kontrolsüz kaynak tüketimi ve limit belirtilmeyen pod'ların küme kaynaklarını tüketmesi engellenir.

```bash
$ kubectl apply -f ./02-namespaces-and-quotas.yaml

# Doğrulama:
$ kubectl get ns production
$ kubectl describe quota -n production
$ kubectl describe limitrange -n production
```
</details>

***
**3:** Dedicated Node Scheduling: Database iş yüklerinin 3. node'a, web iş yüklerinin web node'larına gitmesini sağlayacak taint/toleration ve nodeSelector stratejisini doğrulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Toleration içermeyen geçici bir test pod'u DB node'una zorlandığında scheduling aşamasında bekletilmelidir (Pending).

```bash
# Negatif test (Toleration olmadan DB node'una gitmeye çalışan pod):
$ kubectl run taint-test -n production --image=busybox:1.36 --overrides='{"spec": {"nodeSelector": {"tier": "database"}}}' --restart=Never -- sleep 30

$ kubectl get pod taint-test -n production
$ kubectl describe pod taint-test -n production | grep -i "untolerated taint"

# Test pod'unu temizle:
$ kubectl delete pod taint-test -n production --force --grace-period=0
```
</details>

***
**4:** Veritabanı kimlik bilgilerini tutan bir Secret ("postgres-secret") ve uygulama ayarlarını tutan bir ConfigMap ("app-config") oluşturun.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

12-Factor App kuralı: Hassas bilgiler Secret'ta, genel çalışma zamanı ayarları ConfigMap'te tutulur.

```bash
$ kubectl apply -f ./04-config-and-secret.yaml

# Doğrulama:
$ kubectl get secret postgres-secret -n production
$ kubectl get secret postgres-secret -n production -o jsonpath='{.data.POSTGRES_USER}' | base64 -d; echo
$ kubectl describe configmap app-config -n production
```
</details>

***
**5:** "production" namespace'inde OCI Block Volume (`storageClassName: oci-bv`) kullanan 50Gi PVC ile PostgreSQL 16 veritabanını deploy edin. 3. node'a yerleşecek toleration ve nodeSelector tanımlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

OCI Block Volume CSI (`oci-bv`) minimum 50Gi blok hacmi sağlar. `Recreate` stratejisi ile diskin aynı anda iki pod'a takılmaya çalışması (Multi-Attach) önlenir.

```bash
$ kubectl apply -f ./05-postgres-pvc-deployment.yaml

# Doğrulama:
$ kubectl get pvc -n production
$ kubectl get pods -n production -l app=postgres -o wide
$ kubectl exec -n production deploy/postgres -c postgres -- pg_isready -U okeadmin -d productiondb
```
</details>

***
**6 & 7:** Yüksek erişilebilirlikli Web API Deployment'ı oluşturun:
- 2 replikanın 2 ayrı web node'una dengeli dağılması için `podAntiAffinity` ve `topologySpreadConstraints` (maxSkew: 1) içersin.
- Veritabanı portu (5432) dinlemeye başlayana kadar bekleyen bir Init-Container içersin.
- `startupProbe`, `readinessProbe`, `livenessProbe` ve connection drain için `lifecycle.preStop` (`sleep 10`) tanımlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

- `wait-for-postgres` init-container veritabanı portunu `nc` ile yoklayıp hazır olana kadar ana container'ı bekletir.
- `topologySpreadConstraints` ile 2 pod 2 ayrı web node'una eşit (1-1) dağıtılır.
- `preStop: sleep 10` ile pod kapanırken Load Balancer'ın pod'u listeden çıkarması için zaman tanınır (zero-downtime draining).

```bash
$ kubectl apply -f ./06-07-web-deployment.yaml

# Doğrulama:
$ kubectl get pods -n production -l app=web-api -o wide
$ kubectl logs -n production -l app=web-api -c wait-for-postgres --tail=10
$ kubectl exec -n production deploy/web-api -c web-api -- wget -qO- http://localhost:8080/
```
</details>

***
**8:** Güvenlik katmanı: PostgreSQL pod'una yalnızca aynı namespace'teki `app: web-api` etiketli pod'ların erişmesine izin veren bir NetworkPolicy tanımlayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Default-deny Ingress: `app: postgres` pod'una gelen tüm trafik engellenir, sadece `app: web-api` etiketli pod'ların 5432 portuna erişimine izin verilir.

```bash
$ kubectl apply -f ./08-network-policy.yaml

# Doğrulama:
$ kubectl describe networkpolicy postgres-network-policy -n production

# İzin verilen erişim (Web pod'undan test):
$ kubectl exec -n production deploy/web-api -c web-api -- nc -z -v postgres 5432

# Engellenen erişim (Etiketsiz yabancı pod'dan doğrudan test):
$ kubectl run test-netpol -n production --rm -it --restart=Never --image=busybox:1.36 -- nc -z -w 3 postgres 5432
# (Zaman aşımına uğramalı, bağlantı kurulamaz)
```
</details>

***
**9:** Web API'yi dış dünyaya açmak için OCI Flexible Load Balancer anotasyonlarını (`flexible`, min: 10, max: 40 Mbps) içeren bir LoadBalancer servisi oluşturun.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

OCI CCM (Cloud Controller Manager) otomatik olarak esnek OCI Load Balancer provizyon eder.

```bash
$ kubectl apply -f ./09-web-loadbalancer-service.yaml

# External IP alma durumunu izleyin (OCI LB ayağa kalkınca IP atanır):
$ kubectl get svc web-api-lb -n production -w

# Dış dünya testi:
$ LB_IP=$(kubectl get svc web-api-lb -n production -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
$ curl -I "http://${LB_IP}/"
```
</details>

***
**10:** Headless service arkasında her pod'a bağımsız 10Gi `oci-bv` PVC bağlayan `volumeClaimTemplates` yapısına sahip 2 replikalı bir Redis StatefulSet deploy edin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Headless service (`clusterIP: None`) ile pod'lar stabil DNS adları alır (`redis-0.redis-headless...`). Her pod `volumeClaimTemplates` ile bağımsız 10Gi OCI Block Volume diski kullanır.

```bash
$ kubectl apply -f ./10-redis-statefulset.yaml

# Doğrulama:
$ kubectl get statefulset,pods,pvc -n production -l app=redis -o wide

# Veri yazma ve okuma testi:
$ kubectl exec -n production redis-0 -c redis -- redis-cli set oke:test "aktif"
$ kubectl exec -n production redis-0 -c redis -- redis-cli get oke:test

# Pod yeniden başlasa da verinin korunduğunu doğrulama:
$ kubectl delete pod redis-0 -n production
$ kubectl wait --for=condition=Ready pod/redis-0 -n production --timeout=120s
$ kubectl exec -n production redis-0 -c redis -- redis-cli get oke:test
```
</details>

***
**11:** Web API için CPU kullanımı %60'ı aştığında pod sayısını min 2, max 8 yapacak bir HPA ve bakım anında en az 1 pod'un ayakta kalmasını garanti eden PDB (`minAvailable: 1`) kuralı uygulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

```bash
$ kubectl apply -f ./11-hpa-and-pdb.yaml

# Doğrulama:
$ kubectl get hpa,pdb -n production

# Yük testi simülasyonu:
$ kubectl run load-generator -n production --image=busybox:1.36 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://web-api-lb > /dev/null; done"

$ kubectl get hpa web-api-hpa -n production -w

$ kubectl delete pod load-generator -n production
```
</details>

***
**12:** Yalnızca `production` namespace'indeki `pods` ve `events` kaynaklarını get/list edebilen bir ServiceAccount, Role ve RoleBinding oluşturun. Curl pod'u üzerinden cluster API'sine istek atarak pod listesini çekin.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

En az yetki prensibi (Least Privilege): ServiceAccount sadece pod ve event listeleyebilir, secret okuyamaz veya kaynak silemez.

```bash
$ kubectl apply -f ./12-rbac-and-client-pod.yaml

# Yetki kontrolleri:
$ kubectl auth can-i list pods -n production --as=system:serviceaccount:production:api-client-sa
# (yes)
$ kubectl auth can-i get secrets -n production --as=system:serviceaccount:production:api-client-sa
# (no)

# Pod içerisinden API sorgusu:
$ kubectl exec -n production api-client-pod -c curl -- sh -c '
  SA=/var/run/secrets/kubernetes.io/serviceaccount
  curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $(cat $SA/token)" https://kubernetes.default.svc/api/v1/namespaces/production/pods | head -n 30
'
```
</details>

***
**13:** Planlı Bakım ve Güvenli Drenaj (Maintenance): Web pod'unun çalıştığı worker node'u tespit edin, `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` ile pod'ların PDB kurallarına uygun şekilde diğer node'a taşınmasını sağlayın. Node'u `cordon` ve `uncordon` döngüsüyle doğrulayın.
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

Web pod'ları 2 web node'una dağılmıştır. Biri drain edildiğinde PDB (`minAvailable: 1`) servis kesintisini engeller ve pod diğer web node'una taşınır.

```bash
# 1. Web pod'larının çalıştığı node'ları listeleyin:
$ kubectl get pods -n production -l app=web-api -o wide

# 2. Drene edilecek node'u seçin:
$ TARGET_NODE=$(kubectl get pods -n production -l app=web-api -o jsonpath='{.items[0].spec.nodeName}')
$ echo "Drene edilecek node: $TARGET_NODE"

# 3. Node'u çizelgelemeye kapatın ve boşaltın:
$ kubectl cordon "$TARGET_NODE"
$ kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s

# 4. Pod'ların diğer node'a geçtiğini ve ayakta kaldığını doğrulayın:
$ kubectl get pods -n production -l app=web-api -o wide
$ kubectl get pdb web-api-pdb -n production

# 5. Bakım bitti, node'u tekrar açın:
$ kubectl uncordon "$TARGET_NODE"
$ kubectl get nodes

# 6. Pod'ları tekrar 2 node'a yaymak için rollout restart:
$ kubectl rollout restart deployment web-api -n production
$ kubectl get pods -n production -l app=web-api -o wide
```
</details>

***
**OCI Troubleshooting & Üretim İpuçları**
<details>
  <summary>Çözümü görmek için tıklayınız!</summary>

1. **OCI Block Volume Multi-Attach Hatası:**
   - Hata: `Multi-Attach error for volume ... volume is already exclusively attached to one node`.
   - Çözüm: Block Volume'lar RWO disklerdir. Deployment tanımlarında `strategy.type: Recreate` kullanılmalıdır.

2. **OCI 50Gi Minimum Disk Boyutu:**
   - Hata: `The volume size must be at least 50 GB`.
   - Çözüm: OCI Block Volume servisinde minimum disk boyutu 50Gi'dir. PVC'lerde 50Gi altı talep edildiğinde CSI driver hata verebilir veya otomatik 50Gi'ye yuvarlayabilir.

3. **OCI Load Balancer Pending Durumu:**
   - Belirti: External IP sürekli `<pending>` kalıyor.
   - Çözüm: Subnet'in Public Subnet olduğundan, `0.0.0.0/0 -> Internet Gateway` route kuralı bulunduğundan ve Security List'te 80 portunun açık olduğundan emin olun.

4. **NetworkPolicy ve OKE CNI Uyumluluğu:**
   - OKE kümesinde NetworkPolicy'nin aktif çalışması için cluster kurulumunda Calico veya OCI NetworkPolicy eklentisinin açık olması gerekir.
</details>
