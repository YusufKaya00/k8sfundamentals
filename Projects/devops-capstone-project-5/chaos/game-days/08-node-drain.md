# Game Day 08 — Node Drain: Sunucu Bakımı ve `PodDisruptionBudget` Koruması

**Referans Doküman:** [`chaos/experiments/08-node-drain.md`](../experiments/08-node-drain.md)  
**Hedef Sunucu:** `vm-worker-app` (`10.30.1.6`)  
**Kaos Türü:** Manuel Operasyonel Kaos (`kubectl cordon` + `kubectl drain`)

---

## 1. Hipotez (Neyi Kanıtlıyoruz?)

> **Hipotez:** Operasyon ekibi kernel güncellemesi veya Azure VM bakımı için `vm-worker-app` sunucusunu boşaltmak (`kubectl drain`) istediğinde:
> 1. `order-api` için tanımlanan **`PodDisruptionBudget (minAvailable: 1)`** devreye girer.
> 2. İlk `order-api` pod'u tahliye edilir (evicted) ve yeni pod oluşturulur; ancak lab ortamında ikinci bir `tier=app` sunucusu olmadığı için (master ve data sunucuları `NoSchedule` taint'lidir) yeni pod **`Pending`** durumunda kalır.
> 3. Yeni pod `Ready` olamadığı için Kubernetes Disruption Controller **ikinci `order-api` pod'unun silinmesini kesin olarak reddeder (`Cannot evict pod as it would violate the pod's disruption budget`)** ve sistemin %100 kapanmasını önler!

**Neden Prod'da Önemli?**  
Üretim ortamındaki kesintilerin önemli bir kısmı dış saldırılardan değil, **rutin bakım işlemlerinden** (node drain, cluster upgrade) kaynaklanır. Eğer `PodDisruptionBudget (PDB)` tanımlamazsanız, `kubectl drain` komutu bir Deployment'ın tüm pod'larını aynı saniyede öldürür ve yeni pod'lar diğer sunucuda ayağa kalkana kadar (veya yer yoksa sonsuza kadar) servisiniz tamamen çöker!

---

## 2. Steady State (Normal Durum) Kontrolü — PromQL & CLI

Deney öncesi hem PromQL hem de `kubectl` ile durumu doğrulayın:

```promql
# 1) Hazır order-api pod sayısı == 2
count(kube_pod_status_ready{namespace="app", condition="true", pod=~"order-api-.*"}) == 2

# 2) Tüm node'lar Ready ve Schedulable durumda
sum(kube_node_spec_unschedulable) == 0
```

```bash
# PDB durumunu kontrol edin (ALLOWED DISRUPTIONS = 1 olmalı)
kubectl get pdb -n app
```

---

## 3. Blast Radius (Etki Yarıçapı) ve Güvenlik Korkulukları

- **Kapsam:** `vm-worker-app` üzerindeki tüm iş yükleri (`app`, `messaging`, `gitlab-runner`).
- **Korkuluk (Guardrail):** `PodDisruptionBudget` (`minAvailable: 1`).
- **Kritik Kural:** Asla `--disable-eviction` veya `--force` bayraklarını kullanmayın; bu bayraklar Eviction API'sini atlayıp doğrudan `DELETE pod` çağrısı yapar ve PDB korumasını devre dışı bırakır!

---

## 4. Abort (Acil Durdurma) Koşulları

1. Drain komutu PDB tarafından beklendiği üzere bloklandığında testi tamamlamak için.
2. Herhangi bir kritik servis beklenmedik şekilde tamamen durursa.

**Acil Durdurma / Geri Alma Komutu:**
```bash
# 1) Çalışan kubectl drain komutunu Ctrl+C ile durdurun
# 2) Sunucuyu tekrar zamanlamaya (scheduling) açın:
kubectl uncordon vm-worker-app
```

---

## 5. Adım Adım Çalıştırma Komutları

### Adım 1: Mevcut Pod Dağılımını ve PDB'yi Kaydedin (Terminal 1)
```bash
kubectl get nodes -o wide
kubectl get pods -n app -o wide
kubectl get pdb -n app
```

### Adım 2: Sunucuyu `cordon` ile Yeni Podlara Kapatın
```bash
kubectl cordon vm-worker-app
kubectl get nodes
# vm-worker-app artık "Ready,SchedulingDisabled" olarak görünmelidir.
```

### Adım 3: `drain` İşlemini Başlatın (60s Timeout ile)
```bash
kubectl drain vm-worker-app \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=60s
```

### Adım 4: Diğer Terminalden (Terminal 2) Olayları Gözlemleyin
Drain çalışırken ikinci bir terminalde şunları çalıştırın:
```bash
kubectl get pods -n app -o wide
kubectl get pdb -n app
kubectl get events -n app --sort-by=.lastTimestamp | tail -n 15
```

---

## 6. Beklenen Gözlem (Grafana, CLI & Alarmlar)

1. **`kubectl drain` Çıktısı:**
   - İlk `order-api` pod'u tahliye edilir (`evicting pod app/order-api-...`).
   - Yeni açılan pod `Pending` kalır (`0/3 nodes are available: 1 node(s) were unschedulable, 1 node(s) had untolerated taint {CriticalAddonsOnly: true}, 1 node(s) had untolerated taint {dedicated: data}`).
   - İkinci `order-api` pod'u için şu mesaj basılır:
     ```text
     error when evicting pods/"order-api-xxxx" -n "app" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
     ```
2. **`kubectl get pdb -n app` Çıktısı:**
   - `ALLOWED DISRUPTIONS` değeri `1`'den **`0`**'a düşer.
3. **Grafana — SLO Overview:**
   - Hayatta kalan 1 adet `order-api` pod'u trafiğin %100'ünü karşılamaya devam eder!

---

## 7. Toparlanma (Recovery) ve Temizlik

> [!WARNING]
> Bu adımı çalıştırmayı unutursanız `vm-worker-app` `SchedulingDisabled` kalır ve `Pending` olan pod'lar asla başlamaz!

```bash
# 1) Sunucuyu tekrar aktif et
kubectl uncordon vm-worker-app

# 2) Tüm node'ların Ready olduğunu (SchedulingDisabled olmadığını) doğrula
kubectl get nodes

# 3) Pending kalan podların hemen Running/Ready durumuna geçtiğini doğrula
kubectl get pods -n app -o wide
kubectl get pods -n messaging -o wide
```

---

## 8. Prod Notu (Neden Prod'da Böyle?)

Lab ortamımızda Azure for Students `6 vCPU` kotası nedeniyle uygulama katmanında tek bir VM (`vm-worker-app`) kullandık. Bu deney bize çok değerli iki prod dersi verir:
1. **PDB Tek Başına Yetmez, Yedek Kapasite (N+1 Node) Şarttır:** Prod'da `tier=app` havuzunda en az 3 sunucu (AZ-1, AZ-2, AZ-3) bulunur. `vm-worker-app-1` drain edildiğinde, tahliye edilen pod `vm-worker-app-2` üzerinde ayağa kalkar, `Ready` olur, `ALLOWED DISRUPTIONS` tekrar `1`'e çıkar ve drain işlemi takılmadan başarıyla tamamlanır.
2. **Cluster Autoscaler / Karpenter:** Eğer diğer sunucularda boş CPU/RAM yoksa, `Pending` kalan pod'u gören Cluster Autoscaler bulut sağlayıcıdan otomatik olarak yeni bir VM açar ve drain işleminin tamamlanmasını sağlar.
