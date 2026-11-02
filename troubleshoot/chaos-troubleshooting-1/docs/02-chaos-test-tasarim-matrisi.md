# 02 — Bir Sistemde Hangi Kaos Testlerini ve Kontrolleri Yapmalıyım? (Karar Matrisi)

Bir şirkette veya projede önüne çalışan bir mimari geldiğinde **"Ben şimdi bu sistemin neresine hangi kaos testini uygulamalıyım ve neyin patlayıp neyin patlamaması gerekir?"** sorusunu yanıtlamak için aşağıdaki mühendislik metodolojisini kullanırız.

---

## 1. Altın Kural: Bağımlılıkları Sınıflandır (Hard vs. Soft Dependency)

Kaos testine başlamadan önce mimarideki her parçayı ikiye ayırmalısın:

1. **Kritik Bağımlılık (Hard Dependency):** Bu bileşen tamamen çökerse ana işlev (örn. sipariş alma) devam **edemez**.  
   *Örnek:* `PostgreSQL` (Siparişin kaydedildiği ana veritabanı).  
   *Amaç:* Kısa süreli yavaşlamalarda (`Latency`) uygulama podlarının çökmemesini sağlamak, tam kesintide ise temiz bir `503` dönüp veritabanı geldiğinde kendi kendine düzelmesini (Self-Healing) doğrulamaktır.
2. **Esnek / Yan Bağımlılık (Soft Dependency / Asenkron):** Bu bileşen çökerse veya yavaşlarsa ana API **asla çökmemelidir!**  
   *Örnek:* `Redis` (Önbellek), `Kafka` (Analitik event akışı), `RabbitMQ` (Arka plan ödeme kuyruğu).  
   *Amaç:* Bunlar kesildiğinde sistemin **Graceful Degradation (Zarif Bozulma)** veya **Asenkron Tamponlama** ile kullanıcıya hizmet vermeye devam ettiğini kanıtlamaktır.

---

## 2. Bileşen Bazlı Kaos Test ve Kontrol Matrisi

Bir sistemde aşağıdaki teknolojilerden hangisi varsa, uygulanacak standart test reçetesi şudur:

| Sistemde Ne Var? | Hangi Kaos Testi Yapılmalı? (Chaos Mesh Türü) | Neyi Doğruluyoruz? (Beklenen Davranış) | Test Sırasında Neye Bakmalıyım? (Kontroller) |
| :--- | :--- | :--- | :--- |
| **1. Stateless Web API** (`order-api` Deployment) | **Pod Fault -> Pod Kill** (`Mode: One`) | • En az 2 replika var mı?<br>• Podlardan biri aniden öldüğünde (`SIGKILL`) diğer pod tüm yükü kesintisiz alıyor mu? | • `kubectl get pods -n app -w`<br>• `kubectl get endpoints -n app order-api`<br>• `curl` isteklerinde `HTTP 201` devamlılığı |
| **2. Redis / Memcached** (Önbellek Katmanı) | **DNS Fault -> Error** veya **Network -> Partition** | • Cache çöktüğünde API 500 hatası veriyor mu yoksa DB'ye düşüp (Fallback) çalışmaya devam mı ediyor? | • `/api/status` içinde `redis: DOWN`<br>• Sipariş cevabında `"status": "degraded"` ama HTTP kodu `201`<br>• `rs_circuit_breaker_state{dependency="redis"}` |
| **3. Apache Kafka** (Event Streaming) | **Network -> Delay (`300ms`)** ve **Consumer Stress / Kill** | • Kafka yavaşladığında API kilitleniyor mu?<br>• Consumer (`analytics-consumer`) öldüğünde mesajlar kayboluyor mu yoksa `LAG` olarak birikip pod gelince eriyor mu? | • `kafka-consumer-groups.sh --describe --group analytics-consumer`<br>• `LAG` sütununun artması ve deney bitince `0`'a inmesi |
| **4. RabbitMQ** (Task Queue / İş Kuyruğu) | **Pod Fault -> Pod Failure** (Worker üzerinde) veya **Network -> Partition** | • Tek bir worker podu arızalandığında kuyruk tamamen duruyor mu (`consumers: 0`), yoksa yedek worker devam mı ediyor?<br>• Hatalı mesajlar `DLQ` kuyruğuna düşüyor mu? | • `rabbitmqctl list_queues name messages_ready consumers`<br>• `consumers >= 1` kalmalı, `messages_ready` yığılmamalı |
| **5. PostgreSQL / MySQL** (Ana Veritabanı) | **Network -> Delay (`1000ms`)** veya **IO Injection -> Latency** | • **En Kritik Test:** Veritabanı yavaşladığında Kubelet yanlış yapılandırılmış bir `Liveness Probe` yüzünden API podlarını öldürüyor mu? | • `kubectl get pods -n app` (`RESTARTS` sayısı artmamalı!)<br>• `kubectl describe pod` (Liveness vs Readiness ayrımı)<br>• `pg_stat_activity` |
| **6. Arka Plan Worker / Consumer Podları** | **Stress Test -> Memory / CPU** | • Bellek veya CPU yükseldiğinde pod `OOMKilled (Exit Code 137)` olup `CrashLoopBackOff` döngüsüne giriyor mu? | • `kubectl top pods -n app`<br>• `kubectl describe pod` (`OOMKilled`)<br>• `resources.limits.memory` kontrolü |

---

## 3. Neden Bazı Testler "Sadece Kontrol", Bazıları "Troubleshooting" Olmalıdır?

Gerçek mühendislikte iki tip test senaryosu yürütülür:

1. **🟢 Kontrol (Doğrulama) Testleri:**
   - Sistemin zaten doğru kurgulandığı yerleri (örneğin 2 replikalı API'de 1 podun ölmesi veya Redis cache kesintisi) test ederiz.
   - **Burada hiçbir şey patlamamalıdır.** Öğrendiğimiz şey: *"Kaos enjekte edildiğinde sistemin kendini koruduğunu metriklerden ve CLI komutlarından nasıl okurum?"*
2. **🔴 Troubleshooting (Zafiyet Yakalama ve Çözme) Testleri:**
   - Yanlış ayarlanmış bir `livenessProbe`, tek replika bırakılmış bir `worker` veya çok düşük verilmiş bir `memory limit` normal şartlarda (`Steady State`) hiçbir hata vermez! Her şey `1/1 Running` görünür.
   - Ancak kaos testi uygulandığı anda bu gizli kusurlar **patlar**.
   - **Burada öğrendiğimiz şey:** *"Patlayan bileşeni semptomlarından (`502 Bad Gateway`, `OOMKilled`, `messages_ready` artışı) nasıl teşhis ederim ve Helm `values.yaml` üzerinden kalıcı olarak nasıl tamir ederim?"*
