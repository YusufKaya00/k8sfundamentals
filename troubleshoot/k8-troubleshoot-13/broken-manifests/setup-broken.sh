#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Deploying NovaEdge Broken Environment (Lab 13)"
echo "=========================================================="

echo "[1/4] Ensuring namespace novaedge-prod exists..."
kubectl create namespace novaedge-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Installing Edge Ingress Controller with broken values..."
helm upgrade --install edge-ingress "${SCRIPT_DIR}/../charts/edge-ingress" \
  -f "${SCRIPT_DIR}/helm-values/edge-ingress-prod.yaml" \
  -n novaedge-prod

echo "[3/4] Applying core infrastructure & storage manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-core-infra.yaml"

echo "[4/4] Applying broken ingress, stream-api, daemonset & sync worker manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/20-ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/30-stream-api.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/40-edge-daemonset.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/50-sync-worker.yaml"

echo "=========================================================="
echo " NovaEdge broken setup complete. Incident tickets active!"
echo "=========================================================="
