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
