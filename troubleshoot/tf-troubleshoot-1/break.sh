#!/bin/bash
# "Gece nöbetçi sistemci portaldan elle müdahale etti" simülasyonu.
set -e
RG="rg-tf-troubleshoot-1"

echo ">> NSG kuralı elle değiştiriliyor (SSH herkese açıldı)..."
az network nsg rule update -g "$RG" --nsg-name nsg-tf-lab -n Allow-SSH \
  --source-address-prefixes '*' -o none

echo ">> NSG'ye elle 'geçici' bir kural ekleniyor..."
az network nsg rule create -g "$RG" --nsg-name nsg-tf-lab -n Allow-All-Temp \
  --priority 100 --direction Inbound --access Allow --protocol '*' \
  --source-address-prefixes '*' --destination-port-ranges '*' -o none

echo ">> NSG etiketi elle değiştiriliyor..."
az network nsg update -g "$RG" -n nsg-tf-lab --set tags.owner=nobetci -o none

echo ">> Terraform dışından 'subnet-db' oluşturuluyor..."
az network vnet subnet create -g "$RG" --vnet-name vnet-tf-lab -n subnet-db \
  --address-prefixes 10.10.2.0/24 -o none

echo "Bitti. Şimdi README'deki 3. adıma geç."
