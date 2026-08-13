#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="${ROOT_DIR}/kubernetes/gateway"
EG_VERSION="${EG_VERSION:-v1.8.3}"
NAMESPACE="envoy-gateway-system"

echo "==> Rendering Envoy Gateway ${EG_VERSION} manifests (helm template is local-only)"
rm -rf /tmp/eg-manifests
helm template eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${EG_VERSION}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --include-crds \
  --timeout 10m \
  --output-dir /tmp/eg-manifests > /dev/null 2>&1

echo "==> Applying Envoy Gateway manifests"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
find /tmp/eg-manifests -type f -name '*.yaml' -print0 | sort -z | \
  xargs -0 -n1 kubectl apply --server-side --force-conflicts --validate=false -f

echo "==> Applying Gateway API resources (GatewayClass, EnvoyProxy, Gateway, WAF policy)"
kubectl apply -f "${GATEWAY_DIR}/gatewayclass.yaml"
kubectl apply -f "${GATEWAY_DIR}/envoyproxy.yaml"
kubectl apply -f "${GATEWAY_DIR}/gateway.yaml"
kubectl apply -f "${GATEWAY_DIR}/waf-extensionpolicy.yaml"

echo "==> Waiting for Gateway to be accepted"
kubectl wait --for=condition=Accepted gateway/boutique-gateway \
  -n "${NAMESPACE}" --timeout=120s

echo "==> Waiting for LoadBalancer external IP (may take 2-5 minutes)"
kubectl get svc -n "${NAMESPACE}" -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway -w &
WATCH_PID=$!

for i in $(seq 1 60); do
  IP=$(kubectl get svc -n "${NAMESPACE}" -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${IP}" ]]; then
    kill "${WATCH_PID}" 2>/dev/null || true
    echo ""
    echo "==> Gateway external IP: ${IP}"
    echo "    Add a Cloudflare A record pointing your domain to this IP"
    echo "    Then deploy the app and route: BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh"
    exit 0
  fi
  sleep 5
done

kill "${WATCH_PID}" 2>/dev/null || true
echo "LoadBalancer IP not assigned yet. Check with:"
echo "  kubectl get svc -n ${NAMESPACE} -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway"
echo "  kubectl describe gateway/boutique-gateway -n ${NAMESPACE}"
