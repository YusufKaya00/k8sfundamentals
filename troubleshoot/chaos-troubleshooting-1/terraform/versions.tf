# ==============================================================================
# CHAOS & TROUBLESHOOTING LAB 1 - TERRAFORM VERSIONS & PROVIDERS
# ==============================================================================
# Bu dosya (versions.tf), altyapı kodumuzun (IaC - Infrastructure as Code)
# hangi Terraform çekirdek sürümüyle ve hangi bulut sağlayıcı eklentileriyle
# (Providers) çalışacağını kesin kurallarla (Version Constraints) belirler.
# ==============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # --------------------------------------------------------------------------
    # 1. Microsoft Azure Kaynak Yöneticisi Sağlayıcısı (azurerm)
    # --------------------------------------------------------------------------
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110.0"
    }

    # --------------------------------------------------------------------------
    # 2. Yerel Dosya Sistemi Sağlayıcısı (local)
    # --------------------------------------------------------------------------
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.0"
    }
  }
}

# ==============================================================================
# AZURERM PROVIDER CONFIGURATION (SAĞLAYICI YAPILANDIRMASI)
# ==============================================================================
provider "azurerm" {
  features {
    virtual_machine {
      delete_os_disk_on_deletion = true
      graceful_shutdown          = false
    }

    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
