# ==============================================================================
# OMNISTREAM ENTERPRISE PLATFORM - TERRAFORM VERSIONS & PROVIDERS
# ==============================================================================
# Bu dosya (versions.tf), altyapı kodumuzun (IaC - Infrastructure as Code)
# hangi Terraform çekirdek sürümüyle ve hangi bulut sağlayıcı eklentileriyle
# (Providers) çalışacağını kesin kurallarla (Version Constraints) belirler.
# Gerçek dünya DevOps/Cloud mühendisliğinde sürümleri sabitlemek (pinning),
# "Benim bilgisayarımda çalışıyordu ama CI/CD pipeline'ında patladı" sorununu
# ve beklenmedik kırıcı değişiklikleri (Breaking Changes) önlemek için zorunludur.
# ==============================================================================

terraform {
  # Terraform CLI çekirdek sürümünün en az 1.5.0 veya daha yeni olmasını şart koşuyoruz.
  # ">= 1.5.0" ifadesi, modern Terraform özelliklerinin (ör. gelişmiş import blokları,
  # check blokları ve güvenli tip dönüşümleri) desteklendiğinden emin olmamızı sağlar.
  required_version = ">= 1.5.0"

  # required_providers bloğu, Terraform'un dış dünyadaki API'lerle (Azure ARM API,
  # yerel dosya sistemi vb.) konuşabilmesi için indireceği eklentileri tanımlar.
  required_providers {
    # --------------------------------------------------------------------------
    # 1. Microsoft Azure Kaynak Yöneticisi Sağlayıcısı (azurerm)
    # --------------------------------------------------------------------------
    azurerm = {
      # HashiCorp'un resmi Terraform Registry deposundaki doğrulanmış kaynak adresi.
      source = "hashicorp/azurerm"

      # Pessimistic Version Constraint (Kötümser Sürüm Kısıtlaması) Operatörü: "~>"
      # "~> 3.110.0" ne anlama gelir?
      # Semantic Versioning (MAJOR.MINOR.PATCH -> 3.110.0) standardına göre:
      # - Sadece en sağdaki basamağın (PATCH) artmasına izin verir (>= 3.110.0 ve < 3.111.0).
      # - Yani 3.110.1, 3.110.5 gibi hata düzeltmesi (bugfix) ve güvenlik yaması içeren
      #   sürümleri otomatik kabul eder, ancak yeni özellik veya davranış değişikliği
      #   getirebilecek 3.111.0 veya 4.0.0 sürümlerine geçişi engeller.
      # Bu sayede üretim (Production) ortamında %100 tekrarlanabilirlik (Reproducibility) sağlanır.
      version = "~> 3.110.0"
    }

    # --------------------------------------------------------------------------
    # 2. Yerel Dosya Sistemi Sağlayıcısı (local)
    # --------------------------------------------------------------------------
    local = {
      # Bulut sunucularımız (VM) oluşturulduktan sonra, dinamik IP adreslerini alıp
      # diskimizde "../ansible/hosts.ini" envanter dosyasını otomatik üretmek için kullanılır.
      # Böylece Terraform (Provisioning) ile Ansible (Configuration Management) arasında
      # sıfır manuel müdahale ile köprü (Zero-Touch Automation) kurulur.
      source = "hashicorp/local"

      # 2.5.x serisindeki tüm yama sürümlerine izin verir (>= 2.5.0, < 2.6.0).
      version = "~> 2.5.0"
    }
  }
}

# ==============================================================================
# AZURERM PROVIDER CONFIGURATION (SAĞLAYICI YAPILANDIRMASI)
# ==============================================================================
# Yukarıda indirilmesini istediğimiz "azurerm" eklentisinin çalışma zamanı (runtime)
# davranışlarını burada yapılandırıyoruz.
provider "azurerm" {
  # "features {}" bloğu azurerm sağlayıcısı için ZORUNLUDUR (boş bırakılsa bile yazılmalıdır).
  # Neden var? HashiCorp, Azure kaynaklarının silinme veya güncellenme sırasındaki
  # varsayılan davranışlarını (ör. bir sanal makine silindiğinde işletim sistemi diskinin
  # de otomatik silinip silinmeyeceği veya Key Vault silindiğinde purge edilip edilmeyeceği)
  # kullanıcının açıkça kontrol edebilmesi için bu bloğu şart koşar.
  features {
    virtual_machine {
      # Sanal makine (VM) "terraform destroy" ile silindiğinde, ona bağlı işletim sistemi
      # diskinin (OS Disk) Azure üzerinde yetim (orphaned) kalıp faturanızı şişirmesini önler.
      delete_os_disk_on_deletion = true

      # VM kapatılırken Azure'un işletim sistemine nazikçe kapanma (graceful shutdown)
      # sinyali göndermesini, hızlı laboratuvar yıkımlarında zaman kaybetmemek için devre dışı bırakıyoruz.
      graceful_shutdown = false
    }

    resource_group {
      # İçerisinde Terraform dışı manuel oluşturulmuş bir kaynak kalsa bile,
      # "terraform destroy" komutu verildiğinde tüm Resource Group'un temizlenmesine izin verir.
      prevent_deletion_if_contains_resources = false
    }
  }
}
