#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="/tmp/nexusvault-lab5"

echo "=================================================================="
echo " 🚨 Provisioning SRE Incident Lab: tf-troubleshoot-5 (NexusVault)"
echo "=================================================================="

pkill -f "nexusvault_daemon_lab5.py" 2>/dev/null || true
rm -rf "${RUNTIME_DIR}"
mkdir -p "${RUNTIME_DIR}/etc/nexusvault" "${RUNTIME_DIR}/var/log"
mkdir -p "${LAB_DIR}/terraform" "${LAB_DIR}/ansible/group_vars"
mkdir -p "${LAB_DIR}/ansible/roles/vault-agent/defaults"
mkdir -p "${LAB_DIR}/ansible/roles/vault-agent/vars"
mkdir -p "${LAB_DIR}/ansible/roles/vault-agent/tasks"
mkdir -p "${LAB_DIR}/ansible/roles/vault-agent/templates"
mkdir -p "${LAB_DIR}/ansible/roles/vault-agent/files"

# 1. Step 1: Create initial baseline Terraform config to generate a real valid state backup
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

resource "random_id" "cluster_id" {
  byte_length = 4
  lifecycle {
    prevent_destroy = true
  }
}

resource "random_password" "api_token" {
  length  = 20
  special = false
}

resource "local_file" "vault_bootstrap" {
  filename        = "/tmp/nexusvault-lab5/etc/nexusvault/bootstrap.json"
  file_permission = "0600"
  content = jsonencode({
    cluster_id = random_id.cluster_id.hex
    api_token  = random_password.api_token.result
  })
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<-EOT
[vault_nodes]
nexusvault-01 ansible_host=127.0.0.1 ansible_connection=local vault_cluster_id=${random_id.cluster_id.hex} vault_seal_threshold=2
EOT
}

output "vault_cluster_id" {
  value = random_id.cluster_id.hex
}

output "api_token_sha256" {
  value = nonsensitive(sha256(random_password.api_token.result))
}
EOF

echo ">> Initializing Terraform and creating baseline production state..."
rm -rf "${LAB_DIR}/terraform/terraform.tfstate" "${LAB_DIR}/terraform/terraform.tfstate.backup"
(
  cd "${LAB_DIR}/terraform"
  terraform init -input=false >/dev/null 2>&1
  terraform apply -auto-approve >/dev/null 2>&1
)

# Save original production IDs for reference and backup
ORIG_CLUSTER_ID="$(cd "${LAB_DIR}/terraform" && terraform output -raw vault_cluster_id)"
ORIG_TOKEN_HASH="$(cd "${LAB_DIR}/terraform" && terraform output -raw api_token_sha256)"
echo "${ORIG_CLUSTER_ID}" > "${RUNTIME_DIR}/etc/nexusvault/expected_cluster_id.txt"
echo "${ORIG_TOKEN_HASH}" > "${RUNTIME_DIR}/etc/nexusvault/leaked_token_sha256.txt"

# Copy valid state to terraform.tfstate.backup and wipe terraform.tfstate to simulate [INC-501]
cp "${LAB_DIR}/terraform/terraform.tfstate" "${LAB_DIR}/terraform/terraform.tfstate.backup"
rm -f "${LAB_DIR}/terraform/terraform.tfstate"

# 2. Now write the refactored main.tf where random_id.cluster_id was renamed to random_id.vault_cluster_id [INC-502]
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

# [FAULT 502] Resource was renamed from 'random_id.cluster_id' to 'random_id.vault_cluster_id'
# without a 'moved {}' block or 'terraform state mv', triggering a prevent_destroy error!
resource "random_id" "vault_cluster_id" {
  byte_length = 4
  lifecycle {
    prevent_destroy = true
  }
}

# [FAULT 503] This API token was leaked and must be rotated using '-replace=random_password.api_token'
# while keeping random_id.vault_cluster_id unchanged!
resource "random_password" "api_token" {
  length  = 20
  special = false
}

resource "local_file" "vault_bootstrap" {
  filename        = "/tmp/nexusvault-lab5/etc/nexusvault/bootstrap.json"
  file_permission = "0600"
  content = jsonencode({
    cluster_id = random_id.vault_cluster_id.hex
    api_token  = random_password.api_token.result
  })
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<-EOT
[vault_nodes]
nexusvault-01 ansible_host=127.0.0.1 ansible_connection=local vault_cluster_id=${random_id.vault_cluster_id.hex} vault_seal_threshold=2
EOT
}

output "vault_cluster_id" {
  value = random_id.vault_cluster_id.hex
}

output "api_token_sha256" {
  value = nonsensitive(sha256(random_password.api_token.result))
}
EOF

# 3. Populate Ansible files with Role Variable Precedence Trap [INC-504] and when: Type Trap [INC-505]
cat << 'EOF' > "${LAB_DIR}/ansible/ansible.cfg"
[defaults]
inventory = hosts.ini
roles_path = ./roles
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/group_vars/all.yml"
---
vault_listen_port: 18200
vault_environment: "production"
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/roles/vault-agent/defaults/main.yml"
---
vault_listen_port: 18200
vault_storage_backend: "raft"
EOF

# [FAULT 504] Role 'vars/main.yml' has higher precedence than both 'defaults/main.yml' and 'group_vars/all.yml'!
cat << 'EOF' > "${LAB_DIR}/ansible/roles/vault-agent/vars/main.yml"
---
# Stale legacy debug port accidentally left in role vars (overrides group_vars and defaults!)
vault_listen_port: 19999
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/roles/vault-agent/templates/vault-config.json.j2"
{
  "cluster_id": "{{ vault_cluster_id }}",
  "listen_port": {{ vault_listen_port }},
  "storage_backend": "{{ vault_storage_backend }}",
  "sealed": {{ vault_remain_sealed | default(true) | lower }}
}
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/roles/vault-agent/tasks/main.yml"
---
- name: Verify production cluster_id was preserved (not regenerated)
  slurp:
    src: "/tmp/nexusvault-lab5/etc/nexusvault/expected_cluster_id.txt"
  register: expected_id_raw

- name: Assert cluster_id matches original production state
  assert:
    that:
      - vault_cluster_id == (expected_id_raw.content | b64decode | trim)
    fail_msg: "CRITICAL STATE LOSS: vault_cluster_id ({{ vault_cluster_id }}) does not match original production ID ({{ expected_id_raw.content | b64decode | trim }})! Restore terraform.tfstate from backup!"

- name: Unseal NexusVault when seal threshold equals 2
  set_fact:
    vault_remain_sealed: false
  # [FAULT 505] Inventory variables from INI files are parsed as strings ("2"), so '== 2' evaluates to False!
  # Must use 'vault_seal_threshold | int == 2'
  when: vault_seal_threshold == 2

- name: Render NexusVault configuration file
  template:
    src: vault-config.json.j2
    dest: "/tmp/nexusvault-lab5/etc/nexusvault/vault-config.json"
    mode: '0600'

- name: Start or Reload NexusVault Daemon
  shell: |
    pkill -f "nexusvault_daemon_lab5.py" 2>/dev/null || true
    nohup python3 {{ role_path }}/files/nexusvault_daemon_lab5.py /tmp/nexusvault-lab5/etc/nexusvault/vault-config.json > /tmp/nexusvault-lab5/var/log/vault.log 2>&1 &
    sleep 1
  changed_when: false
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/site.yml"
---
- name: Deploy and Unseal NexusVault Stateful Node
  hosts: vault_nodes
  gather_facts: false
  roles:
    - vault-agent
EOF

cat << 'EOF' > "${LAB_DIR}/ansible/roles/vault-agent/files/nexusvault_daemon_lab5.py"
import http.server
import json
import sys

CFG_PATH = sys.argv[1]
with open(CFG_PATH, "r") as f:
    CFG = json.load(f)

PORT = int(CFG["listen_port"])
SEALED = bool(CFG["sealed"])
CLUSTER_ID = CFG["cluster_id"]

class VaultHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/v1/sys/health":
            code = 503 if SEALED else 200
            body = json.dumps({
                "cluster_id": CLUSTER_ID,
                "sealed": SEALED,
                "listen_port": PORT,
                "status": "SEALED_UNAVAILABLE" if SEALED else "ACTIVE_UNSEALED"
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
    server = http.server.HTTPServer(("127.0.0.1", PORT), VaultHandler)
    server.serve_forever()
EOF

echo "✅ Outage simulation ready! Original Production Cluster ID: ${ORIG_CLUSTER_ID}"
echo "   Follow README.md from [INC-501] to [INC-505]."
