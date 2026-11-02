#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Deploying Chronos Broken Environment (Incident Simulation)"
echo "=========================================================="

echo "[1/4] Ensuring namespace chronos-prod exists..."
kubectl create namespace chronos-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Applying broken core infrastructure manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/"

echo "[3/4] Installing order-api Helm chart with broken values..."
helm upgrade --install order-api "${SCRIPT_DIR}/../charts/order-api" \
  -f "${SCRIPT_DIR}/helm-values/order-api-prod.yaml" \
  -n chronos-prod

echo "[4/4] Installing edge-lb Helm chart with broken values..."
helm upgrade --install edge-lb "${SCRIPT_DIR}/../charts/edge-lb" \
  -f "${SCRIPT_DIR}/helm-values/edge-lb-prod.yaml" \
  -n chronos-prod

echo "=========================================================="
echo " Chronos broken setup complete. Incident tickets active!"
echo "=========================================================="
