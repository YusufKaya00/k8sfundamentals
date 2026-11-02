# Çözüm — tf-troubleshoot-3

Düzeltilmiş kod: [main.tf](main.tf)

## 5 Hata
| # | Hata | Mesaj (özet) | Çözüm |
|---|------|--------------|-------|
| 1 | `replicas` tipi `number`, default `"three"` | `Invalid default value for variable` | `default = 3` |
| 2 | `var.app_port` tanımlı değil | `Reference to undeclared input variable` | `variable "app_port"` ekle |
| 3 | frontend ↔ backend birbirini referans ediyor | `Cycle: local_file.backend, local_file.frontend` | Yolları `locals`'a taşı |
| 4 | `random_pet.app.value` | `Unsupported attribute` | `.id` kullan (attribute'ları registry dokümanında "Attributes Reference" kısmından bak) |
| 5 | `local_file.frontend` iki kez | `Duplicate resource "local_file" configuration` | İkincisini `readme` yap |

> Not: Terraform hataları **aşamalı** gösterir. Birini düzeltince yenisi çıkabilir — normal.

## Cycle Mantığı
`${local_file.backend.filename}` yazınca Terraform "frontend'i yazmak için önce backend oluşmalı" der. Backend de frontend'i bekleyince ikisi de birbirini bekler.
Çözüm: değer zaten **önceden biliniyorsa** (sabit yol, isim) kaynağa değil `local`/`variable`'a bağla. Gerçek hayatta tipik örnek: iki NSG'nin birbirine kural yazması → kuralları ayrı `azurerm_network_security_rule` kaynaklarına bölmek.

Grafiği görmek için: `terraform graph | grep -- '->'`

## Görev 4 — Replace
```bash
terraform apply -replace=random_password.api_key
```
Plan: `random_password.api_key` **replace** + `local_file.backend` **replace** (içeriği değiştiği için). `random_pet` ve `frontend` dokunulmaz → **zincirleme etki** (dependency) budur.

## Görev 5 — Elle değiştirilen dosya
`local_file` her plan'da dosyanın içeriğini kontrol eder; değişmişse onu **drift** sayar ve yeniden yazmayı planlar. Azure'daki drift ile aynı mantık.

## Bonus — taint vs -replace
- `terraform taint` (eski, deprecated): state'e anında "bozuk" işareti koyar, plan görmeden.
- `terraform apply -replace=...` (önerilen): aynı işi **plan içinde** gösterir, onaylamadan hiçbir şey olmaz.
