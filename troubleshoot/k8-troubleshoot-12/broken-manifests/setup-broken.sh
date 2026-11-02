#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Deploying Vortex Broken Environment (Lab 12)"
echo "=========================================================="

echo "[1/4] Ensuring namespace vortex-prod exists..."
kubectl create namespace vortex-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Installing Traefik Ingress Controller with broken values..."
helm upgrade --install traefik "${SCRIPT_DIR}/../charts/traefik" \
  -f "${SCRIPT_DIR}/helm-values/traefik-prod.yaml" \
  -n vortex-prod

echo "[3/4] Applying core infrastructure manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-core-infra.yaml"

echo "[4/4] Applying broken microservices and ingress manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/20-ingress.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/30-auth-service.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/40-payment-service.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/50-notification-worker.yaml"

echo "=========================================================="
echo " Vortex broken setup complete. Incident tickets active!"
echo "=========================================================="
