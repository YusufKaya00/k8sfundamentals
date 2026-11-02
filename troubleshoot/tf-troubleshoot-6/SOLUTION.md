# 🇬🇧 English & 🇹🇷 Turkish Solution Guide: tf-troubleshoot-6

## 📑 Executive Incident Resolution Matrix

| Ticket ID | Root Cause | Exact Fix |
| :--- | :--- | :--- |
| **[INC-601]** | `local_file.master_token` and `local_file.worker_link` reference each other's attributes (`Cycle`). | In `terraform/main.tf`, set `master_token.content = random_password.cluster_join_token.result` and `worker_link` `token_source = local.master_token_path`. |
| **[INC-602]** | `hosts.ini` template defines `[worker_nodes]` instead of `[workers]`. | In `terraform/main.tf`, change `[worker_nodes]` to `[workers]` and run `terraform apply -auto-approve`. |
| **[INC-603]** | `slurp:` returns Base64-encoded text (`raw_master_token.content`). | In `ansible/site.yml`, change `join_token: "{{ raw_master_token.content }}"` to `join_token: "{{ raw_master_token.content \| b64decode \| trim }}"`. |
| **[INC-604]** | `lineinfile` without `regexp:` appends `MAX_CONNECTIONS=500` to the end of `worker.env`, leaving `MAX_CONNECTIONS=0` at the top. | Add `regexp: '^MAX_CONNECTIONS='` to the `lineinfile` task in `ansible/site.yml`. |
| **[INC-605]** | `ansible/templates/lb.json.j2` loops over `groups['master']` instead of `groups['workers']`. | Change `{% for host in groups['master'] %}` to `{% for host in groups['workers'] %}` in `ansible/templates/lb.json.j2`. |

---

## 🛠️ Complete Remediation Walkthrough

### 1. Fix `terraform/main.tf` (`[INC-601]` & `[INC-602]`)
```hcl
resource "local_file" "master_token" {
  filename        = local.master_token_path
  file_permission = "0600"
  content         = random_password.cluster_join_token.result
}

resource "local_file" "worker_link" {
  filename = local.worker_meta_path
  content = jsonencode({
    token_source = local.master_token_path
  })
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content  = <<-EOT
[master]
master1 ansible_host=127.0.0.1 ansible_connection=local

[workers]
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
```
Run:
```bash
cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/terraform
terraform validate && terraform apply -auto-approve
```

### 2. Fix `ansible/site.yml` (`[INC-603]` & `[INC-604]`)
Update `join_token` and `lineinfile`:
```yaml
    - name: Export join_token fact on master1
      set_fact:
        join_token: "{{ raw_master_token.content | b64decode | trim }}"
```
and in Play 2:
```yaml
    - name: Set MAX_CONNECTIONS=500 in worker.env
      lineinfile:
        path: "/tmp/aegiscloud-lab6/{{ inventory_hostname }}/worker.env"
        regexp: '^MAX_CONNECTIONS='
        line: "MAX_CONNECTIONS=500"
```

### 3. Fix `ansible/templates/lb.json.j2` (`[INC-605]`)
```json
{
  "listen_port": {{ lb_listen_port }},
  "upstreams": [
{% for host in groups['workers'] %}
    "http://127.0.0.1:{{ hostvars[host]['worker_port'] | default(19999) }}/work"{% if not loop.last %},{% endif %}
{% endfor %}
  ]
}
```

### 4. Apply & Verify
```bash
cd /home/ysf/k8sfundamentals/Troubleshoot/tf-troubleshoot-6/ansible
ansible-playbook site.yml
curl -s http://127.0.0.1:18090/cluster-status
```
