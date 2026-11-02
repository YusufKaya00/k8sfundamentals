#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

NAMESPACE="omnipulse-prod"

echo "=========================================================="
echo " Bootstrapping SRE Incident Lab 19: OmniPulse Platform (Broken State)"
echo "=========================================================="

echo "--> Creating namespace ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "--> Cleaning up old resources in ${NAMESPACE} if present..."
kubectl delete sts,pvc,job --all -n "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true

echo "--> Deploying broken omnipulse Helm release..."
helm upgrade --install omnipulse ./broken-manifests/helm/omnipulse -n "${NAMESPACE}"

echo "--> Checking initial resource status in ${NAMESPACE}..."
sleep 3
kubectl get pvc,pods,sts,ds,jobs,cronjobs,svc,ep,hpa,pdb,ingress -n "${NAMESPACE}"

echo "=========================================================="
echo " OmniPulse broken deployment finished. Review README.md for triage."
echo "=========================================================="
