#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="/tmp/aegiscloud-lab6"

echo "=================================================================="
echo " 🚨 Provisioning SRE Incident Lab: tf-troubleshoot-6 (AegisCloud)"
echo "=================================================================="

pkill -f "aegis_worker_lab6.py" 2>/dev/null || true
pkill -f "aegis_lb_lab6.py" 2>/dev/null || true
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/master" "${RUNTIME_DIR}/worker1" "${RUNTIME_DIR}/worker2" "${RUNTIME_DIR}/lb" "${RUNTIME_DIR}/logs"
mkdir -p "${LAB_DIR}/terraform" "${LAB_DIR}/ansible/templates" "${LAB_DIR}/ansible/files"

# Pre-seed worker sysctl.conf with MAX_CONNECTIONS=0 so missing 'regexp:' in lineinfile [INC-604] leaves it broken!
for w in worker1 worker2; do
  cat << 'EOF' > "${RUNTIME_DIR}/${w}/worker.env"
NODE_ROLE=worker
MAX_CONNECTIONS=0
EOF
done

# 1. Write faulty Terraform configuration [INC-601 & INC-602]
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

resource "random_password" "cluster_join_token" {
  length  = 24
  special = false
}

locals {
  master_token_path = "/tmp/aegiscloud-lab6/master/node-token"
  worker_meta_path  = "/tmp/aegiscloud-lab6/worker1/cluster-link.json"
  workers = {
    worker1 = 19101
    worker2 = 19102
  }
}

# [FAULT 601] Circular dependency Cycle between local_file.master_token and local_file.worker_link!
# Fix by referencing 'local.worker_meta_path' and 'local.master_token_path' instead of the resource attributes.
resource "local_file" "master_token" {
  filename        = local.master_token_path
  file_permission = "0600"
  # Referencing local_file.worker_link.filename creates a Cycle! Simply write random_password.cluster_join_token.result
  content         = "${random_password.cluster_join_token.result}#linked:${local_file.worker_link.filename}"
}

resource "local_file" "worker_link" {
  filename = local.worker_meta_path
  content = jsonencode({
    token_source = local_file.master_token.filename
  })
}

# [FAULT 602] Inventory generation has wrong group header '[worker_nodes]' instead of '[workers]'
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<-EOT
[master]
master1 ansible_host=127.0.0.1 ansible_connection=local

[worker_nodes]
worker1 ansible_host=127.0.0.1 ansible_connection=local worker_port=19101
worker2 ansible_host=127.0.0.1 ansible_connection=local worker_port=19102

[lb]
lb1 ansible_host=127.0.0.1 ansible_connection=local lb_listen_port=18090

[aegis_cluster:children]
master
workers
lb
EOT
}
EOF

# 2. Write faulty Ansible configuration [INC-603, INC-604, INC-605]
cat << 'EOF' > "${LAB_DIR}/ansible/ansible.cfg"
[defaults]
inventory = hosts.ini
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/hosts.ini"
[master]
master1 ansible_host=127.0.0.1 ansible_connection=local

[worker_nodes]
worker1 ansible_host=127.0.0.1 ansible_connection=local worker_port=19101
worker2 ansible_host=127.0.0.1 ansible_connection=local worker_port=19102

[lb]
lb1 ansible_host=127.0.0.1 ansible_connection=local lb_listen_port=18090
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/templates/lb.json.j2"
{
  "listen_port": {{ lb_listen_port }},
  "upstreams": [
{% for host in groups['master'] %}
    "http://127.0.0.1:{{ hostvars[host]['worker_port'] | default(19999) }}/work"{% if not loop.last %},{% endif %}
{% endfor %}
  ]
}
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/site.yml"
---
# PLAY 1: Read Cluster Join Token from Master Node
- name: Master Control-Plane Token Extraction
  hosts: master
  gather_facts: false
  tasks:
    - name: Slurp cluster join token from Master
      slurp:
        src: "/tmp/aegiscloud-lab6/master/node-token"
      register: raw_master_token

    # [FAULT 603] slurp returns base64-encoded content! Missing '| b64decode | trim' filter!
    - name: Export join_token fact on master1
      set_fact:
        join_token: "{{ raw_master_token.content }}"

# PLAY 2: Join Worker Nodes to Master & Tune Limits
- name: Worker Nodes Join and Tuning
  hosts: workers
  gather_facts: false
  tasks:
    # [FAULT 604] Missing 'regexp: ^MAX_CONNECTIONS=' causes lineinfile to append a duplicate line
    # while leaving the original 'MAX_CONNECTIONS=0' active at the top of worker.env!
    - name: Set MAX_CONNECTIONS=500 in worker.env
      lineinfile:
        path: "/tmp/aegiscloud-lab6/{{ inventory_hostname }}/worker.env"
        line: "MAX_CONNECTIONS=500"

    - name: Write worker runtime configuration
      copy:
        dest: "/tmp/aegiscloud-lab6/{{ inventory_hostname }}/config.json"
        mode: '0600'
        content: |
          {
            "node_name": "{{ inventory_hostname }}",
            "listen_port": {{ worker_port }},
            "worker_token": "{{ hostvars['master1']['join_token'] }}",
            "expected_token_file": "/tmp/aegiscloud-lab6/master/node-token",
            "env_file": "/tmp/aegiscloud-lab6/{{ inventory_hostname }}/worker.env"
          }

    - name: Start Worker Node Daemon
      shell: |
        pkill -f "aegis_worker_lab6.py {{ inventory_hostname }}" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/aegis_worker_lab6.py {{ inventory_hostname }} /tmp/aegiscloud-lab6/{{ inventory_hostname }}/config.json > /tmp/aegiscloud-lab6/logs/{{ inventory_hostname }}.log 2>&1 &
        sleep 1
      changed_when: false

# PLAY 3: Configure Edge LoadBalancer
- name: Configure Edge LoadBalancer
  hosts: lb
  gather_facts: false
  tasks:
    # [FAULT 605] templates/lb.json.j2 loops over groups['master'] instead of groups['workers']!
    - name: Render LoadBalancer upstream config
      template:
        src: templates/lb.json.j2
        dest: "/tmp/aegiscloud-lab6/lb/lb.json"
        mode: '0644'

    - name: Start Edge LoadBalancer Daemon
      shell: |
        pkill -f "aegis_lb_lab6.py" 2>/dev/null || true
        nohup python3 {{ playbook_dir }}/files/aegis_lb_lab6.py /tmp/aegiscloud-lab6/lb/lb.json > /tmp/aegiscloud-lab6/logs/lb.log 2>&1 &
        sleep 1
      changed_when: false
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/files/aegis_worker_lab6.py"
import http.server
import json
import sys

NODE_NAME = sys.argv[1]
CFG_PATH = sys.argv[2]

with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
WORKER_TOKEN = CFG["worker_token"].strip()
with open(CFG["expected_token_file"], "r") as tf:
    EXPECTED_TOKEN = tf.read().strip()

# First occurrence of MAX_CONNECTIONS wins (simulating strict env parser)
MAX_CONN = 0
with open(CFG["env_file"], "r") as ef:
    for line in ef:
        line = line.strip()
        if line.startswith("MAX_CONNECTIONS="):
            MAX_CONN = int(line.split("=", 1)[1])
            break

class WorkerHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/work":
            if WORKER_TOKEN != EXPECTED_TOKEN:
                body = json.dumps({
                    "node": NODE_NAME,
                    "error": "401_UNAUTHORIZED_JOIN_TOKEN_MISMATCH",
                    "received_token": WORKER_TOKEN
                }).encode("utf-8")
                self.send_response(401)
            elif MAX_CONN <= 0:
                body = json.dumps({
                    "node": NODE_NAME,
                    "error": "503_MAX_CONNECTIONS_ZERO_IN_ENV",
                    "max_connections": MAX_CONN
                }).encode("utf-8")
                self.send_response(503)
            else:
                body = json.dumps({
                    "node": NODE_NAME,
                    "status": "WORKER_HEALTHY",
                    "max_connections": MAX_CONN,
                    "port": PORT
                }).encode("utf-8")
                self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), WorkerHandler)
    server.serve_forever()
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/files/aegis_lb_lab6.py"
import http.server
import json
import sys
import urllib.request

CFG_PATH = sys.argv[1]
with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
UPSTREAMS = CFG["upstreams"]

class LBHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/cluster-status":
            results = []
            all_ok = True
            for url in UPSTREAMS:
                try:
                    with urllib.request.urlopen(url, timeout=2) as resp:
                        results.append(json.loads(resp.read().decode("utf-8")))
                except urllib.error.HTTPError as he:
                    all_ok = False
                    results.append(json.loads(he.read().decode("utf-8")))
                except Exception as e:
                    all_ok = False
                    results.append({"upstream": url, "error": str(e)})
            code = 200 if (all_ok and len(results) == 2) else 502
            body = json.dumps({
                "lb_status": "HEALTHY" if code == 200 else "DEGRADED_502",
                "active_workers": len(results),
                "backends": results
            }).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        return

if __name__ == "__main__":
    server = http.server.HTTPServer(("127.0.0.1", PORT), LBHandler)
    server.serve_forever()
EOF

echo ">> Initializing Terraform providers..."
rm -rf "${LAB_DIR}/terraform/terraform.tfstate" "${LAB_DIR}/terraform/terraform.tfstate.backup"
(cd "${LAB_DIR}/terraform" && terraform init -input=false >/dev/null 2>&1 || true)

echo "✅ Outage simulation ready! Follow README.md from [INC-601] to [INC-605]."
