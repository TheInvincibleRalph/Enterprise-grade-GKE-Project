# [Part 7] Observability: Prometheus, Grafana, and Datadog

*Prometheus scrapes, Grafana renders, Datadog receives: the cluster watched continuously.*

In Part 6 the failover was observed through a poll loop printing one line every two seconds. In this part we replace the loop with a monitoring stack: **Prometheus** scrapes metrics from every component, **Grafana** turns the scrapes into dashboards, and **Datadog** receives the same telemetry on the platform enterprise teams run. The claims of the previous part (synchronous replication, zero failed transactions, WAF blocking) become panels watched continuously instead of receipts read after the fact.

---

## Prometheus Exporters

Ever wondered how Grafana can render metrics from across your entire infrastructure without complex logic on your side?

Like we will see with CloudNativePG and Cilium, modern cloud-native tools make this effortless by exposing their telemetry through native exporters, each serving its metrics on an HTTP endpoint. Because Prometheus is a pull-based metrics server, it scrapes those endpoints (`/metrics` or `/stats/prometheus`) on a schedule and stores the samples in a time series database.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword="admin" \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

kubectl get pods -n monitoring     # prometheus, operator, grafana, alertmanager, exporters Running
```

---

## Step 1: CloudNativePG Exporter

**CloudNativePG** ships a metrics exporter in every instance and can generate a PodMonitor for it, but it is off by default. To switch it on, run this command:

```bash
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"monitoring":{"enablePodMonitor":true}}}'

kubectl get podmonitor -n database # ha-postgres
kubectl get podmonitor -n database ha-postgres -o yaml
```

The PodMonitor is a Custom Resource Definition object that tells Prometheus to bypass Kubernetes Services and scrape the individual PostgreSQL pods directly on port 9187. The reason you get `ha-postgres` as the name of the PodMonitor is that CloudNativePG names it after the cluster.

Now check that Prometheus sees the exporter

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```
Then http://localhost:9090/targets. Search for "ha-postgres" → targets UP on port 9187

## Step 2: Cilium Exporter

We installed **Cilium** in Part 4 with `prometheus.enabled: true` already on, but `serviceMonitor` deliberately left off with a comment to revisit it.

Now, let's switch it on:

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.18.12 \
  --values kubernetes/cilium/values.yaml \
  --set prometheus.serviceMonitor.enabled=true
```

---

## Step 3: The PostgreSQL dashboard

Grafana is now listening on the `monitoring-grafana` service:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 8080:80
# http://localhost:8080, admin/admin
```

Set up a new password when prompted, or skip.

Dashboards → New → Import → 20417 → Load. This is CloudNativePG's official dashboard, datasource: Prometheus. It renders the CNPG metrics: transactions per second, connection count, replication lag per replica, cache hit ratio, WAL generation rate.

The panels for replication lag are the interesting ones. They are drawn from the instance metrics CNPG exports per pod, so every instance appears as its own series, labeled by instance name. That is what makes the failover visible later in this part: `ha-postgres-1`'s series dies and `ha-postgres-2`'s takes over the primary workload.

---

## Step 4: The Envoy metrics pipeline

Envoy Gateway already exports rich metrics, but for the sake of discovery we need to do two things: deploy a Service that exposes the metrics port, and deploy a ServiceMonitor that tells Prometheus to scrape it.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: envoy-admin-metrics
  namespace: envoy-gateway-system
  labels:                                # required: SM selector matches on these
    app.kubernetes.io/name: envoy
    app.kubernetes.io/component: proxy
spec:
  selector:
    app.kubernetes.io/name: envoy
    app.kubernetes.io/component: proxy
  ports:
    - name: metrics
      port: 19000
      targetPort: 19001
```

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-metrics
  namespace: envoy-gateway-system
  labels:                                # required: Prometheus selects SMs by release label
    release: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: envoy      # + component: proxy → ONLY the data plane,
      app.kubernetes.io/component: proxy #   never the controller's service
  endpoints:
    - port: metrics
      path: /stats/prometheus
      interval: 30s
```

---

## Step 5: Watch the targets come up

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# http://localhost:9090/targets: search "envoy" → UP, address 10.1.x.x:19001
```

A target that shows `UP` is the whole pipeline proven: the ServiceMonitor matched, Prometheus resolved the endpoints, and the scrape succeeded. The panels are downstream of this screen, so this is the first thing to check when a dashboard is empty.

Then generate traffic so the panels have data:

```bash
curl -s https://boutique.invincibledevops.tech/ > /dev/null
./scripts/waf-test.sh https://boutique.invincibledevops.tech/
```

One expected noise: the `coredns` target is always `down` on GKE (kube-dns does not expose port 9153). Ignore it.

---

## Step 6: The WAF dashboard

The WAF dashboard is three panels, and it lives in the repo as a ready-to-import JSON: `kubernetes/envoy/waf-dashboard.json`. Import it:

1. In Grafana: **Dashboards → New → Import**.
2. Paste the contents of `kubernetes/envoy/waf-dashboard.json` into the import box, or upload the file with the upload button.
3. Click **Load**. The data source field comes pre-bound to the Prometheus datasource UID `prometheus`, so confirm and click **Import**.

The dashboard renders immediately. Two things to know about this flow:

- **The datasource is bound by UID, not by placeholder.** The JSON targets the datasource UID `prometheus` (the one kube-prometheus-stack provisions). If a dashboard uses the `${DS_PROMETHEUS}` placeholder instead, the import dialog can silently leave it unbound and every panel renders `No data`.
- **`envoy_http_downstream_rq_403` does not exist.** Envoy Gateway disables per-status-code counters. The 4xx class on the data-plane listener (`http-10080`) is the proxy for WAF blocks. Every Coraza 403 shows up there.

What's inside, in case you want to verify the queries or build the panels by hand:

| Panel | PromQL |
|---|---|
| Request rate by status code | `sum(rate(envoy_http_downstream_rq_xx[5m])) by (envoy_response_code_class)` |
| 403s blocked (WAF) | `sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="4",envoy_http_conn_manager_prefix="http-10080"}[5m]))` |
| Latency p50 / p95 / p99 | `histogram_quantile(0.50, sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le))` (swap `0.50` → `0.95` → `0.99`) |

Building them by hand is the same work: **Dashboards → New → New Dashboard → + Add visualization**, pick Prometheus, then switch the query editor from Builder to **Code** mode and paste the query. Panel 1 needs Options → Legend → **Custom** → `{{envoy_response_code_class}}` so each code class is its own series. Panel 3 is three queries in one panel (use **+ Query** for B and C, quantiles 0.50/0.95/0.99, legends p50/p95/p99, unit ms).

---

## Step 7: Watch the failover live

This is the moment the whole stack has been leading to. In Part 6 the failover was seen through a poll loop: one sample every two seconds, printed as text. Now the same event runs while the PostgreSQL dashboard renders:

```bash
./scripts/test-failover.sh
```

What the panels show during the kill:

1. The connection count and tps drop to zero the moment the leader pod dies. The pgbench clients were exec'd into that pod, so they die with it. That is the known behavior from Part 6, now visible as a graph instead of an exit code.
2. `ha-postgres-1`'s instance series disappears. The cluster phase moves through `Failing over` to healthy in roughly 20 seconds, and `ha-postgres-2`'s series comes up carrying the primary workload.
3. The WAF panel is live in the same session: run `./scripts/waf-test.sh https://boutique.invincibledevops.tech/` while watching it, and each blocked request is a spike in the 4xx series.

The poll loop from Part 6 was honest but primitive. Prometheus scrapes every 30 seconds per target and the dashboard renders continuously, so the transition is a graph you watch happen, not a log line you read after.

---

## Step 8: Datadog

The same cluster, on the platform enterprise teams run. The Datadog Agent is installed as a DaemonSet (one pod per node) plus a cluster agent, and it forwards metrics, logs, and APM data to the Datadog SaaS.

The account comes from the GitHub Student Pack. The one manual step is the API key: Datadog → Organization Settings → API Keys → New Key.

```bash
export DD_API_KEY="<your-key>"

helm repo add datadog https://helm.datadoghq.com
helm repo update

helm upgrade --install datadog datadog/datadog \
  --namespace datadog --create-namespace \
  --set datadog.apiKey="$DD_API_KEY" \
  --set datadog.site="us5.datadoghq.com" \
  --set datadog.apm.enabled=true \
  --set datadog.logs.enabled=true \
  --set datadog.logs.containerCollectAll=true \
  --set datadog.processAgent.enabled=true \
  --set datadog.clusterAgent.enabled=true \
  --set datadog.clusterAgent.metricsProvider.enabled=true \
  --set providers.gke.cos=true
```

Two flags carry the hard-won lessons:

- **`datadog.site` must match your account.** Datadog accounts are region-specific. If the key is rejected with `API Key invalid`, check the URL after login (`datadoghq.com`, `us3.datadoghq.com`, `us5.datadoghq.com`, `datadoghq.eu`) and set the site to match.
- **`providers.gke.cos=true` is required on GKE.** GKE's Container-Optimized OS keeps kernel paths read-only, and without this flag the system-probe container fails to create `/usr/src` and every agent pod lands in `CreateContainerError`. The flag fixes the mount itself. The trade-off: no eBPF network/security monitoring on COS; metrics, APM, logs, and the host map all still work.

Verify the agent is actually talking to Datadog, because the failure mode is silent:

```bash
kubectl get pods -n datadog    # datadog-agent-* (one per node) + cluster agent

# An unset $DD_API_KEY at install time writes an EMPTY key. Pods look
# healthy; Datadog just never receives anything.
kubectl exec -n datadog <agent-pod> -- agent status | grep -i "API key"
```

Then Infrastructure → Host Map: the six nodes appear within minutes.

One honest trade-off to plan around: the agent is the heaviest component on this cluster. On the 1-vCPU/4 GB application nodes that already run the storefront, Postgres, and the monitoring stack, if pods start going `Pending`, the first trim is `--set datadog.processAgent.enabled=false` (the CPU-hungriest piece, and the least essential for the demo).

The portfolio payoff is the same failover test on an enterprise platform: re-run `./scripts/test-failover.sh` with the Host Map open and watch the node hosting the leader take the load hit, then the node hosting the promoted replica pick it up. A real production tool showing a real production event on this trial cluster.

[image]

---

## To understand what this config achieves, I will highlight the decisions that shaped it.

### 1. The whole stack is one Helm chart, and the two selector flags are the contract.

`kube-prometheus-stack` installs the operator, Prometheus, Grafana, Alertmanager, and the node exporters in one shot. The Prometheus the operator creates uses label selectors to decide which monitors it honors, and by default those selectors are pinned to the chart's own release. Every monitor in this part lives in another namespace (`database`, `envoy-gateway-system`, `kube-system`). The two `NilUsesHelmValues=false` flags relax an empty selector to "match everything", which is what lets monitors from anywhere in the cluster become scrape jobs. Without them, CNPG and Envoy metrics would be invisible and every dashboard would render `No data` while Prometheus runs perfectly.

### 2. Monitors are declarations, not configuration.

Nothing in this part edited Prometheus' config. CNPG's PodMonitor comes into existence because the Cluster CR says `enablePodMonitor: true`; the Envoy scrape job exists because a ServiceMonitor object exists; Cilium's job exists because its Helm values say so. The operator translates those objects into `prometheus.yml` and reloads. That is the pattern that scales: adding a monitored component is writing a small YAML object, never touching a config file.

### 3. The Envoy wiring is three objects, each with a silent failure mode.

A metrics port, a Service, and a ServiceMonitor. Each one fails quietly: the wrong port (19000 instead of 19001) registers a dead target; a missing label latches the ServiceMonitor onto the wrong Service; a missing `release: monitoring` label means no scrape job is generated at all. The fixes are all in the manifests above, and the verification order matters: the targets page is checked before any panel is built, because a dashboard with a dead target is indistinguishable from a dashboard with a wrong query.

### 4. The WAF's 403s are read from the data-plane listener, not a WAF metric.

Coraza blocks show up as 4xx responses from Envoy, and Envoy Gateway v1.8 does not expose per-status-code counters, so `envoy_http_downstream_rq_403` does not exist as a metric. The honest signal is the 4xx class rate on the listener that actually serves traffic (`http-10080`), separated from the controller's listener by the conn-manager prefix. The WAF dashboard is therefore built on the classes that do exist, and the "blocked" panel is the 4xx series on the data plane. In Part 5 the WAF was proven with curl exit codes; now the same proof is a live graph.

### 5. Datadog on GKE COS costs the eBPF probes, and that is a fair trade on this cluster.

The COS fix (`providers.gke.cos=true`) and the read-only `/usr` failure are GKE-specific; on a stock Linux node pool the chart installs without them. Losing system-probe means no network/security monitoring from the agent, but metrics, APM, logs, and the host map all work, and those are what the demo needs. The empty-key trap is the worst of the three bugs because it is invisible: every pod healthy, zero data received. The `agent status` check is part of the procedure precisely because the install reports success either way.

### 6. Every component is sized for 1-vCPU nodes.

The trial's resource budget shaped every choice: the stack runs on the existing node pools with no new nodes, monitors scrape at 30-second intervals instead of aggressive defaults, and the Datadog agent, the heaviest process on the cluster, has a documented first trim (`processAgent`) if scheduling pressure appears. On a trial, observability is itself a workload to budget, and it gets the same treatment as the database got in Part 6: requests that fit, limits that cap.

---

## What's next

The manual kill in Part 6 is now a watched event: the failover renders on dashboards and on the Datadog host map as it happens. The next part turns the manual kill into an automated discipline. **Chaos Mesh** takes the `kubectl delete pod` of Part 6 and makes it a repeatable experiment: pod kills, network latency, CPU stress, node failures, each one injected on a schedule and each one validating a steady-state hypothesis the way Part 6 validated its own. The dashboards from this part are the "during" evidence layer for those experiments.
