#!/usr/bin/env bash
# This is an OPERATIONAL script (not a Chaos Mesh manifest): cordon + drain
# and is the realistic way to simulate a node/zone loss.
#
# Usage: ./chaos/node-drain.sh [NODE_NAME]   (defaults to an application node)
set -euo pipefail

NODE_TO_DRAIN="${1:-$(kubectl get nodes -l role=application -o jsonpath='{.items[0].metadata.name}')}"
echo "==> Draining node: ${NODE_TO_DRAIN}"

kubectl cordon "$NODE_TO_DRAIN"
kubectl drain "$NODE_TO_DRAIN" --ignore-daemonsets --delete-emptydir-data

echo ""
echo "==> Observe:"
echo "    - Pods reschedule to other nodes"
echo "    - Database replica (if affected) catches up from WAL"
echo "    - Application traffic shifts to remaining replicas"
echo "    - A new node is provisioned, and the number of nodes returns back to 6"
echo ""
echo "==> Restore:"
echo "    kubectl uncordon ${NODE_TO_DRAIN}"
