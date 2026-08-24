# [Part 6] Deploying a Highly Available PostgreSQL on Kubernetes with CloudNativePG, Load Testing It and Proving Failover Mechanism

*Leader election, synchronous replication, and self-healing storage*

In Part 5 the storefront went live behind the WAF, but needs a database. In this part we deploy **PostgreSQL as a fully managed, Kubernetes-native cluster** with CloudNativePG: one leader and two replicas spread across three zones, writes survive a leader dying mid-flight, and disk grows while the database keeps serving.

---

## Why CloudNativePG?

CloudNativePG is the Kubernetes operator that handles the full lifecycle of a highly available PostgreSQL database cluster. It provides cloud native capabilities like self-healing, high availability, rolling updates, scale up/down of read-only replicas, affinity/anti-affinity/tolerations for scheduling, and every other thing a human operator would do to deploy and manage a Postgres database within the Kubernetes environment.

Features we would be seeing in the implementation:

1. **Leader election*: This means the operator decides who the leader is, watches it, and promotes a replica automatically when it dies.
2. **Synchronous replication**: The leader refuses to acknowledge a write until at least one replica has it on disk so a leader that dies mid-write loses *nothing that was never acknowledged*.
3. **Storage grows in place**: The operator expands the underlying disk live when you bump the size in the spec. No downtime.

---


## Step 1 — Install the operator

```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml

# Verify ALL 6 CRDs landed (a dropped connection can silently skip one):
kubectl get crd | grep cnpg

# The controller crash-loops until every CRD exists — watch it come up:
kubectl get pods -n cnpg-system -w
```

## Step 2 — The Cluster CR: HA by declaration

The entire database — topology, replication, storage, backups — is this file:

```yaml
# kubernetes/cnpg/postgres-cluster.yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ha-postgres
  namespace: database
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4

  postgresql:
    synchronous:
      method: any
      number: 1

  affinity:
    enablePodAntiAffinity: true
    topologyKey: "topology.kubernetes.io/zone"

  resources:
    requests:
      memory: "512Mi"
      cpu: "250m"
    limits:
      memory: "1Gi"
      cpu: "1000m"

  storage:
    size: "1Gi"

  backup:
    retentionPolicy: "30d"
    barmanObjectStore:
      destinationPath: "gs://devops-portfolio-backups/postgres"
      googleCredentials:
        gkeEnvironment: true
      wal:
        compression: gzip
```

## The following resources were provisioned

1. **CloudNativePG operator** (`cnpg-system` namespace) with its 6 CRDs
2. **Cluster `ha-postgres`** (`database` namespace) — 3 instances, PostgreSQL 16.4
3. **`pg-backup-sa`** — a GCP service account bound to the cluster via Workload Identity
4. **`gs://devops-portfolio-backups`** — the GCS bucket backups land in

**To understand what this config achieves, I will highlight the decisions that shaped it.**

### 1. `instances: 3` — one leader, two replicas, and a label that says who's who.

The operator runs three Postgres pods: `ha-postgres-1` (the leader), `ha-postgres-2` and `ha-postgres-3` (replicas). Exactly one pod carries the `cnpg.io/instanceRole=primary` label — that label is how the rest of the world finds the leader, and the operator maintains it as a fact of life. It also creates the read-write service (`ha-postgres-rw`, always pointed at the leader) and the read-only service (`ha-postgres-ro`, spread across replicas) — so applications don't even need to know which pod is which.

### 2. One instance per zone — a zone failure costs one instance, never the cluster.

`enablePodAntiAffinity` + `topologyKey: topology.kubernetes.io/zone` tells the scheduler: never co-locate two of these pods in the same availability zone. A zone failure takes down exactly one instance — the quorum lives on, and with a leader + two replicas the cluster can still serve and still fail over. This is the same three-zone story as the cluster itself, applied one level down.

### 3. Synchronous replication — the commit that isn't acknowledged isn't lost.

With three instances we configure synchronous replication so the leader **waits for at least one replica to confirm a write on disk before acknowledging the client**. The switch is the `postgresql.synchronous` stanza in the Cluster CR: `method: any` with `number: 1`, which CNPG turns into the classic `synchronous_standby_names = 'ANY 1 (ha-postgres-2, ha-postgres-3)'`. The parameter is operator-managed, so it shows up in `SHOW synchronous_standby_names` but not in the YAML. The first replica to ack makes the commit durable; the third replays asynchronously. The trade-off is a write-latency cost (one round trip to a replica per commit) — and in exchange you get the strongest guarantee Postgres offers: **RPO ≈ 0**. When the leader dies, the promoted replica already holds every transaction the clients were told was committed. That is what makes the failover test at the end of this part pass with *zero failed transactions*.

### 4. Leader election by Operator

The operator owns leadership through a lease-based election, watches the leader's health, and on failure promotes the healthiest replica — moving the `cnpg.io/instanceRole=primary` label, re-pointing the `-rw` service, and letting the other replica re-sync. A PodDisruptionBudget protects the quorum during node drains, so a scheduled maintenance event can't accidentally take out two instances at once. The demo later in this post kills the leader *under a live write load* — and the load never notices.

### 5. Storage that grows in place.

Each instance gets its own PVC — 1 Gi on the default class, and that number is the whole interface. When the volume runs out, you don't rebuild anything; you change the number:

```bash
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"storage":{"size":"8Gi","resizeInUseVolumes":true}}}'
kubectl get pvc -n database -w    # volumes grow to 8Gi with no downtime
```

### 6. `250m` CPU — the free-trial math in a resource request.

The database pods share the application pool's 2-vCPU nodes with the storefront and the AI workloads, and that shapes the numbers: a `1000m` CPU request would pin each Postgres pod to a whole node and strand replicas as Pending. `250m` requests with a `1000m` limit keep three instances schedulable alongside everything else, with burst headroom. On a trial, resource requests are architecture decisions.

### 7. Backups via barman and Workload Identity

The `barmanObjectStore` points at GCS (`gs://devops-portfolio-backups/postgres`, WAL compressed with gzip, 30-day retention). But notice what is **not** in the file: no JSON key. The `googleCredentials` block carries a single flag — `gkeEnvironment: true` — which tells barman to use the pod's GKE identity instead of a key file. On this cluster that identity is Workload Identity, bound to a dedicated GCS service account (Step 3). Consistent with everything in this series: the database backs up with an identity, not a key.


---

## Step 3 — The backup identity: Workload Identity, end to end

The cluster's pods need to be able to write to GCS as a service account. The chain:

```bash
# 1. The GCS identity — a dedicated SA with objectAdmin on the bucket
gcloud iam service-accounts create pg-backup-sa \
  --display-name="CNPG GCS backups"
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
gcloud storage buckets create gs://devops-portfolio-backups \
  --project=devops-portfolio-prod        # skip if it already exists

# 2. The Kubernetes side: tell the namespace and the SA about the mapping
kubectl create ns database
kubectl annotate namespace database iam.gke.io/gke-metadata-server-enabled="true"
kubectl annotate serviceaccount default -n database \
  iam.gke.io/gcp-service-account=pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com

# 3. The trust: allow that Kubernetes identity to act as pg-backup-sa
gcloud iam service-accounts add-iam-policy-binding \
  pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com \
  --member="serviceAccount:devops-portfolio-prod.svc.id.goog[database/default]" \
  --role="roles.iam.workloadIdentityUser"
```

Read it as a chain of trust: the `database/default` Kubernetes service account is *allowed to assume* the GCS service account (the `workloadIdentityUser` binding on `pg-backup-sa`), and any pod running as `default` in the `database` namespace gets GCS credentials from the metadata server (the namespace annotation). barman picks them up with zero config. This is the same mechanism that will carry every workload-to-GCP permission in this project — one mental model, no keys.

## Step 4 — Deploy, and watch a database become a cluster

```bash
kubectl apply -f kubernetes/cnpg/postgres-cluster.yaml

kubectl get pods -n database -o wide     # ha-postgres-1 leader + 2 replicas
kubectl get cluster -n database          # Phase: Ready
kubectl get pvc -n database              # 3x Bound
```

[image]

In a few minutes the operator turns that YAML into three healthy Postgres pods, one per zone, plus the `-rw`/`-ro` services. That's the entire deployment story: one apply, and the operator handled the rest.

---

## Prove it: replication and failover

In the first half we deployed HA PostgreSQL with CloudNativePG and *asserted* its promises — leader election, synchronous replication, in-place storage growth. Now we stop asserting and start proving: we put the database under a continuous write load, then we kill the leader mid-write and watch the operator promote a replacement. Two questions get answered with evidence, not promises:

1. **Does replication survive a leader dying mid-write?**
2. **Does the HA story survive being tested?**

This is also the first experiment in the project's chaos discipline — the same steady-state hypothesis thinking that Chaos Mesh formalizes in a later part. Today the chaos injection is one command and a prayer: `kubectl delete pod`.

## Why break things on purpose

Breaking things on purpose is how we test the reliability of a system. You state what you believe is true of the system (the *steady-state hypothesis*), then you attack the system to find out if the belief survives. A HA database whose failover has never been tested is not HA — it's hope.

Two tools do all the work:

- **pgbench** — Postgres' own load generator. Ships with the database, zero install, standard TPC-B-style workload. The most reputable load generator you don't have to deploy.
- **`kubectl delete pod --grace-period=0 --force`** — the chaos injection. The harshest way to kill a pod: no SIGTERM, no shutdown sequence, instant removal. If the cluster survives this, it survives what production throws at it.

## The test target (what we're proving)

The cluster from the first half of this part: three Postgres instances (`ha-postgres-1/2/3`) spread across three zones, synchronous replication (`ANY 1`), a `-rw` service pinned to the leader via the `cnpg.io/instanceRole=primary` label, and a PodDisruptionBudget protecting the quorum. The two assertions:

- **Assertion A** — synchronous replication: a leader that dies mid-write loses *nothing that was acknowledged*, because no write is acknowledged until at least one replica has it on disk.
- **Assertion B** — killing the leader mid-load causes **zero failed transactions**: everything the clients were told was committed survives, and the promotion is transparent.

---

## Step 5 — Initialize the test database

The kill test writes through pgbench, so its tables have to exist first:

```bash
# Get the leader pod — the label is the source of truth
LEADER_POD=$(kubectl get pods -n database -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

# Initialize pgbench's tables ("app" is the database name)
kubectl exec -n database $LEADER_POD -- pgbench -i -U postgres app
```

- **`app`** — the trailing argument is the *database name*. Easy to drop, and the test then fails against the wrong database.
- Re-running init is safe: pgbench drops its old tables first, so a partially-failed init just re-initializes cleanly.

## Step 6 — State the steady-state hypothesis

Before injecting chaos, write down what you believe — the experiment is only meaningful if you can fail:

> **Hypothesis:** Under continuous write load, killing the leader pod causes no failed transactions. The operator promotes the healthiest replica within seconds, the `cnpg.io/instanceRole=primary` label and the `-rw` service move with it, and pgbench's final report shows zero failed transactions.

That sentence is the whole point of the exercise. Everything below is just the procedure for testing it.

---

## Step 7 — Kill the leader, watch it heal

The experiment, in one script — continuous load in the background, then a forced kill of the leader:

```bash
NAMESPACE="database"
CLUSTER="ha-postgres"

# Continuous write load for 10 minutes, in the background
kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE \
  -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') -- \
  pgbench -c 20 -j 2 -T 600 -P 10 -U postgres app &
LOAD_PID=$!

sleep 30    # let the load establish — the "before" state is measurable

# The kill: no grace period, no SIGTERM — the harshest cut
LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n $NAMESPACE $LEADER --grace-period=0 --force

# Watch the operator promote a new leader
for i in $(seq 1 30); do
  NEW_LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}')
  STATUS=$(kubectl get cluster -n $NAMESPACE $CLUSTER -o jsonpath='{.status.phase}')
  echo "[$i] New leader: $NEW_LEADER | Cluster phase: $STATUS"
  sleep 2
done

wait $LOAD_PID
echo "=== Load test finished ==="
```

The success criterion is the interesting part: **zero failed transactions during the switchover.** The load keeps running through the leadership change because the election, the promotion, and the `-rw` service re-pointing are all the operator's problem, and synchronous replication guarantees the promoted replica has every acknowledged write. The client keeps writing; it never learns the leader died.

[image]

**To understand what the method achieves, I will highlight the choices that shaped this experiment.**

### 1. The kill is the harshest possible cut.

`--grace-period=0 --force` skips the entire shutdown sequence — no SIGTERM, no checkpoint-and-exit, the pod is simply gone. A graceful termination (or even a `kubectl drain`) would let Postgres flush and hand off politely, which is *easy mode*. The forced kill tests the operator against the worst thing that actually happens in production: a node that dies, a spot instance that's repossessed, a kernel panic. If promotion survives this, it survives the soft cases trivially.

### 2. The load is established *before* the fault.

The 30-second warm-up isn't ceremony — it's measurement hygiene. The "before" state is the baseline the post-failover state is compared against. Kill during the warm-up and you can't tell a healthy transition from a cluster that was struggling before the chaos even started.

### 3. The measurement window contains the fault.

The load runs 10 minutes; the kill lands 30 seconds in. pgbench's final report therefore includes the transition itself — the failed-transactions counter, if any, appears in the same report that shows the throughput. The proof isn't a screenshot of a promotion; it's a pgbench report that *includes* the fault and shows no damage.

### 4. The 30-second poll loop is the observability.

The `for` loop watching `cnpg.io/instanceRole=primary` and the cluster phase is a primitive but honest telemetry channel: it shows the label moving from `ha-postgres-1` to `ha-postgres-2` (or 3), with the cluster phase staying `Ready` through the transition. In a later part, Prometheus and Grafana will watch this continuously — but the loop is how you first *see* a failover happen.

---

## Step 8 — Read the receipts

When the load finishes, pgbench prints its final report. The line that proves the hypothesis is the one at the bottom:

```text
number of transactions processed: 120000
number of failed transactions:    0
latency average = ...
tps = ...
```

**`number of failed transactions: 0`** — that is the zero-downtime promotion, in numbers. Every transaction that was acknowledged before the kill was safe (synchronous replication made sure of that), and the clients kept writing through the transition as if nothing happened.

The load test itself is the proof of the sync config. pgbench writes with `synchronous_commit` in play, so every acknowledged transaction is on at least two pods by the time the client sees "committed." When the leader pod above was force-deleted, the replica that took over had everything. If the replication were asynchronous, that kill would have surfaced as failed transactions in the pgbench output — it didn't.

[image]

One honest nuance worth stating plainly: in-flight requests still on the wire when the pod died may have been retried by the client — that's what retries are for. The guarantee — and the test's pass criterion — is that **nothing acknowledged was lost**, and the cluster's ability to serve never required human intervention.

Then confirm the new state of the world:

```bash
kubectl get pods -n database -o wide -l cnpg.io/instanceRole=primary
kubectl get cluster -n database ha-postgres     # Phase: Ready
```

And the operator's own account of the event:

```bash
kubectl get events -n database --sort-by=.lastTimestamp | tail -20
```

**If the test fails instead** — failed transactions appear in the report — the suspects, in order:

1. **Replication config** — with async-only replication, the promoted replica can be behind, and acknowledged-but-not-replicated writes vanish. The `ANY 1` synchronous config is what makes the claim true; verify it's actually in effect.
2. **Quorum damage** — if *two* pods were gone (the kill landed during a node drain, say), the cluster may have no quorum to promote from. The PodDisruptionBudget exists precisely to keep a scheduled drain from causing this.
3. **A polling race** — the `jsonpath='{.items[0].metadata.name}'` trick throws "array index out of bounds" when no pod matches the label yet (mid-promotion). That's a race in the watcher, not an error in the cluster — re-run the loop once the new leader exists.

---

## What's next

The first chaos experiment is a pass: a forced kill under load, a transparent promotion, receipts in hand. In the next part we stop flying blind — the **observability stack** (Prometheus + Grafana with database and WAF dashboards, plus the Datadog integration) so these numbers are watched continuously instead of on demand. And after that, the manual kill becomes an automated discipline: **Chaos Mesh** turns this script into repeatable experiments — pod kills, network latency, CPU stress, node failures — each one validating a steady-state hypothesis the way this part validated its own.
