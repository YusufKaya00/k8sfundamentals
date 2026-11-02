#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

NAMESPACE="storefront-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 18: NovaStore v2.4 (Broken State)"
echo "=========================================================="

echo "--> Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "--> Deploying broken storefront Helm release..."
helm upgrade --install storefront ./broken-manifests/helm/storefront -n "${NAMESPACE}"

echo "--> Checking initial resource status in ${NAMESPACE}..."
sleep 3
kubectl get pvc,pods,svc,ep,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " NovaStore broken deployment finished. Review README.md for triage."
echo "=========================================================="
