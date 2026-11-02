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

provider "random" {}
provider "local" {}

variable "replicas" {
  type    = number
  default = 3
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "app" {
  type = object({
    port = number
  })
  default = {
    port = 8080
  }
}

resource "random_pet" "app" {
  length = 2
}

resource "random_password" "api_key" {
  length  = 32
  special = false
}

resource "local_file" "frontend" {
  filename = "${path.module}/output/frontend.conf"
  content  = <<-EOT
    app_name     = ${random_pet.app.id}
    backend_conf = ${path.module}/output/backend.conf
    port         = ${var.app.port}
  EOT
}

resource "local_file" "backend" {
  filename = "${path.module}/output/backend.conf"
  content  = <<-EOT
    frontend_conf = ${path.module}/output/frontend.conf
    replicas      = ${var.replicas}
    api_key       = ${random_password.api_key.result}
  EOT
}

resource "local_file" "environment" {
  filename = "${path.module}/output/readme.txt"
  content  = "Environment: ${var.environment}"
}