#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="novaedge-prod"

echo "=========================================================="
echo " 🚀 Bootstrapping SRE Incident Lab 13: NovaEdge Platform"
echo "=========================================================="

echo "--> [1/4] Creating namespace ${NAMESPACE}..."
kubectl apply -f "${SCRIPT_DIR}/manifests/00-namespace.yaml"

echo "--> [2/4] Deploying core infrastructure and microservices..."
kubectl apply -f "${SCRIPT_DIR}/manifests/"

echo "--> [3/4] Deploying Edge Ingress Controller via Helm..."
helm upgrade --install edge-ingress "${SCRIPT_DIR}/charts/edge-ingress" \
  -f "${SCRIPT_DIR}/helm-values/edge-ingress-prod.yaml" \
  -n "${NAMESPACE}"

echo "--> [4/4] Verifying initial cluster deployment state..."
sleep 3
kubectl get pods -n "${NAMESPACE}" -o wide

echo "=========================================================="
echo " ⚠️  NovaEdge platform is deployed with active production incidents!"
echo " 📖 Review README.md for on-call triage tasks and verification."
echo " 🛠️  Refer to SOLUTION.md if you need RCA guidance."
echo "=========================================================="
