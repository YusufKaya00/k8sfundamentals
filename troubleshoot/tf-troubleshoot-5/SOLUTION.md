# 🇬🇧 English & 🇹🇷 Turkish Solution Guide: tf-troubleshoot-5

## 📑 Executive Incident Resolution Matrix

| Ticket ID | Root Cause | Exact Fix |
| :--- | :--- | :--- |
| **[INC-501]** | `terraform.tfstate` was wiped, leaving only `terraform.tfstate.backup`. | `cp terraform.tfstate.backup terraform.tfstate` |
| **[INC-502]** | `random_id.cluster_id` was renamed to `random_id.vault_cluster_id` in `main.tf` while `prevent_destroy = true` is active. | Add `moved { from = random_id.cluster_id  to = random_id.vault_cluster_id }` to `main.tf` (or run `terraform state mv random_id.cluster_id random_id.vault_cluster_id`). |
| **[INC-503]** | `random_password.api_token` was compromised and needs targeted regeneration. | `terraform apply -auto-approve -replace="random_password.api_token"` |
| **[INC-504]** | `roles/vault-agent/vars/main.yml` defines `vault_listen_port: 19999`. In Ansible, `role vars` (precedence #15) override both `group_vars/all.yml` (#4) and `role defaults` (#2). | Remove `vault_listen_port: 19999` from `roles/vault-agent/vars/main.yml` (or set it to `18200`). |
| **[INC-505]** | Key-value variables in `.ini` inventories (`vault_seal_threshold=2`) are parsed by Ansible as strings (`"2"`). Comparing `"2" == 2` in Jinja2 returns `False`. | Change `when: vault_seal_threshold == 2` to `when: vault_seal_threshold | int == 2` in `roles/vault-agent/tasks/main.yml`. |

---

## 🛠️ Step-by-Step Commands (Full Walkthrough)

```bash
# 1. [INC-501] Restore missing state from backup
cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-5/terraform
cp terraform.tfstate.backup terraform.tfstate

# 2. [INC-502] Move state address without destroying protected resource
terraform state mv random_id.cluster_id random_id.vault_cluster_id
terraform plan

# 3. [INC-503] Rotate only the leaked API token
terraform apply -auto-approve -replace="random_password.api_token"

# 4. [INC-504] Remove high-precedence port override in role vars
cd ../ansible
sed -i 's/vault_listen_port: 19999/# vault_listen_port: 19999/' roles/vault-agent/vars/main.yml

# 5. [INC-505] Cast inventory string variable to integer in when condition
sed -i 's/when: vault_seal_threshold == 2/when: vault_seal_threshold | int == 2/' roles/vault-agent/tasks/main.yml

# 6. Run Ansible playbook and verify HTTP 200 ACTIVE_UNSEALED
ansible-playbook site.yml
curl -s http://127.0.0.1:18200/v1/sys/health
```
