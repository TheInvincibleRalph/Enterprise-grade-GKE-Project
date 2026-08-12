#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CILIUM_VERSION="${CILIUM_VERSION:-1.18.12}"
VALUES_FILE="${ROOT_DIR}/kubernetes/cilium/values.yaml"

echo "==> Adding Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update cilium

echo "==> Installing Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version "${CILIUM_VERSION}" \
  --values "${VALUES_FILE}"

echo "==> Waiting for Cilium to become ready"
kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=5m

if command -v cilium &>/dev/null; then
  echo "==> Cilium status"
  cilium status --wait
  cilium status | grep -i encryption || true
  echo ""
  echo "Optional: run 'cilium connectivity test' to validate networking"
else
  echo "Install cilium CLI for 'cilium status' and 'cilium connectivity test'"
  echo "  https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli"
fi

echo "==> Cilium installed successfully"
