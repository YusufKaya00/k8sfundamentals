#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

NAMESPACE="quantflow-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 15: QuantFlow Platform (Broken State)"
echo "=========================================================="

echo "--> [1/5] Creating namespace ${NAMESPACE}..."
kubectl apply -f broken-manifests/manifests/00-namespace.yaml

echo "--> [2/5] Applying Kubernetes broken manifests..."
kubectl delete job ledger-bootstrap manual-snapshot -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f broken-manifests/manifests/

echo "--> [3/5] Deploying liquidity-worker Helm release with broken values..."
helm upgrade --install liquidity-worker ./charts/liquidity-worker -f broken-manifests/helm-values/liquidity-prod.yaml -n "${NAMESPACE}"

echo "--> [4/5] Deploying quant-gateway Helm release with broken values..."
helm upgrade --install quant-gateway ./charts/quant-gateway -f broken-manifests/helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [5/5] Checking resource status in ${NAMESPACE}..."
sleep 3
kubectl get pods,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " QuantFlow broken deployment finished. Review README.md for triage."
echo "=========================================================="
