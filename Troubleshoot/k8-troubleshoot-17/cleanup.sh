#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="aether-prod"

echo "=========================================================="
echo " Tearing down SRE Incident Lab 17: AetherMesh Platform"
echo "=========================================================="

echo "--> Uninstalling Helm releases..."
helm uninstall stream-worker -n "${NAMESPACE}" --wait >/dev/null 2>&1 || true
helm uninstall aether-gateway -n "${NAMESPACE}" --wait >/dev/null 2>&1 || true

echo "--> Deleting namespace ${NAMESPACE}..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s || true

echo "=========================================================="
echo " Cleanup complete."
echo "=========================================================="
