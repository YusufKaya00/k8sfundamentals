# Çözüm — tf-troubleshoot-1

## Görev 1 — Drift
`terraform plan -refresh-only` 3 elle değişikliği gösterir:
1. `Allow-SSH` kuralının kaynağı `10.0.0.0/8` → `*` yapılmış
2. `Allow-All-Temp` adında, kodda olmayan bir kural eklenmiş
3. `owner = "nobetci"` etiketi eklenmiş

**Karar:**
- Etiketi koda işle (portal kazanır):
  ```hcl
  tags = {
    env   = "lab"
    owner = "nobetci"
  }
  ```
- Güvenlik kurallarına dokunma; normal `terraform apply` kodu esas alır, `*` kaynağını geri `10.0.0.0/8` yapar ve `Allow-All-Temp` kuralını siler (kod kazanır).

> `-refresh-only` ile apply edersen Terraform Azure'daki hali state'e yazar ama Azure'u değiştirmez. Sonraki normal `plan` yine farkı gösterir — kodu güncellemediysen.

## Görev 2 — Import
Hata: `a resource with the ID ".../subnets/subnet-db" already exists - to be managed via Terraform this resource needs to be imported into the State`

**Yöntem A (modern, önerilen)** — `main.tf`'ye ekle:
```hcl
import {
  to = azurerm_subnet.db
  id = "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-tf-troubleshoot-1/providers/Microsoft.Network/virtualNetworks/vnet-tf-lab/subnets/subnet-db"
}
```
`terraform plan` → `1 to import` görmelisin → `terraform apply`. Sonra `import` bloğunu silebilirsin.

**Yöntem B (klasik CLI):**
```bash
terraform import azurerm_subnet.db "/subscriptions/.../subnets/subnet-db"
```

> Fark: A kod içinde görünür, `plan` ile önizlenir ve PR'da gözden geçirilebilir. B anında state'i değiştirir.

ID'yi bulmak için: `az network vnet subnet show -g rg-tf-troubleshoot-1 --vnet-name vnet-tf-lab -n subnet-db --query id -o tsv`

## Görev 3 — prevent_destroy
Hata: `Instance cannot be destroyed ... lifecycle.prevent_destroy set`
Bu bir **özellik**, hata değil. Silmek bilinçli bir karar olmalı:
1. `main.tf`'de `prevent_destroy = false` yap (veya `lifecycle` bloğunu kaldır)
2. `terraform destroy`

> `-target` ile korumayı aşamazsın; tek yol kodu değiştirmek. Bu sayede silme işlemi PR/review sürecinden geçmek zorunda kalır.
