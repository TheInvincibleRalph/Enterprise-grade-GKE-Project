#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUTIQUE_DIR="${ROOT_DIR}/kubernetes/boutique"
BOUTIQUE_HOST="${BOUTIQUE_HOST:-}"

echo "==> Reconciling Online Boutique from repo-managed Kustomize overlay"
kubectl apply -k "${BOUTIQUE_DIR}"

echo "==> Waiting for frontend deployment"
kubectl rollout status deployment/frontend -n boutique --timeout=5m

echo "==> Applying HTTPRoute for boutique (requires the Gateway from install-envoy-gateway.sh)"
if [[ -n "${BOUTIQUE_HOST}" ]]; then
  echo "==> Routing host: ${BOUTIQUE_HOST}"
  sed "s/boutique.example.dev/${BOUTIQUE_HOST}/" "${ROOT_DIR}/kubernetes/gateway/httproute.yaml" | kubectl apply -f -
else
  echo "==> Applying HTTPRoute with placeholder host (boutique.example.dev)"
  echo "    Re-apply with your domain:"
  echo "    BOUTIQUE_HOST=boutique.invincibledevops.tech $0"
  kubectl apply -f "${ROOT_DIR}/kubernetes/gateway/httproute.yaml"
fi

echo "==> Boutique deployed"
kubectl get pods,svc -n boutique
kubectl get httproute -n boutique
