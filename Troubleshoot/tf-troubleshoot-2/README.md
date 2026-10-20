# tf-troubleshoot-2 — State Felaketleri (Lock, Silinen State, Refactor)

**Senaryolar:** State Lock · State dosyası silindi · Kaynak yeniden adlandırma (state mv)
**Maliyet:** 0 — tamamen lokal (random / local / time provider). Azure'a gitmez.

## Hazırlık
```bash
terraform init
terraform apply -auto-approve        # ilk kurulum ~90 sn sürer (time_sleep)
terraform apply -auto-approve -var environment=prod   # ikinci apply → .backup dosyası oluşur
cat output/app.conf                  # sunucu adını not al!
ls -la                               # terraform.tfstate ve terraform.tfstate.backup gör
```

---

## Senaryo A — State Lock
İki terminal aç (ikisi de bu klasörde).

- **Terminal 1:**
  ```bash
  terraform apply -auto-approve -replace=time_sleep.long_operation
  ```
- **Terminal 2** (Terminal 1 çalışırken):
  ```bash
  terraform plan
  ```

- [ ] **Görev A1:** Terminal 2'deki hatayı oku. Lock ID, `Who`, `Operation` alanları ne anlatıyor? Lock bilgisi hangi dosyada tutuluyor? (`ls -la` ile çalışırken bak)
- [ ] **Görev A2:** Terminal 1'deki işlemi zorla öldür: `pkill -9 terraform`. Sonra tekrar `terraform plan` çalıştır. Kilit kaldı mı? Neden?
- [ ] **Görev A3:** `terraform force-unlock` ne zaman ve neden **tehlikelidir**?

---

## Senaryo B — State Silindi (Kabus)
```bash
rm terraform.tfstate
terraform plan
```
- [ ] **Görev B1:** Plan ne diyor? `apply` deseydin "prod sunucusu" ve "DB şifresi"ne ne olurdu?
- [ ] **Görev B2:** **apply ETMEDEN** state'i kurtar. Kurtardıktan sonra `terraform plan` → `No changes` olmalı ve `output/app.conf` içindeki sunucu adı değişmemeli.
- [ ] **Görev B3:** Bir daha olmasın diye ne yapardın? (en az 2 önlem)

---

## Senaryo C — Refactor Felaketi
Kodu "temizlemek" istiyorsun. `main.tf`'de `random_pet.server_name` kaynağının adını `random_pet.primary_server` yap (output ve local_file içindeki referansları da güncelle).
```bash
terraform plan
```
- [ ] **Görev C1:** Plan neden **1 destroy + 1 create** diyor? Sadece adını değiştirdin!
- [ ] **Görev C2:** Kaynağı yeniden yaratmadan rename et. İki yolu da dene: `moved {}` bloğu ve `terraform state mv`.

## Başarı Kriteri
Her senaryo sonunda `terraform plan` → `No changes` ve sunucu adı en baştaki ile aynı.

> Takılırsan: `solution/README.md`
