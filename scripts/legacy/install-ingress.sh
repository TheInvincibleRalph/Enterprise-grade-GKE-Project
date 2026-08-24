#!/usr/bin/env bash
# ⚠️ SUPERSEDED — Phase 1.3 original: Install Ingress NGINX with ModSecurity WAF
#
# The community ingress-nginx controller was retired in March 2026.
# Replaced by scripts/install-envoy-gateway.sh (Envoy Gateway + Coraza WAF).
# Kept as the "before" state for the migration course milestone.
#
# Original content:
# Phase 1.3 — Install Ingress NGINX with ModSecurity WAF (OWASP CRS)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES_FILE="${ROOT_DIR}/kubernetes/ingress/values.yaml"
NAMESPACE="ingress-nginx"

echo "==> Adding ingress-nginx Helm repo"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx

echo "==> Installing Ingress NGINX with WAF"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values "${VALUES_FILE}" \
  --wait \
  --timeout 10m

echo "==> Waiting for LoadBalancer external IP (may take 2-5 minutes)"
kubectl get svc -n "${NAMESPACE}" ingress-nginx-controller -w &
WATCH_PID=$!

for i in $(seq 1 60); do
  IP=$(kubectl get svc -n "${NAMESPACE}" ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "${IP}" ]]; then
    kill "${WATCH_PID}" 2>/dev/null || true
    echo ""
    echo "==> Ingress external IP: ${IP}"
    echo "    Add a Cloudflare A record pointing your domain to this IP"
    exit 0
  fi
  sleep 5
done

kill "${WATCH_PID}" 2>/dev/null || true
echo "LoadBalancer IP not assigned yet. Check with:"
echo "  kubectl get svc -n ${NAMESPACE} ingress-nginx-controller"
