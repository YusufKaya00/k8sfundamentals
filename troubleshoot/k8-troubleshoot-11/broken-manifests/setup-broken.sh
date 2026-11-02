#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Deploying PulseStream Broken Environment (Lab 11)"
echo "=========================================================="

echo "[1/4] Ensuring namespace pulsestream-prod exists..."
kubectl create namespace pulsestream-prod --dry-run=client -o yaml | kubectl apply -f -

echo "[2/4] Applying broken core infrastructure & database manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/10-core-infra.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/20-db-migration-job.yaml"

echo "[3/4] Installing analytics-worker Helm chart with broken values..."
helm upgrade --install analytics-worker "${SCRIPT_DIR}/../charts/analytics-worker" \
  -f "${SCRIPT_DIR}/helm-values/worker-prod.yaml" \
  -n pulsestream-prod

echo "[4/4] Applying broken report-api, HPA, and edge manifests..."
kubectl apply -f "${SCRIPT_DIR}/manifests/30-report-api.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/40-report-hpa.yaml"
kubectl apply -f "${SCRIPT_DIR}/manifests/50-edge-and-daemon.yaml"

echo "=========================================================="
echo " PulseStream broken setup complete. Incident tickets active!"
echo "=========================================================="
