#!/usr/bin/env bash
# Phase 1.5 — OWASP ZAP baseline scan (requires Docker)
set -euo pipefail

TARGET_URL="${1:-}"
REPORT_FILE="${2:-zap_report.html}"

if [[ -z "${TARGET_URL}" ]]; then
  echo "Usage: $0 <https://boutique.yourdomain.dev> [report.html]"
  exit 1
fi

echo "==> Pulling OWASP ZAP image"
docker pull zaproxy/zap-stable

echo "==> Running baseline scan against ${TARGET_URL}"
docker run --rm -v "$(pwd):/zap/wrk:rw" zaproxy/zap-stable zap-baseline.py \
  -t "${TARGET_URL}" \
  -r "${REPORT_FILE}"

echo "==> Report saved to ${REPORT_FILE}"
echo "Verify WAF blocks in Envoy Gateway logs:"
echo "  kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway | grep -i coraza"
