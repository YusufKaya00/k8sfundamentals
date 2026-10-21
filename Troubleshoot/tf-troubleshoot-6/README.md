# 🇬🇧 English Version

# 🚨 SRE Incident Lab: tf-troubleshoot-6 — AegisCloud Multi-Tier Cluster (Dependency Cycles, Cross-Host `hostvars`, `lineinfile` & L7 LB Routing)

Welcome to **tf-troubleshoot-6**. This capstone IaC + Configuration Management lab simulates a multi-tier cluster outage across **AegisCloud** (1 Control-Plane Master, 2 Worker Nodes, and 1 Edge LoadBalancer) — mirroring the exact architecture of a multi-node Kubernetes/K3s cluster bootstrap with Terraform and Ansible.

Your mission as the Lead SRE is to resolve tickets **INC-601** through **INC-605** in sequential order until `http://127.0.0.1:18090/cluster-status` returns `HTTP 200 HEALTHY` with both workers online.

> 📖 **Post-Mortem & Deep Root Cause Analyses (RCA):**  
> 👉 **[Explore Principal SRE Post-Mortem Guide (SOLUTION.md)](./SOLUTION.md)** — *Attempt resolution on your own before consulting the guide!*

---

## ⚡ Quick Start: Environment Provisioning

```bash
cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6
./setup.sh
```

---

## 📋 On-Call Incident Board (Active P1 Tickets)

| Ticket ID | Layer | Component | Observed Symptom | Suspected File(s) | Severity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-601]** | Terraform | Dependency Graph (`Cycle`) | `terraform validate` / `plan` fails with `Error: Cycle: local_file.worker_link, local_file.master_token`. | `terraform/main.tf` | `P1 - Blocker` |
| **[INC-602]** | Terraform -> Ansible | Inventory Group Structure | `ansible-playbook site.yml` fails to parse `hosts.ini` because `[aegis_cluster:children]` references `workers`, whereas the group header was generated as `[worker_nodes]`. | `terraform/main.tf` | `P1 - Blocker` |
| **[INC-603]** | Ansible | Cross-Host `slurp` Base64 Token | Worker nodes return `401_UNAUTHORIZED_JOIN_TOKEN_MISMATCH` because `raw_master_token.content` from `slurp:` was not decoded (`b64decode \| trim`). | `ansible/site.yml` | `P1 - Blocker` |
| **[INC-604]** | Ansible | `lineinfile` Missing `regexp:` | Worker nodes return `503_MAX_CONNECTIONS_ZERO_IN_ENV` because `lineinfile` appended `MAX_CONNECTIONS=500` without replacing the top `MAX_CONNECTIONS=0` line. | `ansible/site.yml` | `P1 - Blocker` |
| **[INC-605]** | Ansible & LB | Jinja2 Inventory Group Loop | Edge LB (`:18090/cluster-status`) returns `DEGRADED_502` because `templates/lb.json.j2` iterates over `groups['master']` instead of `groups['workers']`. | `ansible/templates/lb.json.j2` | `P1 - Blocker` |

---

## 🔍 Incident Triage & Verification Playbook

### [INC-601] Breaking the Terraform Circular Dependency (`Cycle:`)

* **Triage Commands (Before Fix):**
  ```bash
  cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/terraform
  terraform validate
  ```
* **Verification Commands (After Fix):**
  ```bash
  # Break the cycle in main.tf (master_token content should only contain random_password.cluster_join_token.result, and worker_link should use local.master_token_path)
  terraform validate
  ```

---

### [INC-602] Fixing Terraform Multi-Group Inventory Generation

* **Triage Commands (Before Fix):**
  ```bash
  cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/terraform
  terraform apply -auto-approve
  cd ../ansible && ansible-inventory --list
  ```
* **Verification Commands (After Fix):**
  ```bash
  # Change [worker_nodes] to [workers] in terraform/main.tf and re-apply
  cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/terraform
  terraform apply -auto-approve
  cd ../ansible && ansible all -m ping
  ```

---

### [INC-603] Fixing Cross-Host `slurp:` Base64 Join Token Decoding

* **Triage Commands (Before Fix):**
  ```bash
  cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/ansible
  ansible-playbook site.yml
  curl -i http://127.0.0.1:19101/work || true
  cat /tmp/aegiscloud-lab6/worker1/config.json
  ```
* **Verification Commands (After Fix):**
  ```bash
  # Add '| b64decode | trim' to join_token in site.yml, re-run ansible-playbook site.yml
  cat /tmp/aegiscloud-lab6/worker1/config.json
  ```

---

### [INC-604] Fixing `lineinfile` Duplicate Config Line (`regexp:`)

* **Triage Commands (Before Fix):**
  ```bash
  cat /tmp/aegiscloud-lab6/worker1/worker.env
  curl -i http://127.0.0.1:19101/work || true
  ```
* **Verification Commands (After Fix):**
  ```bash
  # Add 'regexp: "^MAX_CONNECTIONS="' to lineinfile in site.yml and re-run ansible-playbook site.yml
  cat /tmp/aegiscloud-lab6/worker1/worker.env
  curl -s http://127.0.0.1:19101/work
  curl -s http://127.0.0.1:19102/work
  ```

---

### [INC-605] Fixing Jinja2 LoadBalancer Upstream Group Loop

* **Triage Commands (Before Fix):**
  ```bash
  cat /tmp/aegiscloud-lab6/lb/lb.json
  curl -i http://127.0.0.1:18090/cluster-status || true
  ```
* **Verification Commands (After Fix):**
  ```bash
  # Change groups['master'] to groups['workers'] in ansible/templates/lb.json.j2 and re-run ansible-playbook site.yml
  cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/ansible
  ansible-playbook site.yml
  curl -s http://127.0.0.1:18090/cluster-status
  # Expected HTTP 200 JSON: {"lb_status": "HEALTHY", "active_workers": 2, ...}
  ```

---

<br>

---

# 🇹🇷 Türkçe Versiyon

# 🚨 SRE Arıza Labı: tf-troubleshoot-6 — AegisCloud Çok Katmanlı Küme (Cycle, `hostvars` Token Paylaşımı, `lineinfile` ve L7 LB Yönlendirme)

**tf-troubleshoot-6** laboratuvarına hoş geldiniz. Bu senaryo; 1 Master, 2 Worker ve 1 LoadBalancer sunucusundan oluşan çok katmanlı bir kümenin Terraform ve Ansible ile ayağa kaldırılması sırasında yaşanan 5 gerçekçi üretim arızasını simüle eder:
1. **[INC-601]:** İki kaynağın birbirini referans alması nedeniyle oluşan Terraform döngüsel bağımlılık (`Cycle`) hatası.
2. **[INC-602]:** Terraform'un ürettiği `hosts.ini` dosyasında `[worker_nodes]` vs `[workers]` grup adı uyuşmazlığı.
3. **[INC-603]:** Master sunucudan `slurp:` ile okunan katılım anahtarının (`join_token`) Base64 formatında kalması (`| b64decode | trim` unutulması) nedeniyle Worker'ların `401 Unauthorized` hatası vermesi.
4. **[INC-604]:** `lineinfile` modülünde `regexp: '^MAX_CONNECTIONS='` kullanılmadığı için `worker.env` içindeki `MAX_CONNECTIONS=0` satırının ezilmeyip alt satıra mükerrer kayıt eklenmesi (`503` hatası).
5. **[INC-605]:** LoadBalancer Jinja2 şablonunda (`lb.json.j2`) `groups['workers']` yerine `groups['master']` döngüsü kurulması nedeniyle trafiğin worker'lara dağıtılamaması (`502 Bad Gateway`).
