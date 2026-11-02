#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

NAMESPACE="omnicore-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 16: OmniCore Platform (Broken State)"
echo "=========================================================="

echo "--> [1/6] Cleaning up old lab namespaces if present..."
kubectl delete namespace aegis-prod --ignore-not-found >/dev/null 2>&1 || true

echo "--> [2/6] Creating namespace ${NAMESPACE}..."
kubectl apply -f broken-manifests/manifests/00-namespace.yaml

echo "--> [3/6] Applying Kubernetes broken manifests..."
kubectl delete job schema-migrator manual-heartbeat -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete jobs -n "${NAMESPACE}" -l app.kubernetes.io/name=state-heartbeat --ignore-not-found >/dev/null 2>&1 || true
kubectl delete statefulset omnicore-db -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete pvc data-omnicore-db-0 -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete deploy catalog-worker -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f broken-manifests/manifests/

echo "--> [4/6] Deploying catalog-worker Helm release with broken values..."
helm upgrade --install catalog-worker ./charts/catalog-worker -f broken-manifests/helm-values/catalog-prod.yaml -n "${NAMESPACE}"

echo "--> [5/6] Deploying omni-gateway Helm release with broken values..."
helm upgrade --install omni-gateway ./charts/omni-gateway -f broken-manifests/helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [6/6] Checking resource status in ${NAMESPACE}..."
sleep 4
kubectl get pods,pvc,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " OmniCore broken deployment finished. Review README.md for triage."
echo "=========================================================="
