#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="aether-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 17: AetherMesh Platform"
echo "=========================================================="

echo "--> [1/6] Cleaning up old lab resources in ${NAMESPACE} if present..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

echo "--> [2/6] Creating namespace ${NAMESPACE}..."
kubectl apply -f manifests/00-namespace.yaml

echo "--> [3/6] Applying Kubernetes manifests..."
kubectl delete job schema-migrator -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete jobs -n "${NAMESPACE}" -l app.kubernetes.io/name=cluster-heartbeat --ignore-not-found >/dev/null 2>&1 || true
kubectl delete statefulset aether-db -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete pvc data-aether-db-0 -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete deploy stream-worker -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f manifests/

echo "--> [4/6] Deploying stream-worker Helm release..."
helm upgrade --install stream-worker ./charts/stream-worker -f helm-values/worker-prod.yaml -n "${NAMESPACE}"

echo "--> [5/6] Deploying aether-gateway Helm release..."
helm upgrade --install aether-gateway ./charts/aether-gateway -f helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [6/6] Checking initial resource status in ${NAMESPACE}..."
sleep 4
kubectl get pods,pvc,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " AetherMesh deployment finished. Review README.md for triage."
echo "=========================================================="
