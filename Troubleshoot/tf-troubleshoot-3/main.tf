terraform {
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Bu lab tamamen LOKALDE çalışır (maliyet 0).
# Bu dosya BİLEREK bozuk yazıldı. İçinde 5 hata var.

variable "replicas" {
  type    = number
  default = "three"
}

variable "environment" {
  type    = string
  default = "dev"
}

resource "random_pet" "app" {
  length = 2
}

resource "random_password" "api_key" {
  length  = 32
  special = false
}

# Frontend config'i backend'in adresini bilmek istiyor...
resource "local_file" "frontend" {
  filename = "${path.module}/output/frontend.conf"
  content  = <<-EOT
    app_name     = ${random_pet.app.value}
    backend_conf = ${local_file.backend.filename}
    port         = ${var.app_port}
  EOT
}

# ...backend config'i de frontend'in adresini bilmek istiyor.
resource "local_file" "backend" {
  filename = "${path.module}/output/backend.conf"
  content  = <<-EOT
    frontend_conf = ${local_file.frontend.filename}
    replicas      = ${var.replicas}
    api_key       = ${random_password.api_key.result}
  EOT
}

resource "local_file" "frontend" {
  filename = "${path.module}/output/readme.txt"
  content  = "Environment: ${var.environment}"
}
