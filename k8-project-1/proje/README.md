# 🏗️ Lab 1: Core Kubernetes Primitives & Microservice Deployment

This project guides you through foundational Kubernetes operations: cluster bootstrapping, namespace isolation, RBAC role assignments, Ingress setup, node taints & tolerations, multi-tier stateful workloads, rolling updates, DaemonSets, and StatefulSets.

> **Solutions / Çözümler:** Detailed solutions with YAML references are in [cozum/README.md](./cozum/README.md).

---

## 📋 English Instructions

**1:** Set up a 5-node Kubernetes cluster (1 Master + 4 Worker Nodes).

**2:** Create two namespaces: `test` and `production`.

**3:** Configure RBAC:
- Create roles and bindings for the `junior` group granting full CRUD permissions (`read, list, create, delete, ...`) in `test`, but strictly read-only (`read, list`) in `production`.
- Create roles and bindings for the `senior` group granting full CRUD permissions in both `production` and `test`, plus cluster-wide read-only access on remaining cluster resources.

**4:** Install an Ingress Controller of your choice (e.g., Ingress-Nginx, Traefik, or HAProxy).

**5:** Dedicate 3 worker nodes exclusively for `production` workloads. Ensure non-production pods cannot be scheduled onto these nodes.

**6:** Deploy the WordPress stack across both `test` and `production` namespaces (`wordpress:latest` and `mysql:5.6`):
- Expose MySQL internally via a `ClusterIP` Service.
- Store persistent data on PersistentVolumes.
- Keep all sensitive credentials (passwords) out of plain manifests by using Kubernetes Secrets.
- Ensure WordPress and MySQL for the same environment are co-located on the same worker node.
- Define CPU and Memory resource requests and limits for both workloads.

**7:** Expose WordPress via Ingress:
- Route `testblog.example.com` to the WordPress service in `test`.
- Route `companyblog.example.com` to the WordPress service in `production`.

**8:** In `production`, deploy `ozgurozturknet/k8s:v1` with 5 replicas, a rolling update strategy allowing 2 pods to update concurrently (`maxSurge: 2`), a `livenessProbe` checking `/healthcheck`, and a `readinessProbe` checking `/ready`.

**9:** Expose the deployment from Step 8 externally using a `LoadBalancer` Service.

**10:** Scale the deployment to 3 replicas, then scale up to 10 replicas, and perform a rolling update to image `ozgurozturknet/k8s:v2`.

**11:** Deploy `fluentd` as a cluster-wide `DaemonSet`.

**12:** Deploy a 2-node `mongodb` cluster using a `StatefulSet` and verify replica set initialization.

**13:** Create a `ServiceAccount` with cluster-wide read permissions. Run a curl pod associated with this ServiceAccount and list all pods in the cluster via the API.

**14:** Gracefully drain all pods from one worker node and cordon it to prevent new pod scheduling.

---

## 🇹🇷 Türkçe Dokümantasyon / Turkish Version

**Proje Talimatları**

**1:** 5 node'lu "1 Master + 4 Worker Node" bir Kubernetes cluster kurun. 

**2:** "test" ve "production" adlarında 2 namespace oluşturun.

**3:** "junior" isimli grubun "test" namespace'inde tüm kaynaklar üstünde "okuma, listeleme, yaratma..." gibi tüm haklara, "production" namespace'inde ise tüm kaynaklar üstünde sadece "okuma ve listeleme" haklarına sahip olacağı rol oluşturup bunları grupla ilişkilendirin. Aynı şekilde "senior" isimli grubun "production" ve "test" namespace'lerindeki tüm kaynaklar üstünde "okuma, listeleme, yaratma..." gibi tüm haklara ve cluster üstündeki diğer kaynaklar üstünde ise sadece "okuma ve listeleme" haklarına sahip olacağı rol oluşturup bunları grupla ilişkilendirin.

**4:** Sizin seçeceğiniz bir "ingress controller" kurun. (nginx, traefik, haproxy vb.)

**5:** Cluster'da seçeceğiniz 3 worker node sadece "production" ortamında deploy edeceğiniz ve cluster tarafından oluşturulan podlar schedule edilebilsin. Bunun dışındaki podların bu worker node üstünde oluşturulmamasını sağlayın. 

**6:** Wordpress uygulamasını hem "test" hem de "production" namespace'lerinde deploy edin. (wordpress:latest ve mysql:5.6 imajlarından oluşturulacak)

- mysql "ClusterIp" tipi bir servisle cluster içinden erişilebilir olacak. 
- Her iki uygulamanın da uzun dönem verilerini "persistent volume"ler üzerinde saklanacak.
- Her iki uygulamanın da hiç bir hassas bilgisi "ör: şifre" uygulama ya da yaml dosyaları içerisinde tutulmayacak. 
- Her iki uygulama da aynı worker node üstünde schedule edilecek.
- Her iki uygulama için de cpu ve memory kaynak kısıtları tanımlı olacak.  

**7:** "test" namespace'inde deploy edilen wordpress uygulaması "testblog.example.com", "production" namespace'inde deploy edilen wordpress uygulaması "companyblog.example.com" olarak ingress üstünden dış dünyaya expose edilecek. 

**8:** "production" namespace'inde "ozgurozturknet/k8s:v1" imajından, 5 replikalı, update stratejisi olarak aynı anda 2 pod'un update edilebileceği bir deployment oluşturun. "/healthcheck" endpoint'ini sorgulayan "liveness probe" ve "/ready" endpoint'ini sorgulayan bir "readiness probe" tanımları da olsun. 

**9:** Bir önceki görevde oluşturduğunuz deployment'i "loadbalancer" tipi bir servisle dış dünyadan erişilebilir hale getirin. 

**10:** Bu deployment'i önce 3 replikaya indirin. Ardından 10 replikaya çıkarın. Sonrasında bu deployment'i "ozgurozturknet/k8s:v2" imajıyla güncelleyin.

**11:** "fluentd" uygulamasını bir "daemonset" olarak cluster'da deploy edin. 

**12:** 2 node'lu bir "mongodb" cluster'i "statefulset" olarak cluster'da deploy edin. "mongodb" cluster'ın çalıştığından emin olun. 

**13:** Cluster'da tüm objeler üstünde "okuma ve listeleme" haklarına sahip bir "service account" oluşturun. Bu service account’u bağladığınız bir pod oluşturun ve bağlanarak "curl" ile cluster’daki tüm podları listeleyin. 

**14:** Worker node'lardan bir tanesinin üzerindeki tüm podları tahliye edin ve ardından yeni pod schedule edilememesini sağlayın. 