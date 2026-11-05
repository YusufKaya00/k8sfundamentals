#!/usr/bin/env bash
# ==============================================================================
# SRE INCIDENT LAB 23: NexusMesh v4.2 Zero-Trust Edge Gateway Outage
# cleanup.sh — Temizlik ve Kaldırma Betiği
# ==============================================================================
set -euo pipefail

GATEWAY_NS="nexus-gateway"
MESH_NS="nexus-mesh"
SECURE_NS="nexus-secure"

echo "=========================================================="
echo " Cleaning up SRE Incident Lab 23: NexusMesh v4.2"
echo "=========================================================="

echo "--> [1/3] Uninstalling Helm release 'nexusmesh'..."
helm uninstall nexusmesh -n "${MESH_NS}" 2>/dev/null || helm uninstall nexusmesh 2>/dev/null || true

echo "--> [2/3] Deleting namespaces '${GATEWAY_NS}', '${MESH_NS}', '${SECURE_NS}'..."
kubectl delete namespace "${GATEWAY_NS}" "${MESH_NS}" "${SECURE_NS}" --ignore-not-found --timeout=60s || true

echo "--> [3/3] Verifying namespace removal..."
kubectl get ns "${GATEWAY_NS}" "${MESH_NS}" "${SECURE_NS}" 2>/dev/null || echo "Namespaces successfully removed."

echo "=========================================================="
echo " Lab 23 cleanup complete."
echo "=========================================================="
