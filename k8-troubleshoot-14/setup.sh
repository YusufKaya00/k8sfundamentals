#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="aegis-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 14: AegisGrid Platform"
echo "=========================================================="

echo "--> [1/5] Creating namespace ${NAMESPACE}..."
kubectl apply -f manifests/00-namespace.yaml

echo "--> [2/5] Applying Kubernetes manifests..."
kubectl apply -f manifests/

echo "--> [3/5] Deploying scanner-worker Helm release..."
helm upgrade --install scanner-worker ./charts/scanner-worker -f helm-values/scanner-prod.yaml -n "${NAMESPACE}"

echo "--> [4/5] Deploying aegis-gateway Helm release..."
helm upgrade --install aegis-gateway ./charts/aegis-gateway -f helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [5/5] Checking resource status in ${NAMESPACE}..."
sleep 3
kubectl get pods,jobs,cronjobs,daemonsets,deployments,statefulsets,services,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " AegisGrid deployment finished. Review README.md for triage."
echo "=========================================================="
