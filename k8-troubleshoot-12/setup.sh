#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==========================================="
echo " Deploying Vortex Platform"
echo "==========================================="

echo "[1/3] Ensuring namespace exists..."
kubectl apply -f manifests/00-namespace.yaml

echo "[2/3] Applying Kubernetes manifests..."
kubectl apply -f manifests/

echo "[3/3] Deploying traefik Helm chart..."
helm upgrade --install traefik ./charts/traefik \
  -f helm-values/traefik-prod.yaml \
  -n vortex-prod

echo "==========================================="
echo " Vortex deployment completed."
echo "==========================================="
