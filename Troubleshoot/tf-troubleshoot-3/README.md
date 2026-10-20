# tf-troubleshoot-3 — Bozuk Kod, Cycle ve Replace

**Senaryolar:** Döngüsel bağımlılık · Tip / referans / isim hataları · Tek kaynağı yeniden yaratma (`-replace`)
**Maliyet:** 0 — tamamen lokal.

## Bölüm 1 — Kodu Ayağa Kaldır
`main.tf` bilerek bozuk. İçinde **5 hata** var.

```bash
terraform init
terraform validate     # hataları burada yakala
terraform fmt          # formatı düzelt
terraform plan
```

- [ ] **Görev 1:** `validate` çıktısını oku ve 5 hatanın hepsini bul. Her hatanın mesajını not al — gerçek hayatta bunları sürekli göreceksin.
- [ ] **Görev 2:** Döngüsel bağımlılığı (`Cycle:`) kır. Frontend ve backend hâlâ birbirinin dosya yolunu config'inde göstermeli.
  (İpucu: Terraform'un bir değeri bilmek için bir **kaynağın** oluşmasını beklemesi gerekiyor mu?)
- [ ] **Görev 3:** `terraform apply` başarılı olsun, `output/` altındaki 3 dosyayı kontrol et.

## Bölüm 2 — Bozuk Kaynak / Şifre Rotasyonu
Senaryo: `api_key` sızdırıldı, **sadece onu** yenilemen lazım. Başka hiçbir şey yeniden oluşmamalı (`random_pet` adı aynı kalmalı).

- [ ] **Görev 4:** Sadece `random_password.api_key`'i yeniden üret. Plan'da kaç kaynak etkileniyor ve neden?
- [ ] **Görev 5:** `output/backend.conf` dosyasını elle düzenle (bir satır ekle), sonra `terraform plan`. Terraform ne fark etti?
- [ ] **Bonus:** `terraform taint` ile `-replace` arasındaki fark ne? Hangisi önerilir?

## Başarı Kriteri
`terraform validate` → `Success!`, `terraform plan` → `No changes`, `api_key` değişmiş ama uygulama adı aynı.

> Takılırsan: `solution/`
