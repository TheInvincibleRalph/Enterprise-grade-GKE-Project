# [Part 8][Optional] Observability with Datadog

*The agent on every node, the dashboards in the SaaS: the cluster watched from the outside.*

In Part 7, Prometheus scraped in-cluster endpoints, and Grafana rendered them. Datadog works differently: it deploys a DaemonSet of Agent pods that stream metrics, logs, and process data to the Datadog SaaS, where dashboards and monitors are created.

---

## Step 1: Create the account

Sign up at app.datadoghq.com through the GitHub Student Pack's Datadog benefit, which grants free credits.

After login, look at the URL. The site segment is your region: datadoghq.com (US1), us3.datadoghq.com, us5.datadoghq.com, datadoghq.eu.

Organization Settings → API Keys → New Key. Copy it.

---

## Step 2: Install the Agent

The chart installs three things: the Agent as a DaemonSet (one pod per node), the cluster agent, and the cluster agent's metrics provider.

```bash
export DD_API_KEY="<your-key>" # replace with your API key.

helm repo add datadog https://helm.datadoghq.com
helm repo update

# Set the site to your account's region, e.g. us5.datadoghq.com
helm upgrade --install datadog datadog/datadog \
  --namespace datadog --create-namespace \
  --set datadog.apiKey="$DD_API_KEY" \
  --set datadog.site="<region>.datadoghq.com" \
  --set datadog.apm.enabled=true \
  --set datadog.logs.enabled=true \
  --set datadog.logs.containerCollectAll=true \
  --set datadog.processAgent.enabled=true \
  --set datadog.clusterAgent.enabled=true \
  --set datadog.clusterAgent.metricsProvider.enabled=true \
  --set providers.gke.cos=true
```

The flags, briefly:

- `apm.enabled`: trace collection. The agent is ready; the apps still need a tracer library for traces to appear. The plumbing is in place either way.
- `logs.enabled` + `containerCollectAll`: every container's stdout is streamed and searchable. Zero instrumentation.
- `processAgent`: live processes per node and per pod.
- `clusterAgent` + `metricsProvider`: node-level state aggregated, and cluster metrics exposed as Datadog metrics. That is the hook for external autoscaling later in this series.
- `providers.gke.cos=true`: the fix GKE's Container-Optimized OS requires. Its kernel paths are read-only, and without this flag the system-probe container fails to start.

---

## Step 3: Verify

```bash
kubectl get pods -n datadog    # one agent per node + the cluster agent
```

---

## Step 4: Build the dashboards with Bits

We will not be building the dashboards by hand. We will use Bits, Datadog's in-product AI assistant. Bits reads the Datadog API for what the agent in each node ships, writes the dashboard definitions, and saves them.

Feed Bits with this prompt:

```text
Build a full-stack monitoring dashboard for my Kubernetes cluster kube_cluster_name:devops-portfolio. Cover infrastructure (CPU, memory, disk, load), Kubernetes health (nodes, pods, deployments, restarts), application workloads (Online Boutique in kube_namespace:boutique), database (ha-postgres in kube_namespace:database), network, and logs. Anything that is trackable.
```

This is the resulting dashboard with the different sections.

[image: the Full-Stack Overview dashboard]

You can scope the dashboard view to a namespace or a deployment or host ($kube_namespace, $kube_deployment, $host).

For the event this series has been replaying since Part 6, we also want a dashboard that watches the failover itself. Feed Bits this:

```text
Build a dashboard named "Database Failover Validation" to watch the PostgreSQL failover event for the ha-postgres cluster in kube_namespace:database: transactions per second, active connections, replication lag, and pod readiness, scoped to kube_cluster_name:devops-portfolio.
```

This is the resulting dashboard:

[image: the failover dashboard]

---

## Step 5: Setting Up an Alert for Failover

We will be setting up a monitor specifically for our database failover event. A monitor is a query with a threshold and a notification.

```text
Create a metric monitor named "PostgreSQL Failover Detected", scoped to kube_cluster_name:devops-portfolio, kube_namespace:database, and condition:true. Group by pod_name so each pod is monitored individually. Use min aggregation over a 1-minute window, alerting when it drops below 1. Set require_full_window: false. Notify @<your-email>, set priority P1, link to the Full-Stack Overview dashboard.
```

Then run the test:

```bash
./scripts/test-failover.sh
```

[image: the alert email]

---

## What's next

The cluster is now watched from both sides: Grafana inside, Datadog outside. The next part turns the manual kill into an automated discipline: **Chaos Mesh** takes the `kubectl delete pod` of Part 6 and makes it a repeatable experiment, pod kills, network latency, CPU stress, node failures, each one validating a steady-state hypothesis the way Part 6 validated its own. The dashboards from the last two parts are the evidence layer those experiments will be read against.
