#!/usr/bin/env bash
set -euo pipefail


NAMESPACE="${NAMESPACE:-database}"
CLUSTER="${CLUSTER:-ha-postgres}"

echo "==> Starting continuous write load for 10 minutes (pgbench, 20 clients, 2 threads)"
kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE \
  -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') -- \
  pgbench -c 20 -j 2 -T 600 -P 10 -U postgres app &
LOAD_PID=$!

sleep 30 

echo "==> Killing the leader: no grace period, no SIGTERM — the harshest cut"
LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n $NAMESPACE $LEADER --grace-period=0 --force

for i in $(seq 1 30); do
  NEW_LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  STATUS=$(kubectl get cluster -n $NAMESPACE $CLUSTER -o jsonpath='{.status.phase}')
  echo "[$i] New leader: $NEW_LEADER | Cluster phase: $STATUS"
  sleep 2
done

wait $LOAD_PID || true 
echo "=== Load test finished ==="
