# Troubleshooting

## General Diagnostics

### Check All Pods

```bash
# Everything across all namespaces, with node placement
kubectl get pods -A -o wide

# Just the namespaces this platform owns
kubectl get pods -n boutique -n database -n ai-inference -n monitoring -n envoy-gateway-system -n datadog -n chaos-mesh

# Recent events in a namespace, most useful first
kubectl get events -n <namespace> --sort-by=.lastTimestamp
```

### View Logs

```bash
kubectl logs -n <namespace> deploy/<deployment-name> --tail=100
kubectl logs -n <namespace> <pod-name> -f

# Previous container (crash loops)
kubectl logs -n <namespace> <pod-name> --previous
```

### Check Service Connectivity

```bash
# A Service with no ready endpoints fails with [Errno 1] Operation not permitted (EPERM).
# Check the endpoint list first; an empty list explains the connection error.
kubectl get endpoints -n <namespace> <service-name>
kubectl get pods -n <namespace> -l app=<app-name> -o wide
```

## kubectl Context Issues

### Helm Fails with "cluster reachability check failed"

Helm validates the cluster from the active kubeconfig context before installing anything. If the terminal's context points at a cluster that no longer exists, every `helm install` aborts immediately:

```text
Error: INSTALLATION FAILED: cluster reachability check failed: kubernetes cluster unreachable:
Get "https://B459CE....us-east-2.eks.amazonaws.com/version":
dial tcp: lookup ... no such host
```

1. Check which context is active:
   ```bash
   kubectl config current-context
   kubectl config get-contexts
   ```
2. Point kubectl at the GKE cluster:
   ```bash
   gcloud container clusters get-credentials devops-portfolio \
     --region us-central1 --project devops-portfolio-prod
   ```
3. Confirm the context changed and the nodes answer:
   ```bash
   kubectl config current-context   # must contain gke_devops-portfolio-prod_us-central1_devops-portfolio
   kubectl get nodes
   ```
4. Re-run the helm command. Nothing was installed before the check, so there is nothing to clean up.

### `invalid_rapt` / Reauthentication Required from gcloud

The console login goes stale after weeks of inactivity and gcloud demands reauthentication:

```text
ERROR: (gcloud.auth.login) ... Your credentials may have expired. Please re-authenticate
```

1. Try the normal refresh first:
   ```bash
   gcloud auth login
   ```
2. If the browser flow is not an option, authenticate as the Terraform service account with its emergency key (this is exactly what `terraform-key.json` exists for):
   ```bash
   gcloud auth activate-service-account \
     terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com \
     --key-file=/path/to/terraform-key.json
   gcloud container clusters get-credentials devops-portfolio \
     --region us-central1 --project devops-portfolio-prod
   ```
3. Restore the human login later with `gcloud auth login`.

## gcloud Auth Issues

### Error: storage.NewClient() failed: could not find default credentials

Terraform authenticates through Application Default Credentials (ADC), not the `gcloud auth login` browser profile:

```text
│ Error: storage.NewClient() failed: dialing: credentials: could not find default credentials.
```

1. Create the ADC profile once, impersonating the Terraform service account:
   ```bash
   gcloud auth application-default login \
     --impersonate-service-account=terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com
   ```
2. Verify:
   ```bash
   gcloud auth application-default print-access-token > /dev/null
   ```
3. Use `gcloud auth login` for human gcloud commands, and ADC for code and tools (Terraform, Python scripts). The two profiles are separate.

### Terraform Fails with a 403 That Looks Like an Auth Problem

A 403 from the state backend is often a permissions problem, not a token problem:

1. Confirm the service account can reach the state bucket:
   ```bash
   gcloud storage ls gs://devops-portfolio-tfstate/
   ```
2. The Terraform SA must hold storage admin on the project, otherwise Terraform cannot read or write the bucket:
   ```bash
   gcloud projects add-iam-policy-binding devops-portfolio-prod \
     --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
     --role="roles/storage.admin"
   ```

### GOOGLE_APPLICATION_CREDENTIALS Overrides Impersonation

If `GOOGLE_APPLICATION_CREDENTIALS` is set in the shell, it points the provider at a key file instead of the ADC impersonation profile, and Terraform fails with credentials errors that reference a file that does not exist.

1. Unset it in every shell that runs terraform:
   ```bash
   unset GOOGLE_APPLICATION_CREDENTIALS
   ```
2. Do not add a `credentials` line to the provider block in `infra/terraform/main.tf`; it overrides ADC the same way.

## Terraform Issues

### Flaky Apply Silently Skips a CRD

A connection blip mid-apply can leave a CRD missing while the rest of the apply reports success. The operator then crash-loops:

```text
no matches for kind "Pooler"
```

1. Verify the CloudNativePG CRD count after every apply:
   ```bash
   kubectl get crd | grep cnpg
   ```
2. Re-apply the operator manifest if any CRD is missing:
   ```bash
   kubectl apply -f \
     https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
   ```

### "array index out of bounds" in a jsonpath Query

```text
Error: executing template: array index out of bounds: index 0, length 0
```

This is a race, not an error: the pods do not exist yet. Re-run once the deployment is Ready.

### Node Pool Updates Hang at the Instance Quota Cap

At the trial's instance quota (8 instances), node pool changes cannot surge, so GKE drains and replaces nodes sequentially. A 30-minute terraform timeout does not mean failure:

```bash
gcloud container operations list --filter="status=RUNNING" \
  --region us-central1 --project devops-portfolio-prod
gcloud container operations wait <OP_ID> --region us-central1
```

### `kubectl patch` Fails with "image: Required value"

Strategic-merge patches can fail when the OpenAPI schema fetch stalls on a slow network. Use a JSON patch or edit the manifest and apply it instead:

```bash
kubectl apply -f <edited-manifest.yaml>
```

## Networking Issues

### Port 19001, Not 19000 (Envoy Gateway Metrics)

Envoy Gateway v1.8 exposes the metrics listener on port 19001. A Service or monitor pointing at 19000 registers a target that is never up:

1. Check the proxy's listening ports:
   ```bash
   kubectl exec -n envoy-gateway-system <envoy-pod> -- ss -lntp
   ```
2. Point the metrics Service at 19001, and make sure it carries the selector labels `app.kubernetes.io/name=envoy` and `component: proxy`.

### ServiceMonitor Never Gets a Scrape Job

kube-prometheus-stack's Prometheus selects monitors by label:

1. The ServiceMonitor needs `release: monitoring`:
   ```bash
   kubectl get servicemonitors -n envoy-gateway-system --show-labels
   ```
2. Check whether Prometheus actually picked it up:
   ```bash
   kubectl exec -n monitoring <prometheus-pod> -- cat /etc/prometheus/prometheus.yml | grep -i envoy
   ```
3. Without the label, re-apply with it; without it, no scrape job exists, and every panel renders `No data`.

### coredns Target Is Always Down

On GKE, the `coredns` target shows `down` because kube-dns does not expose port 9153. It is expected noise, not a fault.

## Envoy Gateway and WAF Issues

### WAF Test Does Not Return 403

```bash
./scripts/waf-test.sh <lb-ip>
```

1. Confirm the route accepts the hostname first (a plain request must answer 200, not 404):
   ```bash
   curl -H "Host: boutique.invincibledevops.tech" http://<lb-ip>/
   ```
2. Confirm the WAF extension policy is applied and the Coraza module loaded:
   ```bash
   kubectl get extensionpolicy -n envoy-gateway-system
   kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway | grep -i coraza
   ```
3. Fire one known payload directly:
   ```bash
   curl -H "Host: boutique.invincibledevops.tech" \
     "http://<lb-ip>/?id=1'+OR+'1'='1"
   ```
   Expected: `403` with a Coraza deny log entry.

### `envoy_http_downstream_rq_403` Does Not Exist

Envoy Gateway disables per-code counters. The WAF's 403s appear in the 4xx class on the data-plane listener `http-10080`:

```promql
sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="4",envoy_http_conn_manager_prefix="http-10080"}[5m]))
```

### Clients Get HTTP 403 with Cloudflare Error Code 1010

Cloudflare blocks the default `Python-urllib/3.x` user agent with 403 error code 1010, while curl (and the browser) pass. The health check works, the submission fails:

1. Reproduce with a raw urllib request, then with curl, to isolate the user agent.
2. Send an explicit, non-default user agent on every request:
   ```python
   headers = {"Content-Type": "application/json", "User-Agent": "devops-portfolio/1.0"}
   ```
3. Keep the same headers on GETs (result polling) as on POSTs (submission).

### Coraza Dynamic Module Fails to Load

The in-process Coraza module (composer image) is a development build and requires a recent GKE minor version for image volumes. If the proxy fails to start or the module never loads:

1. Check the proxy logs for module load errors:
   ```bash
   kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway
   ```
2. Fall back to the Coraza proxy-wasm connector via the EnvoyExtensionPolicy if the dynamic module cannot load on your GKE version.

## Database Issues (CloudNativePG)

### pgbench Fails with `relation "pgbench_branches" does not exist`

The benchmark database must be named. Omitting the database runs pgbench against `postgres`, which has no tables:

```bash
kubectl exec -n database <leader-pod> -- \
  pgbench -U postgres -d app -i -s 100
```

### pgbench Fails Mid-Init with "No space left on device"

`pgbench -s 100` needs roughly 1.4 GB. The original 1 Gi volumes fill up during initialization. Give the database at least 2 Gi, or use a smaller scale factor on constrained nodes.

### zsh Breaks Pasted Commands with Inline Comments

zsh does not treat `#` as a comment inside pasted commands:

```text
pods "#" not found
```

Put comments on their own line, or drop them when pasting into zsh.

### Leader Deletion and Automatic Failover

The operator recreates deleted instances automatically. `--force` deletion is not needed and skips the graceful switchover dance. During a 50-client load test, a 1-vCPU leader failed its readiness probes and CNPG failed over by itself with 0 failed transactions in the final pgbench report. Check the result of a failover run with:

```bash
grep -c "ERROR\|FATAL" write_log.txt    # expected: 0 or a few transient, auto-retried lines
```

## Observability Issues

### Datadog: "API Key invalid"

Datadog accounts are region-specific. A rejected key usually means the account lives on a different site than `datadoghq.com`:

1. Check the site in your browser URL after login: `datadoghq.com` (US1), `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`.
2. Set the matching site at install time:
   ```bash
   --set datadog.site="us5.datadoghq.com"
   ```
3. Verify from inside an agent pod:
   ```bash
   kubectl exec -n datadog <agent-pod> -- agent status | grep -i "API key"
   ```

### Datadog: Empty API Key Secret (Silent Failure)

If `$DD_API_KEY` is unset at install time, the chart writes an empty key and every agent runs unauthenticated. Pods look healthy and Datadog just never receives anything.

1. Check the secret:
   ```bash
   kubectl get secret -n datadog datadog-api-key -o jsonpath='{.data.api-key}' | base64 -d | wc -c
   ```
2. Fix by writing the key straight into the secret and restarting the agents:
   ```bash
   kubectl create secret generic datadog-api-key -n datadog \
     --from-literal=api-key=<KEY> --dry-run=client -o yaml | kubectl apply -f -
   kubectl rollout restart daemonset/datadog -n datadog
   ```

### Datadog system-probe Fails on GKE COS

```text
CreateContainerError: mkdir /usr/src: read-only file system
```

GKE's Container-Optimized OS keeps kernel paths read-only, so the system probe cannot mount them. Install with the chart's GKE flag:

```bash
--set providers.gke.cos=true
```

This loses only eBPF network/security monitoring; metrics, APM, logs, and the host map all work.

### Datadog Pods Pending on 1-vCPU Nodes

The agent is the heaviest component on this cluster. If pods start going Pending after the Datadog install, the first trim is the process agent:

```bash
--set datadog.processAgent.enabled=false
```

### Grafana Dashboard Imports with "No data"

Imported dashboards bind the datasource by UID. The provisioned datasource is `monitoring-kube-prometheus-grafana-datasource`, so import with the literal UID `prometheus`:

1. If a dashboard uses the `${DS_PROMETHEUS}` placeholder instead, the import dialog can silently leave it unbound and every panel renders `No data`.
2. Re-import with UID `prometheus`, or edit the datasource variable after import.

## AI Inference Issues (KEDA, Ollama, Redis)

### Model Pod Stuck in Pending for 10+ Minutes

The model disk is zonal in `us-central1-b`, so the pod must land on a node in that zone. If the only application node there is saturated on CPU requests, the scheduler waits and the autoscaler cannot add nodes:

```text
FailedScaleUp ... GCE quota exceeded
```

1. Check the pod and the node's allocatable CPU:
   ```bash
   kubectl describe pod -n ai-inference -l app=ollama | grep -A 5 Events
   kubectl describe node <us-central1-b-node> | grep -A 4 "Allocated resources"
   ```
2. The disk is zonal: verify the PVC zone matches a node that has headroom:
   ```bash
   kubectl get pvc -n ai-inference ollama-models -o jsonpath='{.spec.volumeName}'
   ```
3. Free CPU on that node (scale the storefront workloads down temporarily):
   ```bash
   kubectl scale deploy/frontend deploy/adservice deploy/recommendationservice \
     deploy/shippingservice deploy/redis-cart -n boutique --replicas=0
   ```
   The pod schedules within about a minute. Restore the replicas afterwards.

### No Pod to Exec Into (Scale-to-Zero)

Once KEDA is live, an empty queue drops `ollama` to 0 replicas after 60 seconds, and there is no pod to exec into. This breaks `kubectl exec` workflows like `ollama pull`:

1. Pull the model onto the persistent disk before installing KEDA:
   ```bash
   kubectl exec -n ai-inference deploy/ollama -- ollama pull llama3.2:3b
   ```
2. If KEDA is already live and the disk is empty, wake the model first: push one job through the API, or temporarily set `minReplicaCount: 1` in `kubernetes/ai/scaledobject.yaml`, then pull.

### Inference API Answers 503

`/result/<id>` answers `503` with `{"status":"unavailable"}` when Redis is briefly unreachable. It is a contract, not a fault: 503 means "try again" for the client. A client that treats any 5xx as retryable handles it; nothing crashes.

### Ghost Job Reappears in the Queue After a Reset

A worker mid-retry holds its job in memory. Flushing the queue while it retries lets it requeue the job after the flush, polluting the fresh state:

1. Stop the worker first, wait for the pod to go away, then flush:
   ```bash
   kubectl scale deploy/queue-worker -n ai-inference --replicas=0
   kubectl wait --for=delete pod -l app=queue-worker -n ai-inference --timeout=60s
   kubectl exec -n ai-inference deploy/redis -- redis-cli del inference_queue
   kubectl exec -n ai-inference deploy/redis -- redis-cli del inference_processing
   kubectl exec -n ai-inference deploy/redis -- redis-cli --scan --pattern 'result:*' |
     while read -r key; do
       kubectl exec -n ai-inference deploy/redis -- redis-cli del "$key" > /dev/null
     done
   kubectl scale deploy/queue-worker -n ai-inference --replicas=1
   ```
2. This is exactly what `./scripts/ai-demo-reset.sh` does; run the script instead of hand-rolling it.

### "[Errno 1] Operation not permitted" When Calling a Service

A ClusterIP Service with no ready endpoints fails with `[Errno 1] Operation not permitted` (EPERM), which looks nothing like a networking problem:

1. Check the endpoints and the backing deployment:
   ```bash
   kubectl get endpoints -n <namespace> <service-name>
   kubectl get pods -n <namespace> -l app=<app-name>
   ```
2. Scale the deployment back up, or use a port-forward to a specific pod for demos:
   ```bash
   kubectl port-forward -n ai-inference svc/inference-api 8080:8080
   ```

### Slim Images Have No curl

`ollama` and `python:3.12-slim` have no curl. Use `ollama run` inside the pod or Python's urllib. Also check for a local process on the same port before debugging a port-forward:

```bash
lsof -i :11434
```

### "Insufficient cpu" on Small Nodes

CPU requests are the scheduler's currency on 1-vCPU nodes; a 500m request is half a node. When a pod cannot schedule, either lower the request or free CPU on the target node (see the Pending section above).

## Chaos Mesh Issues

### PodChaos Rejects `spec.scheduler`

The installed Chaos Mesh CRD version rejects the `scheduler` field at the admission webhook:

```text
unknown field "scheduler"
```

The accepted fields are `action, containerNames, duration, gracePeriod, mode, remoteCluster, selector, value`. Set `duration` to make the kill ongoing and omit `scheduler`.

### NetworkChaos `direction: both` Requires `targets`

The NetworkChaos webhook rejects `both` and `from` with an empty `targets` list. Use `direction: to` (delay traffic arriving at the selected pods), which is the desired semantics for the database latency experiment.

### StressChaos Matches Nothing

A selector that matches no pods injects into nothing and the experiment looks successful while doing nothing. The trial cluster has no GPU nodes, so `role: gpu` matches zero pods; the verified variant stresses the Ollama pod (`app: ollama` in `ai-inference`), which doubles as an autoscaling validation: CPU stress, degraded inference, growing queue, KEDA compensates.

## Kill Switch Issues

### Function Deploys ACTIVE but Never Runs

The budget alert itself must publish to the topic. In the console: Billing, Budgets and Alerts, your budget, Manage notifications, check "Notify on Pub/Sub topic", select `budget-alerts`. Without that, the function is deployed but never triggered.

### `--source` Defaults to the Current Directory

Run the deploy from the repo root and point at the function folder, or the deploy fails with "does not have file [main.py]":

```bash
gcloud functions deploy budget-kill-switch \
  --runtime python312 \
  --trigger-topic budget-alerts \
  --set-env-vars GCP_PROJECT=devops-portfolio-prod \
  --source functions/budget-kill-switch \
  --region us-central1 \
  --gen2 \
  --entry-point kill_switch
```

### gen2 Python Deploy Fails at Source Validation

gen2 Python requires a `requirements.txt` (`google-api-python-client`); without it the deploy fails at source validation.

### `--entry-point` Mismatch

A mismatch builds fine but the container fails its health check at startup:

```text
failed to start and listen on PORT=8080
```

`--entry-point` must match the function name in `main.py` (`kill_switch`).

### The Interactive Region Prompt Wants a Number

Without `--region`, the prompt expects a numeric choice, and the wrong number deploys to the wrong continent. Always pass `--region us-central1`.

### The Function Stops Instances, Not the Cluster

The kill switch stops every compute instance in the cluster zones (`us-central1-b/c/f`). A full stop would also scale node pools to 0; extend `main.py` if you need the complete shutdown.

## Common Issues

### Pods in Pending

1. `kubectl describe pod -n <namespace> <pod-name> | grep -A 10 Events` and read the last event: `Insufficient cpu`, `0/6 nodes available`, `FailedScaleUp`.
2. Free CPU on the target zone or reduce requests (see the AI Pending section for the full drill on a zonal-disk variant).
3. Remember the node pools run at the instance quota cap, so autoscaling may not be able to add nodes.

### Pods in CrashLoopBackOff

1. `kubectl logs -n <namespace> <pod-name> --previous` for the crash reason.
2. Known crash loops in this project: a CNPG operator missing CRDs (`no matches for kind "Pooler"`), a Datadog system probe on GKE COS (`mkdir /usr/src`), and a kill-switch entry-point mismatch (`failed to start and listen on PORT=8080`). Each has a fix above.

### Every Grafana Panel Renders "No data"

1. Confirm Prometheus has scrape jobs: `kubectl get servicemonitors -A --show-labels` and check `release: monitoring` labels.
2. Confirm the dashboard datasource binds the UID `prometheus`.
3. Expect `coredns` to stay down; it is noise.
