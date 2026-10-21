#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

NAMESPACE="aether-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 17: AetherMesh Platform"
echo "=========================================================="

echo "--> [1/7] Auto-configuring Node Topology (Labels & Taints)..."
NODE_LIST=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true))
if [ "${#NODE_LIST[@]}" -ge 3 ]; then
  echo "    Found ${#NODE_LIST[@]} nodes: ${NODE_LIST[*]}"
  kubectl label node "${NODE_LIST[0]}" tier=web --overwrite >/dev/null 2>&1 || true
  kubectl label node "${NODE_LIST[1]}" tier=web --overwrite >/dev/null 2>&1 || true
  kubectl label node "${NODE_LIST[2]}" tier=database --overwrite >/dev/null 2>&1 || true
  kubectl taint nodes "${NODE_LIST[2]}" workload=database:NoSchedule --overwrite >/dev/null 2>&1 || true
  echo "    Topology ready: ${NODE_LIST[0]}=web, ${NODE_LIST[1]}=web, ${NODE_LIST[2]}=database (Tainted)"
else
  echo "    [Notice] Cluster has ${#NODE_LIST[@]} node(s). For full 3-node multi-tier simulation, run:"
  echo "             minikube start --nodes 3 --driver=docker"
fi

echo "--> [2/7] Cleaning up old lab resources in ${NAMESPACE} if present..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

echo "--> [3/7] Creating namespace ${NAMESPACE}..."
kubectl apply -f manifests/00-namespace.yaml

echo "--> [4/7] Applying Kubernetes manifests..."
kubectl delete job schema-migrator -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete jobs -n "${NAMESPACE}" -l app.kubernetes.io/name=cluster-heartbeat --ignore-not-found >/dev/null 2>&1 || true
kubectl delete statefulset aether-db -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete pvc data-aether-db-0 -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl delete deploy stream-worker -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f manifests/

echo "--> [5/7] Deploying stream-worker Helm release..."
helm upgrade --install stream-worker ./charts/stream-worker -f helm-values/worker-prod.yaml -n "${NAMESPACE}"

echo "--> [6/7] Deploying aether-gateway Helm release..."
helm upgrade --install aether-gateway ./charts/aether-gateway -f helm-values/gateway-prod.yaml -n "${NAMESPACE}"

echo "--> [7/7] Checking initial resource status in ${NAMESPACE}..."
sleep 4
kubectl get pods,pvc,jobs,cronjobs,daemonsets,deployments,statefulsets,services,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " AetherMesh deployment finished. Review README.md for triage."
echo "=========================================================="
