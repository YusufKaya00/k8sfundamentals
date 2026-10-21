#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="/tmp/chronopay-lab1"

echo "=================================================================="
echo " 🚨 Provisioning SRE Incident Lab: iac-troubleshoot-1 (ChronoPay)"
echo "=================================================================="

# 1. Clean up any previous lab runtime
pkill -f "chronopay_backend_lab1.py" 2>/dev/null || true
pkill -f "chronopay_proxy_lab1.py" 2>/dev/null || true
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/etc/chronopay" "${RUNTIME_DIR}/var/log/chronopay" "${RUNTIME_DIR}/bin"

# 2. Pre-create a stale directory so the non-idempotent 'command: mkdir' in INC-104 fails!
mkdir -p "${RUNTIME_DIR}/var/log/chronopay/audit"

# 3. Reset faulty Terraform files
cat << 'EOF' > "${LAB_DIR}/terraform/variables.tf"
variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

# [FAULT 1A] Type is declared as number, but default is a string ("two")
variable "worker_threads" {
  description = "Number of gateway worker threads"
  type        = number
  default     = "two"
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
EOF

cat << 'EOF' > "${LAB_DIR}/terraform/main.tf"
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "random_id" "deployment_id" {
  byte_length = 4
}

resource "random_password" "hmac_secret" {
  length  = 24
  special = false
}

# Primary gateway node metadata
resource "local_file" "node_metadata" {
  filename = "/tmp/chronopay-lab1/etc/chronopay/node-meta.json"
  content = jsonencode({
    node_id     = random_id.deployment_id.hex
    environment = var.environment
    threads     = var.worker_threads
    # [FAULT 1B] Undeclared variable reference (var.region_name does not exist in variables.tf)
    region      = var.region_name
  })
}

# [FAULT 1C] Duplicate resource type + name ("local_file" "node_metadata" already declared above!)
resource "local_file" "node_metadata" {
  filename = "/tmp/chronopay-lab1/etc/chronopay/hmac.key"
  content  = random_password.hmac_secret.result
  # [FAULT 2B] File permission is 0644 (world-readable) instead of 0600 required by security check
  file_permission = "0644"
}

# Auto-generate Ansible Inventory from Terraform state
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.tftpl", {
    # [FAULT 2A] Unreachable host address passed to Ansible instead of 127.0.0.1
    target_host       = "192.0.2.99"
    gateway_port      = var.gateway_listen_port
    backend_port      = var.backend_internal_port
    deployment_id     = random_id.deployment_id.hex
  })
}
EOF

cat << 'EOF' > "${LAB_DIR}/terraform/outputs.tf"
output "deployment_id" {
  description = "Hex identifier of the ChronoPay deployment"
  # [FAULT 1D] random_id does not have a '.value' attribute (should be '.hex')
  value       = random_id.deployment_id.value
}

output "gateway_url" {
  description = "ChronoPay Edge Gateway Health Endpoint"
  value       = "http://127.0.0.1:${var.gateway_listen_port}/healthz"
}
EOF

mkdir -p "${LAB_DIR}/terraform/templates"
cat << 'EOF' > "${LAB_DIR}/terraform/templates/hosts.tftpl"
[payment_nodes]
chronopay-edge-01 ansible_host=${target_host} ansible_connection=local gateway_listen_port=${gateway_port} backend_service_port=${backend_port} deploy_id=${deployment_id}
EOF

# 4. Reset faulty Ansible files
cat << 'EOF' > "${LAB_DIR}/ansible/ansible.cfg"
[defaults]
inventory = hosts.ini
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/hosts.ini"
# Placeholder inventory before Terraform apply runs
[payment_nodes]
chronopay-edge-01 ansible_host=192.0.2.99 ansible_connection=local gateway_listen_port=18080 backend_service_port=19090 deploy_id=uninitialized
EOF

mkdir -p "${LAB_DIR}/ansible/templates" "${LAB_DIR}/ansible/files"

cat << 'EOF' > "${LAB_DIR}/ansible/templates/gateway.conf.j2"
{
  "service_name": "chronopay-edge-gateway",
  "deploy_id": "{{ deploy_id }}",
  "listen_host": "127.0.0.1",
  "listen_port": {{ gateway_port_number }},
  "upstream_url": "http://127.0.0.1:{{ upstream_backend_port }}/internal/status",
  "required_header": "X-Chrono-Auth"
}
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/site.yml"
---
# [FAULT 3A] Host group name uses hyphen ('payment-nodes'), but hosts.ini defines '[payment_nodes]'
- name: Configure ChronoPay Edge Gateway & Payment Engine
  hosts: payment-nodes
  gather_facts: false
  vars:
    runtime_root: "/tmp/chronopay-lab1"
    # [FAULT 5A] Upstream port set to 19099, but payment backend actually listens on 19090 (backend_service_port)
    upstream_backend_port: 19099

  tasks:
    - name: Verify HMAC secret key permissions are strictly 0600
      stat:
        path: "{{ runtime_root }}/etc/chronopay/hmac.key"
      register: hmac_stat

    - name: Fail if HMAC key file is missing or permissions are too open (must be 0600)
      fail:
        msg: "CRITICAL SECURITY FAULT: {{ runtime_root }}/etc/chronopay/hmac.key must exist with mode 0600 (found: {{ hmac_stat.stat.mode | default('missing') }})"
      when: not hmac_stat.stat.exists or hmac_stat.stat.mode != '0600'

    # [FAULT 4B] Non-idempotent raw 'command: mkdir' fails when directory already exists!
    - name: Create ChronoPay audit log directory
      command: mkdir {{ runtime_root }}/var/log/chronopay/audit

    - name: Start ChronoPay Internal Payment Backend Daemon
      shell: |
        pkill -f "chronopay_backend_lab1.py" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/chronopay_backend_lab1.py {{ backend_service_port }} > {{ runtime_root }}/var/log/chronopay/backend.log 2>&1 &
        sleep 1
      changed_when: false

    # [FAULT 4A] gateway.conf.j2 references '{{ gateway_port_number }}', which is undefined (inventory defines 'gateway_listen_port')
    # [FAULT 5B] Task notifies 'Restart Edge Proxy', which does not match handler name 'Reload ChronoPay Edge Proxy'
    - name: Render ChronoPay Edge Gateway configuration
      template:
        src: templates/gateway.conf.j2
        dest: "{{ runtime_root }}/etc/chronopay/gateway.json"
        mode: '0644'
      notify: Restart Edge Proxy

  handlers:
    - name: Reload ChronoPay Edge Proxy
      shell: |
        pkill -f "chronopay_proxy_lab1.py" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/chronopay_proxy_lab1.py {{ runtime_root }}/etc/chronopay/gateway.json > {{ runtime_root }}/var/log/chronopay/proxy.log 2>&1 &
        sleep 1
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/files/chronopay_backend_lab1.py"
import http.server
import json
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19090

class BackendHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/internal/status":
            body = json.dumps({
                "engine": "chronopay-core",
                "status": "READY",
                "port": PORT
            }).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), BackendHandler)
    server.serve_forever()
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/files/chronopay_proxy_lab1.py"
import http.server
import json
import sys
import urllib.request
import urllib.error

CONFIG_PATH = sys.argv[1]
with open(CONFIG_PATH, "r") as f:
    CFG = json.load(f)

LISTEN_PORT = int(CFG["listen_port"])
UPSTREAM_URL = CFG["upstream_url"]
DEPLOY_ID = CFG["deploy_id"]

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            try:
                req = urllib.request.Request(UPSTREAM_URL)
                with urllib.request.urlopen(req, timeout=2) as resp:
                    upstream_data = json.loads(resp.read().decode("utf-8"))
                body = json.dumps({
                    "gateway": "ONLINE",
                    "deploy_id": DEPLOY_ID,
                    "upstream": upstream_data
                }).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                body = json.dumps({
                    "gateway": "ERROR_502_BAD_GATEWAY",
                    "reason": str(e),
                    "attempted_upstream": UPSTREAM_URL
                }).encode("utf-8")
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), ProxyHandler)
    server.serve_forever()
EOF

# 5. Initialize Terraform plugins so the user can immediately run terraform validate/plan
echo ">> Initializing Terraform providers..."
rm -rf "${LAB_DIR}/terraform/terraform.tfstate" "${LAB_DIR}/terraform/terraform.tfstate.backup"
(cd "${LAB_DIR}/terraform" && terraform init -input=false >/dev/null 2>&1 || true)

# 6. Start a broken proxy instance pointing to the wrong upstream so initial state is observable
cat << 'EOF' > "${RUNTIME_DIR}/etc/chronopay/gateway.json"
{
  "service_name": "chronopay-edge-gateway",
  "deploy_id": "stale-boot",
  "listen_host": "127.0.0.1",
  "listen_port": 18080,
  "upstream_url": "http://127.0.0.1:19099/internal/status",
  "required_header": "X-Chrono-Auth"
}
EOF
nohup python3 "${LAB_DIR}/ansible/files/chronopay_proxy_lab1.py" "${RUNTIME_DIR}/etc/chronopay/gateway.json" > "${RUNTIME_DIR}/var/log/chronopay/proxy.log" 2>&1 &
sleep 1

echo "✅ Outage simulation ready! Follow README.md from [INC-101] to [INC-105]."
