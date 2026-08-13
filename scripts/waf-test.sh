#!/usr/bin/env bash
set -euo pipefail

TARGET_URL="${1:-}"

if [[ -z "${TARGET_URL}" ]]; then
  echo "Usage: $0 <https://boutique.yourdomain.dev>"
  exit 1
fi

echo "==> Testing WAF at ${TARGET_URL}"
echo ""

ATTACKS=(
  "1' OR '1'='1"
  "<script>alert('xss')</script>"
  "../../../etc/passwd"
  "; cat /etc/passwd"
  "' UNION SELECT * FROM users--"
)

BLOCKED=0
TOTAL=${#ATTACKS[@]}

for attack in "${ATTACKS[@]}"; do
  echo -n "Testing: ${attack} ... "
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -G --data-urlencode "q=${attack}" \
    "${TARGET_URL}/search" || echo "000")

  if [[ "${HTTP_CODE}" == "403" ]]; then
    echo "blocked (403)"
    BLOCKED=$((BLOCKED + 1))
  else
    echo "WARNING: got ${HTTP_CODE} (expected 403)"
  fi
done

echo ""
echo "==> Results: ${BLOCKED}/${TOTAL} attacks blocked"

if [[ "${BLOCKED}" -eq "${TOTAL}" ]]; then
  echo "WAF appears to be working correctly"
else
  echo "Check the Envoy Gateway WAF configuration and logs:"
  echo "  kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway | grep -i -E 'coraza|denied'"
  exit 1
fi
