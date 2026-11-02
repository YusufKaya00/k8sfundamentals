# Çözüm — tf-troubleshoot-2

## Senaryo A — State Lock
**A1:** `Error acquiring the state lock` → Terminal 1 state'i kilitledi. Lock bilgisi `.terraform.tfstate.lock.info` dosyasında (JSON: ID, Who, Operation, Created).

**A2:** Lokal backend'de kilit, işletim sistemi seviyesinde dosya kilidi (flock) ile tutulur. Process ölünce OS kilidi bırakır → tekrar çalışır.
Ama **remote backend'de** (Azure Storage blob lease, S3+DynamoDB, GitLab state) kilit sunucu tarafında kalır ve "ölü kilit" (stale lock) olur. O zaman:
```bash
terraform force-unlock <LOCK_ID>
```

**A3:** `force-unlock` sadece **kilidi tutan işlemin gerçekten öldüğünden eminsen** kullanılır. Başka biri hâlâ apply yapıyorsa ve sen kilidi kırarsan iki işlem aynı anda state'e yazar → state bozulur.
Önce: `Who` alanındaki kişiye sor / CI pipeline hâlâ çalışıyor mu kontrol et.

## Senaryo B — State Silindi
**B1:** Plan `3-4 to add` der. apply deseydin `random_pet` ve `random_password` **yeni değer** üretirdi → prod sunucu adı ve DB şifresi değişir; gerçek bulutta ise kaynaklar **ikinci kez** oluşturulur (çift fatura / isim çakışması).

**B2:** Terraform her yazmadan önce bir önceki state'i yedekler:
```bash
cp terraform.tfstate.backup terraform.tfstate
terraform plan
```
Not: `.backup` **bir önceki** apply'ın halidir. Son apply'da değişiklik yaptıysan plan küçük fark gösterebilir; o farkı apply etmek sorun değil (isim/şifre korunuyorsa).

Yedek de yoksa → kaynakları tek tek `import` edersin (Lab 1). Bu yüzden yedek hayat kurtarır.

**B3:** Önlemler:
1. **Remote backend** (Azure Storage Account + blob versioning / soft delete). State asla laptopta durmaz.
2. State'i **git'e koyma** (`.gitignore`'da zaten var) — içinde şifreler düz metin durur! `grep db_password terraform.tfstate` ile kendin gör.
3. Kritik değişiklik öncesi: `terraform state pull > snapshot-$(date +%F).tfstate`

## Senaryo C — Refactor
**C1:** Terraform kaynakları **adresleriyle** tanır (`random_pet.server_name`). Adres değişince "eskisi koddan gitti → sil, yenisi geldi → oluştur" der.

**C2 Yol 1 — `moved` bloğu (önerilen, review edilebilir):**
```hcl
moved {
  from = random_pet.server_name
  to   = random_pet.primary_server
}
```
`terraform plan` → `has moved to` ve `0 to destroy`. apply et.

**C2 Yol 2 — CLI:**
```bash
terraform state mv random_pet.server_name random_pet.primary_server
```

Diğer faydalı state komutları:
```bash
terraform state list
terraform state show random_pet.primary_server
terraform state rm local_file.app_config   # Terraform "unutur" ama dosyayı silmez
```
