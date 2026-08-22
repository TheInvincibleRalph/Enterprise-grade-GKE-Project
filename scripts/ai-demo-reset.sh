#!/bin/bash
# Reset the inference demo state. The worker is stopped first: it can hold a
# job in its retry loop and would otherwise requeue it after the flush,
# polluting the fresh queue. Then the queue, the processing list, and any
# stored results are emptied, and the worker starts again.
set -euo pipefail

kubectl scale deploy/queue-worker -n ai-inference --replicas=0
kubectl wait --for=delete pod -l app=queue-worker -n ai-inference --timeout=60s
kubectl exec -n ai-inference deploy/redis -- redis-cli del inference_queue > /dev/null
kubectl exec -n ai-inference deploy/redis -- redis-cli del inference_processing > /dev/null
kubectl exec -n ai-inference deploy/redis -- redis-cli --scan --pattern 'result:*' |
  while read -r key; do
    kubectl exec -n ai-inference deploy/redis -- redis-cli del "$key" > /dev/null
  done
kubectl scale deploy/queue-worker -n ai-inference --replicas=1
kubectl rollout status deploy/queue-worker -n ai-inference --timeout=120s

echo "inference demo state reset: worker restarted, queue, processing list, and results are empty"
