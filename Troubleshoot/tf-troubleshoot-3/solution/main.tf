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

# FIX 1: number tipine string verilmişti
variable "replicas" {
  type    = number
  default = 3
}

variable "environment" {
  type    = string
  default = "dev"
}

# FIX 2: tanımsız değişken kullanılıyordu
variable "app_port" {
  type    = number
  default = 8080
}

# FIX 3 (Cycle): dosya yolları zaten önceden bilinen sabit değerler.
# Kaynağın kendisine referans vermek yerine local'den okuyoruz → bağımlılık kalkar.
locals {
  frontend_path = "${path.module}/output/frontend.conf"
  backend_path  = "${path.module}/output/backend.conf"
}

resource "random_pet" "app" {
  length = 2
}

resource "random_password" "api_key" {
  length  = 32
  special = false
}

resource "local_file" "frontend" {
  filename = local.frontend_path
  content  = <<-EOT
    app_name     = ${random_pet.app.id}
    backend_conf = ${local.backend_path}
    port         = ${var.app_port}
  EOT
}
# FIX 4: random_pet'in ".value" diye bir attribute'u yok → ".id"

resource "local_file" "backend" {
  filename = local.backend_path
  content  = <<-EOT
    frontend_conf = ${local.frontend_path}
    replicas      = ${var.replicas}
    api_key       = ${random_password.api_key.result}
  EOT
}

# FIX 5: aynı adres (local_file.frontend) iki kez tanımlanmıştı
resource "local_file" "readme" {
  filename = "${path.module}/output/readme.txt"
  content  = "Environment: ${var.environment}"
}
