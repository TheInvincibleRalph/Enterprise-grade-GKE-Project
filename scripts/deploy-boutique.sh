#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOUTIQUE_DIR="${ROOT_DIR}/kubernetes/boutique"
MANIFESTS_URL="https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml"
BOUTIQUE_HOST="${BOUTIQUE_HOST:-}"

echo "==> Creating boutique namespace"
kubectl apply -f "${BOUTIQUE_DIR}/namespace.yaml"

echo "==> Deploying Online Boutique manifests"
kubectl apply -f "${MANIFESTS_URL}" -n boutique

echo "==> Applying repo-managed boutique overrides"
for manifest in "${BOUTIQUE_DIR}"/*.yaml; do
  if [[ "$(basename "${manifest}")" == "namespace.yaml" ]]; then
    continue
  fi
  kubectl apply -f "${manifest}"
done

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
