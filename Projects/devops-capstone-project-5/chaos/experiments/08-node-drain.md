# Deney 08 — Node Drain (Manuel Bakım Senaryosu)

Chaos Mesh'in node seviyesinde "drain" CRD'si yoktur; prod'daki gerçek bakım (kernel yaması, VM resize) zaten `kubectl drain` ile yapılır. Bu yüzden bu deney **manueldir**.

**Hipotez:** `vm-worker-app` drain edildiğinde PDB'ler sayesinde order-api'nin en az 1 replica'sı ayakta kalır... ancak lab'da tek app node'u olduğu için pod'lar **gidecek yer bulamaz** (master taint'li, data node taint'li). Beklenen: PDB drain'i bloklar → bu, "tek node = tek arıza noktası" dersidir.

## Adımlar

```bash
# 0) Steady state kaydı
kubectl get pods -n app -o wide
kubectl get pdb -n app

# 1) Node'u schedule dışı bırak (yeni pod gelmesin)
kubectl cordon vm-worker-app

# 2) Drain — DaemonSet'leri atla, emptyDir verisini silmeye izin ver, 120 sn timeout
kubectl drain vm-worker-app --ignore-daemonsets --delete-emptydir-data --timeout=120s
#    Beklenen: "Cannot evict pod as it would violate the pod's disruption budget" mesajı
#    (PDB minAvailable=1 ve pod'ların taşınacağı başka node yok)

# 3) Gözlem (ayrı terminal)
kubectl get events -A --sort-by=.lastTimestamp | tail -20
kubectl get pods -A -o wide --field-selector spec.nodeName=vm-worker-app

# 4) Toparlanma — HER ZAMAN çalıştır
kubectl uncordon vm-worker-app
kubectl get nodes
```

## Abort
Drain takılı kalırsa `Ctrl+C` → `kubectl uncordon vm-worker-app`. Asla `--force --disable-eviction` kullanma (PDB'yi atlar, kesinti yaratır).

## Prod notu
Prod'da her tier için en az 2 node ve farklı zone'larda `topologySpreadConstraints` olur; drain PDB'yi ihlal etmeden pod'ları diğer node'a taşır. Cluster Autoscaler gerekirse yeni node açar.

Game day: [08-node-drain.md](../game-days/08-node-drain.md)
