#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==========================================="
echo " Deploying Chronos Production Architecture"
echo "==========================================="

echo "[1/4] Ensuring namespace chronos-prod exists..."
kubectl create namespace chronos-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Applying core infrastructure manifests..."
kubectl apply -f manifests/

echo "[3/4] Installing order-api Helm chart..."
helm upgrade --install order-api ./charts/order-api \
  -f helm-values/order-api-prod.yaml \
  -n chronos-prod

echo "[4/4] Installing edge-lb Helm chart..."
helm upgrade --install edge-lb ./charts/edge-lb \
  -f helm-values/edge-lb-prod.yaml \
  -n chronos-prod

echo "==========================================="
echo " Chronos setup complete."
echo "==========================================="
