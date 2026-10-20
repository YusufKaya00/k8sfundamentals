# 🏗️ Lab 1: Core Kubernetes Primitives & Microservice Deployment

This lab covers fundamental Kubernetes primitives and architectural building blocks: multi-node cluster topology, multi-tenancy with Namespaces, Role-Based Access Control (RBAC), Node Taints & Tolerations, Ingress Controllers, StatefulSets with Persistent Volumes, DaemonSets, Deployments with Rolling Updates & Probes, and Node Maintenance (Cordon & Drain).

> **Solutions / Çözümler:** Detailed solutions are available in [proje/cozum/README.md](./proje/cozum/README.md).

---

## 📋 Lab Objectives & Architecture

1. **Multi-Node Cluster Architecture:** Set up a 5-node Kubernetes cluster (1 Control Plane + 4 Worker Nodes).
2. **Environment Isolation:** Provision isolated `test` and `production` namespaces.
3. **Granular RBAC Authorization:**
   - Configure a `junior` role granting full CRUD access (`read, list, create, delete`) across all resources in `test`, but strictly read-only (`read, list`) access in `production`.
   - Configure a `senior` role granting full CRUD access across `test` and `production`, with read-only permissions cluster-wide.
4. **Ingress Controller Deployment:** Install and configure an Ingress Controller (Nginx, Traefik, or HAProxy).
5. **Workload Isolation with Taints & Tolerations:**
   - Dedicate 3 worker nodes exclusively to `production` workloads using Taints (`tier=production:NoSchedule`) and Labels (`tier=production`).
6. **Multi-Tier Stateful Application (WordPress + MySQL):**
   - Deploy WordPress and MySQL across both `test` and `production` namespaces.
   - Internal connectivity via `ClusterIP` Service.
   - Data persistence using PersistentVolumes and PersistentVolumeClaims.
   - Decouple sensitive credentials (passwords, usernames) into Kubernetes `Secrets`.
   - Co-locate application and database pods on the same worker node using affinity/tolerations.
   - Configure CPU and Memory resource requests and limits.
7. **L7 Ingress Routing:**
   - Route traffic for `testblog.example.com` to the `test` WordPress deployment.
   - Route traffic for `companyblog.example.com` to the `production` WordPress deployment.
8. **Resilient Microservice Deployment & Probes:**
   - Deploy `ozgurozturknet/k8s:v1` in `production` with 5 replicas.
   - Configure rolling update strategy (`maxSurge: 2`, `maxUnavailable: 0`).
   - Define `/healthcheck` for `livenessProbe` and `/ready` for `readinessProbe`.
9. **External Exposure via LoadBalancer:** Expose the deployment using a `LoadBalancer` service.
10. **Lifecycle & Scaling Operations:** Scale the deployment to 3 replicas, then scale up to 10 replicas, and execute a zero-downtime rolling update to `ozgurozturknet/k8s:v2`.
11. **Cluster-Wide DaemonSet:** Deploy a `fluentd` log collection DaemonSet running across all cluster nodes.
12. **High-Availability StatefulSet (MongoDB):** Deploy a 2-node MongoDB StatefulSet backed by persistent storage and initialize the replica set (`rs.initiate`).
13. **In-Cluster RBAC Client:** Create a dedicated `ServiceAccount` with cluster-wide read permissions. Run a curl pod using this ServiceAccount to authenticate and query `/api/v1/pods` via the Kubernetes API.
14. **Node Maintenance & Eviction:** Gracefully evict all pods from a designated worker node (`kubectl drain`) and mark it unschedulable (`kubectl cordon`).

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
