#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "==========================================="
echo " Deploying PulseStream Platform"
echo "==========================================="

echo "[1/3] Ensuring namespace exists..."
kubectl apply -f manifests/00-namespace.yaml

echo "[2/3] Applying Kubernetes manifests..."
kubectl apply -f manifests/

echo "[3/3] Deploying analytics-worker Helm chart..."
helm upgrade --install analytics-worker ./charts/analytics-worker \
  -f helm-values/worker-prod.yaml \
  -n pulsestream-prod

echo "==========================================="
echo " PulseStream deployment completed."
echo "==========================================="
