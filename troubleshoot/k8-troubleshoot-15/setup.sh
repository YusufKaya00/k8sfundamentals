#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="quantflow-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 15: QuantFlow Platform"
echo "=========================================================="

echo "--> [1/5] Creating namespace ${NAMESPACE}..."
kubectl apply -f manifests/00-namespace.yaml

echo "--> [2/5] Applying Kubernetes manifests..."
kubectl delete job ledger-bootstrap manual-snapshot -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f manifests/

echo "--> [3/5] Deploying liquidity-worker Helm release..."
helm upgrade --install liquidity-worker ./charts/liquidity-worker -f helm-values/liquidity-prod.yaml -n "${NAMESPACE}"

echo "--> [4/5] Deploying quant-gateway Helm release..."
helm upgrade --install quant-gateway ./charts/quant-gateway -f helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [5/5] Checking resource status in ${NAMESPACE}..."
sleep 3
kubectl get pods,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " QuantFlow deployment finished. Review README.md for triage."
echo "=========================================================="
