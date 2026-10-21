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
    region      = var.region.name
  })
}

# [FAULT 1C] Duplicate resource type + name ("local_file" "node_metadata" already declared above!)
resource "local_file" "hmac_secret" {
  filename = "/tmp/chronopay-lab1/etc/chronopay/hmac.key"
  content  = random_password.hmac_secret.result
  # [FAULT 2B] File permission is 0644 (world-readable) instead of 0600 required by security check
  file_permission = "0600"
}

# Auto-generate Ansible Inventory from Terraform state
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/hosts.ini"
  content = templatefile("${path.module}/templates/hosts.tftpl", {
    # [FAULT 2A] Unreachable host address passed to Ansible instead of 127.0.0.1
    target_host       = "127.0.0.1"
    gateway_port      = var.gateway_listen_port
    backend_port      = var.backend_internal_port
    deployment_id     = random_id.deployment_id.hex
  })
}
