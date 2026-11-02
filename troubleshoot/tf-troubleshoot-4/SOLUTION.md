# 🇬🇧 English Version

# 🛠️ SRE Post-Mortem & Remediation Guide: tf-troubleshoot-4 — ChronoPay Pipeline

This document serves as the authoritative **Principal SRE Post-Mortem & Incident Remediation Runbook** for the cascading Terraform + Ansible outage in **tf-troubleshoot-4**.

---

## 📑 Executive Incident Resolution Matrix

| Ticket ID | Layer | Observed Symptom | Root Cause | Remediation Summary |Severity |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **[INC-401]** | Terraform | `terraform validate` fails with 4 errors | **1A:** `worker_threads` (`type = number`) has `default = "two"`<br/>**1B:** `var.region_name` is undeclared<br/>**1C:** Duplicate `resource "local_file" "node_metadata"`<br/>**1D:** `random_id.deployment_id.value` instead of `.hex` | Set `default = 2`, replace `var.region_name` with `"eu-central-1"` (or declare variable), rename second `local_file` to `"hmac_key"`, and use `.hex` in `outputs.tf`. | `P1` |
| **[INC-402]** | Terraform -> Ansible | Wrong IP in `hosts.ini` & Ansible rejects `hmac.key` (`0644`) | **2A:** `target_host = "192.0.2.99"` instead of `"127.0.0.1"`<br/>**2B:** `file_permission = "0644"` instead of `"0600"` | Set `target_host = "127.0.0.1"` and `file_permission = "0600"` in `terraform/main.tf`, then run `terraform apply -auto-approve`. | `P1` |
| **[INC-403]** | Ansible | `skipping: no hosts matched` | `site.yml` targets `hosts: payment-nodes` (hyphen), whereas `hosts.ini` defines `[payment_nodes]` (underscore). | Change `hosts: payment-nodes` to `hosts: payment_nodes` in `ansible/site.yml`. | `P1` |
| **[INC-404]** | Ansible | `mkdir: File exists` & `gateway_port_number is undefined` | **4A:** Raw `command: mkdir` is not idempotent<br/>**4B:** `gateway.conf.j2` uses `{{ gateway_port_number }}` instead of inventory variable `{{ gateway_listen_port }}` | Replace `command: mkdir` with `file:` module (`state: directory`) in `site.yml`, and change `gateway_port_number` to `gateway_listen_port` in `templates/gateway.conf.j2`. | `P1` |
| **[INC-405]** | Ansible & Runtime | Handler not found & `HTTP 502 Bad Gateway` on `:18080/healthz` | **5A:** `notify: Restart Edge Proxy` does not match handler name `Reload ChronoPay Edge Proxy`<br/>**5B:** `upstream_backend_port: 19099` instead of `19090` (`{{ backend_service_port }}`) | Align `notify: Reload ChronoPay Edge Proxy` and set `upstream_backend_port: "{{ backend_service_port }}"` (or `19090`) in `ansible/site.yml`. | `P1` |

---

## 🔧 Step-by-Step Resolution

### [INC-401] & [INC-402] Fixing Terraform Configuration & Inventory Handoff

#### 1. Fix `terraform/variables.tf`
Change `default = "two"` to `default = 2` and declare `region_name`:
```hcl
variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

variable "region_name" {
  description = "Deployment region"
  type        = string
  default     = "denmarkeast"
}

variable "worker_threads" {
  description = "Number of gateway worker threads"
  type        = number
  default     = 2
}

variable "gateway_listen_port" {
  description = "External HTTP port for ChronoPay Edge Proxy"
  type        = number
  default     = 18080
}

variable "backend_internal_port" {
  description = "Internal TCP port where ChronoPay payment engine listens"
  type        = number
  default     = 19090
}
```

#### 2. Fix `terraform/main.tf`
Rename the second `local_file` resource to `hmac_key`, change `file_permission` to `"0600"`, and set `target_host = "127.0.0.1"`:
```hcl
resource "local_file" "hmac_key" {
  filename        = "/tmp/chronopay-lab1/etc/chronopay/hmac.key"
  content         = random_password.hmac_secret.result
  file_permission = "0600"
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.tftpl", {
    target_host   = "127.0.0.1"
    gateway_port  = var.gateway_listen_port
    backend_port  = var.backend_internal_port
    deployment_id = random_id.deployment_id.hex
  })
}
```

#### 3. Fix `terraform/outputs.tf`
Replace `.value` with `.hex`:
```hcl
output "deployment_id" {
  description = "Hex identifier of the ChronoPay deployment"
  value       = random_id.deployment_id.hex
}
```

Run `terraform validate && terraform apply -auto-approve`.

---

### [INC-403], [INC-404] & [INC-405] Fixing Ansible Playbook & Jinja2 Template

#### 1. Fix `ansible/templates/gateway.conf.j2`
Replace `{{ gateway_port_number }}` with `{{ gateway_listen_port }}`:
```json
{
  "service_name": "chronopay-edge-gateway",
  "deploy_id": "{{ deploy_id }}",
  "listen_host": "127.0.0.1",
  "listen_port": {{ gateway_listen_port }},
  "upstream_url": "http://127.0.0.1:{{ upstream_backend_port }}/internal/status",
  "required_header": "X-Chrono-Auth"
}
```

#### 2. Fix `ansible/site.yml`
* Change `hosts: payment-nodes` -> `hosts: payment_nodes`
* Change `upstream_backend_port: 19099` -> `upstream_backend_port: "{{ backend_service_port }}"`
* Replace `command: mkdir ...` with the idempotent `file` module (`state: directory`)
* Change `notify: Restart Edge Proxy` -> `notify: Reload ChronoPay Edge Proxy`

```yaml
---
- name: Configure ChronoPay Edge Gateway & Payment Engine
  hosts: payment_nodes
  gather_facts: false
  vars:
    runtime_root: "/tmp/chronopay-lab1"
    upstream_backend_port: "{{ backend_service_port }}"

  tasks:
    - name: Verify HMAC secret key permissions are strictly 0600
      stat:
        path: "{{ runtime_root }}/etc/chronopay/hmac.key"
      register: hmac_stat

    - name: Fail if HMAC key file is missing or permissions are too open (must be 0600)
      fail:
        msg: "CRITICAL SECURITY FAULT: {{ runtime_root }}/etc/chronopay/hmac.key must exist with mode 0600 (found: {{ hmac_stat.stat.mode | default('missing') }})"
      when: not hmac_stat.stat.exists or hmac_stat.stat.mode != '0600'

    - name: Create ChronoPay audit log directory
      file:
        path: "{{ runtime_root }}/var/log/chronopay/audit"
        state: directory
        mode: '0755'

    - name: Start ChronoPay Internal Payment Backend Daemon
      shell: |
        pkill -f "chronopay_backend_lab1.py" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/chronopay_backend_lab1.py {{ backend_service_port }} > {{ runtime_root }}/var/log/chronopay/backend.log 2>&1 &
        sleep 1
      changed_when: false

    - name: Render ChronoPay Edge Gateway configuration
      template:
        src: templates/gateway.conf.j2
        dest: "{{ runtime_root }}/etc/chronopay/gateway.json"
        mode: '0644'
      notify: Reload ChronoPay Edge Proxy

  handlers:
    - name: Reload ChronoPay Edge Proxy
      shell: |
        pkill -f "chronopay_proxy_lab1.py" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/chronopay_proxy_lab1.py {{ runtime_root }}/etc/chronopay/gateway.json > {{ runtime_root }}/var/log/chronopay/proxy.log 2>&1 &
        sleep 1
```

---

<br>

---

# 🇹🇷 Türkçe Çözüm Rehberi

## 🧠 Teşhis Mantığı (Diagnostic Mindset)

1. **`[INC-401]` Terraform Şema ve Tip Doğrulaması:**
   * Terraform'da `type = number` tanımlı bir değişkene `"two"` gibi metin verilemez.
   * Aynı dosya veya modül içinde iki kaynak aynı `<TİP> <İSİM>` (`local_file.node_metadata`) çiftini paylaşamaz.
   * `random_id` kaynağının çıktısı `.value` değil, `.hex` (veya `.b64_url` / `.dec`) olarak okunur.
2. **`[INC-402]` Terraform -> Ansible Köprüsü ve Dosya İzinleri:**
   * `local_file` varsayılan olarak dosyaları `0777` veya `0644` ile oluşturabilir. SSH anahtarları veya HMAC/TLS gizli dosyaları üretilirken `file_permission = "0600"` açıkça belirtilmelidir; aksi halde SSH istemcisi (`Permissions are too open`) veya güvenlik kontrolleri bağlantıyı reddeder.
3. **`[INC-403]` Ansible Grup Adı Uyuşmazlığı:**
   * `hosts.ini` içinde `[payment_nodes]` tanımlıyken Playbook içinde `hosts: payment-nodes` yazılırsa Ansible hiçbir sunucuyu eşleştiremez (`skipping: no hosts matched`).
4. **`[INC-404]` Idempotency İhlali (`command: mkdir` vs `file` modülü) ve Jinja2 Hatası:**
   * Ansible'da `command: mkdir /dizin` kullanmak en yaygın anti-pattern'dir; çünkü dizin zaten varsa ikinci çalışmada hata verir. Bunun yerine `file:` modülü ve `state: directory` kullanılmalıdır.
   * Jinja2 şablonlarında kullanılan değişkenlerin (`gateway_listen_port`) envanterdeki isimle birebir örtüşmesi gerekir.
5. **`[INC-405]` Handler Tetiklenmesi ve 502 Bad Gateway:**
   * `notify:` altında yazılan isim, `handlers:` altındaki `- name:` ile harfi harfine aynı olmalıdır. Ayrıca konfigürasyon dosyası daha önceki başarısız çalışmada zaten değiştiyse, ikinci çalışmada `template` görevi `ok` (değişmedi) döneceği için handler tetiklenmez; bu durumda `ansible-playbook site.yml --force-handlers` veya konfigürasyonda gerçek port (`19090`) değişikliği yapılması handler'ı ateşler ve `502 Bad Gateway` hatasını `200 OK` durumuna geçirir.
