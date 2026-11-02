#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=========================================================="
echo " Connecting Local Kubectl to Azure AKS Cluster"
echo "=========================================================="

RG_NAME=$(terraform output -raw resource_group_name 2>/dev/null || echo "rg-aether-aks")
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "aks-aether-prod")

echo "--> Fetching cluster credentials from Azure..."
az aks get-credentials --resource-group "${RG_NAME}" --name "${CLUSTER_NAME}" --overwrite-existing

echo "--> Verifying cluster connectivity and node topology..."
kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,TIER:.metadata.labels.tier,TAINTS:.spec.taints

echo "=========================================================="
echo " Connection successful! Active context set to: ${CLUSTER_NAME}"
echo " Next step: cd .. && ./setup.sh"
echo "=========================================================="
