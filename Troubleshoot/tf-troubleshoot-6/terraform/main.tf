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
