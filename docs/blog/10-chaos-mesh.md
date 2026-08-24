# [Part 9] Chaos Engineering with Chaos Mesh

*Define normal, inject fault, prove normal: the one-off kill becomes a repeatable experiment.*

In Part 6 the primary was killed with a single `kubectl delete pod`, run by hand every time. **Chaos Mesh** is the CNCF project that turns that one-off into a discipline: faults are declarative CRD objects that inject pod kills, network latency, and node failures on command. The dashboards from Parts 7 and 8 are the evidence layer, and the steady-state hypothesis is the rule: measure before, inject, measure after, compare.

---

## Step 1: Install Chaos Mesh

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true

kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333
# http://localhost:2333
```

The Helm chart installs the controller, the web UI, and the chaos-daemon on every node.

Then visit http://localhost:2333. The login page asks for a token; click **Click here to generate** and a popup shows a ready-made RBAC manifest, generated fresh for you: a service account bound to the chart's `cluster-manager` role, named with a random suffix like `account-cluster-manager-yprvu`. The popup refreshes the manifest every few seconds, so copy it before it changes.

[image: the RBAC manifest popup]

Save it as `rbac.yaml` in the project folder and apply it:

```bash
kubectl apply -f rbac.yaml
```

Then mint the token from the service account in the manifest you copied, and only that one:

```bash
kubectl -n chaos-mesh create token account-cluster-manager-yprvu
```

The name has to match exactly: the manifest and the token are a pair, and the dashboard rejects a token minted for any other account. The token expires in an hour, so re-run the command when the dashboard logs you out.

---

## Step 2: Define the steady state

Before any fault, write down what "normal" means, as a versioned ConfigMap. These are the targets measured before and after every experiment:

```yaml
# chaos/steady-state-check.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: steady-state-check
  namespace: chaos-mesh
data:
  boutique_app: |
    p99_latency: "< 500ms"
    error_rate: "< 1%"
    availability: "> 99.5%"
  postgres: |
    replication_lag: "< 100ms"
    failover_time: "< 30s"
    data_loss: "0"
```

The `ai_inference` block in the repo file waits for the AI part of the series.

---

## Step 3: Experiment 1, the storefront pod kill

```yaml
# chaos/pod-kill-app.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-boutique-pods
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: fixed-percent
  value: "50"                # Kill 50% of pods
  selector:
    namespaces:
      - boutique
    labelSelectors:
      app: frontend
  duration: "60s"            # Keep killing for 60 seconds
```

Apply it and watch: the frontend pods die and the Deployment replaces them, the storefront keeps answering, and the WAF dashboard from Part 7 shows the request rate dipping and recovering. The kill is no longer a command; it is a YAML object.

---

## Step 4: Experiment 2, the automated failover

The experiment this series has been leading to: the primary pod killed the way Part 6 did it, but as a repeatable object.

```yaml
# chaos/pod-kill-primary.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-postgres-primary
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - database
    labelSelectors:
      cnpg.io/instanceRole: primary
  duration: "60s"
```

Apply it, then watch the same event from Part 6, now fully automated:

1. The Grafana PostgreSQL dashboard (20417): the primary's series dies, `Failing over`, the promoted replica takes the workload. Healthy in under 30 seconds.
2. The Datadog PostgreSQL Failover Detected monitor: the killed pod's readiness drops, the alert fires, the email arrives.
3. pgbench during the experiment: zero failed transactions, the synchronous replication claim from Part 6 holding under a repeated kill.

Every kill inside the window is a fresh failover, and every one recovers.

---

## Step 5: Experiment 3, network latency on the database

```yaml
# chaos/network-delay-db.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: db-network-delay
  namespace: chaos-mesh
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - database
    labelSelectors:
      cnpg.io/cluster: ha-postgres
  delay:
    latency: "500ms"         # Insert 500ms latency
    correlation: "50"
    jitter: "100ms"
  duration: "120s"
  direction: to
```

This delays traffic arriving at the Postgres pods. The observation is the interesting part: the synchronous quorum from Part 6 absorbs it. Commit latency rises, tps drops, but there are no failed transactions, and once the experiment ends the replication lag closes within seconds. A half-second of injected latency on a database that acknowledges every write to a replica, and the steady state holds.

---

## Step 6: Experiment 4, node failure

A node loss is an operational event, so it gets an operational script, not a CRD:

```bash
./chaos/node-drain.sh
```

It cordons an application node and drains it: the storefront pods reschedule, and if the node held the primary, the failover runs again. Restore with `kubectl uncordon <node>`. This is the zone-failure story from Part 6, at the node level, with the same dashboards watching.

---

## Step 7: The WAF under chaos

The WAF runs in the data plane, outside the workloads being attacked. Run the Part 5 test while any experiment is active:

```bash
./scripts/waf-test.sh https://boutique.invincibledevops.tech/
```

Every attack still comes back 403 while pods are dying around it. The defense does not depend on the health of what it protects.

---

## What's next

The fault injection now covers everything this series built: the storefront, the database, the network, the nodes. The next part deploys the workload the remaining stress experiment was built for: an inference service on the cluster, with KEDA scaling it and its own block in the steady-state ConfigMap.
