#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Deploying AegisGrid Broken Environment (Lab 14)"
echo "=========================================================="

echo "[1/5] Ensuring namespace aegis-prod exists..."
kubectl create namespace aegis-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/5] Applying core infrastructure & feed jobs..."
kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-core-infra.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/20-feed-jobs.yaml"

echo "[3/5] Installing scanner-worker Helm chart with broken values..."
helm upgrade --install scanner-worker "${SCRIPT_DIR}/../charts/scanner-worker" \
  -f "${SCRIPT_DIR}/helm-values/scanner-prod.yaml" \
  -n aegis-prod

echo "[4/5] Applying broken intel-api, security & daemon manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/30-intel-api.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/40-security-and-daemon.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/50-ingress.yaml"

echo "[5/5] Installing aegis-gateway Helm chart with broken values..."
helm upgrade --install aegis-gateway "${SCRIPT_DIR}/../charts/aegis-gateway" \
  -f "${SCRIPT_DIR}/helm-values/gateway-prod.yaml" \
  -n aegis-prod

echo "=========================================================="
echo " AegisGrid broken setup complete. Incident tickets active!"
echo "=========================================================="
