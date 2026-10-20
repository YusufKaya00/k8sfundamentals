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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

# Bu lab tamamen LOKALDE çalışır, Azure'a hiç gitmez (maliyet 0).
# random_* kaynakları "üretimdeki sunucu adı / şifre" gibi düşün:
# bir kez oluşur, değişirse felaket olur.

variable "environment" {
  type    = string
  default = "prod"
}

variable "sleep_duration" {
  type    = string
  default = "90s"
}

resource "random_pet" "server_name" {
  prefix = var.environment
  length = 2
}

resource "random_password" "db_password" {
  length  = 20
  special = false
}

resource "local_file" "app_config" {
  filename = "${path.module}/output/app.conf"
  content  = <<-EOT
    server_name = ${random_pet.server_name.id}
    environment = ${var.environment}
    db_password = ${random_password.db_password.result}
  EOT
}

# Uzun süren bir işlemi simüle eder (state lock senaryosu için)
resource "time_sleep" "long_operation" {
  create_duration = var.sleep_duration
}

output "server_name" {
  value = random_pet.server_name.id
}
