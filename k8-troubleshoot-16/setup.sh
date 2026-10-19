#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="omnicore-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 16: OmniCore Platform"
echo "=========================================================="

echo "--> [1/6] Cleaning up previous lab namespaces if present..."
kubectl delete namespace quantflow-prod aegis-prod --ignore-not-found >/dev/null 2>&1 || true

echo "--> [2/6] Creating namespace ${NAMESPACE}..."
kubectl apply -f manifests/00-namespace.yaml

echo "--> [3/6] Applying Kubernetes manifests..."
kubectl delete job schema-migrator manual-heartbeat -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete pvc data-omnicore-db-0 -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f manifests/

echo "--> [4/6] Deploying catalog-worker Helm release..."
helm upgrade --install catalog-worker ./charts/catalog-worker -f helm-values/catalog-prod.yaml -n "${NAMESPACE}"

echo "--> [5/6] Deploying omni-gateway Helm release..."
helm upgrade --install omni-gateway ./charts/omni-gateway -f helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [6/6] Checking resource status in ${NAMESPACE}..."
sleep 4
kubectl get pods,pvc,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " OmniCore deployment finished. Review README.md for triage."
echo "=========================================================="
