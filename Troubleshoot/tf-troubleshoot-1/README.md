# tf-troubleshoot-1 — Drift, Import, prevent_destroy (Azure)

**Senaryolar:** State Drift · Resource Already Exists (Import) · Kazara Silme Koruması
**Maliyet:** 0 — sadece RG, VNet, Subnet, NSG (hepsi ücretsiz).

## Adımlar

1. Ortamı kur:
   ```bash
   terraform init
   terraform apply
   ```
2. "Biri portaldan elle müdahale etti":
   ```bash
   chmod +x break.sh && ./break.sh
   ```
3. `main.tf` en altındaki `azurerm_subnet.db` bloğunun yorumunu kaldır.
4. Şimdi şunları çalıştır ve **hataları/farkları oku**:
   ```bash
   terraform plan
   terraform apply
   ```
5. Her şeyi düzelttikten sonra lab'ı silmeyi dene:
   ```bash
   terraform destroy
   ```

## Görevler

- [ ] **Görev 1 (Drift):** `plan` çıktısında NSG için `~` ile gösterilen farkları bul. Elle yapılan 3 değişiklik ne? `terraform plan -refresh-only` ile sadece "Azure'da ne değişmiş" raporunu al.
  Karar ver: elle yapılan değişikliği **geri mi alacaksın** (kod kazanır) yoksa **koda mı işleyeceksin** (portal kazanır)? Etiket için koda işle, güvenlik kuralları için geri al.
- [ ] **Görev 2 (Import):** `apply` neden `already exists` hatası veriyor? Kaynağı **silmeden** state'e al. (İpucu: Terraform 1.5+ `import {}` bloğu veya `terraform import` komutu.)
- [ ] **Görev 3 (prevent_destroy):** `destroy` neden reddediliyor? Lab'ı güvenli şekilde nasıl silersin?
- [ ] **Bonus:** `terraform state list` ve `terraform state show azurerm_network_security_group.nsg` ile state'in içini incele.

## Başarı Kriteri
`terraform plan` → `No changes. Your infrastructure matches the configuration.`
ve en sonda `terraform destroy` başarılı.

> Takılırsan: `solution/README.md`
