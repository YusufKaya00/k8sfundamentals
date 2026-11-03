#!/usr/bin/env bash
set -euo pipefail

CORE_NS="vaultstream-core"
PCI_NS="vaultstream-pci"

echo "=========================================================="
echo " Cleaning up SRE Incident Lab 22: VaultStream v6.0"
echo "=========================================================="

echo "--> [1/3] Uninstalling Helm release 'vaultstream'..."
helm uninstall vaultstream -n "${CORE_NS}" 2>/dev/null || helm uninstall vaultstream 2>/dev/null || true

echo "--> [2/3] Deleting namespaces '${CORE_NS}' and '${PCI_NS}'..."
kubectl delete namespace "${CORE_NS}" "${PCI_NS}" --ignore-not-found --timeout=60s || true

echo "--> [3/3] Verifying namespace removal..."
kubectl get ns "${CORE_NS}" "${PCI_NS}" 2>/dev/null || echo "Namespaces successfully removed."

echo "=========================================================="
echo " Lab 22 cleanup complete."
echo "=========================================================="
