#!/usr/bin/env bash
set -euo pipefail

PRIMARY_NS="netcore-prod"
SECURE_NS="netcore-secure"

echo "=========================================================="
echo " Cleaning up SRE Incident Lab 21: NetCore Network Mesh"
echo "=========================================================="

echo "--> [1/3] Uninstalling Helm release 'netcore'..."
helm uninstall netcore -n "${PRIMARY_NS}" 2>/dev/null || helm uninstall netcore 2>/dev/null || true

echo "--> [2/3] Deleting namespaces '${PRIMARY_NS}' and '${SECURE_NS}'..."
kubectl delete namespace "${PRIMARY_NS}" "${SECURE_NS}" --ignore-not-found --timeout=60s || true

echo "--> [3/3] Verifying namespace removal..."
kubectl get ns "${PRIMARY_NS}" "${SECURE_NS}" 2>/dev/null || echo "Namespaces successfully removed."

echo "=========================================================="
echo " Lab 21 cleanup complete."
echo "=========================================================="
