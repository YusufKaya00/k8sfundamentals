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
  default = "3"
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
    port         = ${var.app.port}
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

resource "local_file" "environment" {
  filename = "${path.module}/output/readme.txt"
  content  = "Environment: ${var.environment}"
}


locals {
  backend_filename  = "${path.module}/output/backend.conf"
  frontend_filename = "${path.module}/output/frontend.conf"

  backend_content  = templatefile("${path.module}/templates/backend.tpl", { host = "backend.example" })
  frontend_content = templatefile("${path.module}/templates/frontend.tpl", { host = "frontend.example" })

  # Eğer frontend config'in içinde backend adresi gerekiyorsa, buraya bilinen bir değer koyun:
  # örn. backend_host veya backend_filename gibi. Plan sırasında bilinmeyen bir dinamik değer olmamalı.
  backend_ref_for_frontend = local.backend_filename
  frontend_ref_for_backend = local.frontend_filename
}

resource "local_file" "frontend" {
  filename = local.frontend_filename
  content  = <<-EOT
    app_name     = ${random_pet.app.value}
    backend_conf = ${local.backend_ref_for_frontend}
    port         = ${var.app.port}

    ${local.frontend_content}
  EOT
}

resource "local_file" "backend" {
  filename = local.backend_filename
  content  = <<-EOT
    frontend_conf = ${local.frontend_ref_for_backend}
    replicas      = ${var.replicas}
    api_key       = ${random_password.api_key.result}

    ${local.backend_content}
  EOT
}

resource "local_file" "environment" {
  filename = "${path.module}/output/readme.txt"
  content  = "Environment: ${var.environment}"
}