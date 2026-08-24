# Load Testing and Proving Failover: From Benchmarks to Zero-Downtime Promotion

*pgbench under load, kill the leader, watch it heal.*

Part 7 of the series. In Part 6 we deployed HA PostgreSQL with CloudNativePG and *asserted* its promises — leader election, synchronous replication, in-place storage growth. In this part we stop asserting and start measuring: we put the database under a real benchmark, then we kill the leader mid-write and watch the operator promote a replacement. Two questions get answered with numbers, not vibes:

1. **Can this cluster carry real load?**
2. **Does the HA story survive being tested?**

This is also the first experiment in the project's chaos discipline — the same steady-state hypothesis thinking that Chaos Mesh formalizes in a later part. Today the chaos injection is one command and a prayer: `kubectl delete pod`.

---

## Why benchmark, and why break things on purpose

A benchmark is not a score — it's a **baseline**. Once you have numbers for a healthy system, every change becomes measurable: the sync-replication flag, a node-pool change, a Postgres setting — each one moves the numbers, and the numbers tell you whether the move was an improvement. Without a baseline, "seems fine" is the entire monitoring strategy.

Breaking things on purpose is the same discipline applied to reliability. You state what you believe is true of the system (the *steady-state hypothesis*), then you attack the system to find out if the belief survives. A HA database whose failover has never been tested is not HA — it's hope.

Two tools do all the work:

- **pgbench** — Postgres' own benchmark utility. Ships with the database, zero install, standard TPC-B-style workload. The most reputable load generator you don't have to deploy.
- **`kubectl delete pod --grace-period=0 --force`** — the chaos injection. The harshest way to kill a pod: no SIGTERM, no shutdown sequence, instant removal. If the cluster survives this, it survives what production throws at it.

## The test target (what we're proving)

The cluster from Part 6: three Postgres instances (`ha-postgres-1/2/3`) spread across three zones, synchronous replication (`ANY 1`), a `-rw` service pinned to the leader via the `cnpg.io/instanceRole=primary` label, and a PodDisruptionBudget protecting the quorum. The two assertions:

- **Assertion A** — the cluster sustains a steady write load with stable throughput and latency.
- **Assertion B** — killing the leader mid-load causes **zero failed transactions**: everything the clients were told was committed survives, and the promotion is transparent.

---

## Step 1 — Warm up: grow the disk first

The benchmark's data (scale 100 ≈ 10 million rows, ~1.4 GB) doesn't fit in the cluster's 1 Gi volumes. That's deliberate — it forces the in-place growth exercise from Part 6 before we can even start:

```bash
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"storage":{"size":"8Gi","resizeInUseVolumes":true}}}'
kubectl get pvc -n database -w          # volumes grow to 8Gi, pods keep serving
```

A prerequisite that takes ten seconds and changes a YAML number. Note the pattern: the database outgrew its disk, and we didn't rebuild anything.

## Step 2 — The benchmark: pgbench 101

First, initialize the benchmark data. The two easy-to-miss details are in the command itself:

```bash
# Get the leader pod — the label is the source of truth
LEADER_POD=$(kubectl get pods -n database -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')

# Initialize pgbench (scale 100 = ~10M rows; "app" is the database name)
kubectl exec -n database $LEADER_POD -- \
  pgbench -i -s 100 -U postgres app
```

- **`-s 100`** — the scale factor: 100× the base dataset, roughly 10 million rows. Realistic, and bigger than the original disk on purpose.
- **`app`** — the trailing argument is the *database name*. Easy to drop, and the benchmark then fails against the wrong database.
- Re-running init is safe: pgbench drops its old tables first, so a partially-failed init just re-initializes cleanly.

Then the run — 50 clients, 4 worker threads, 5 minutes, progress every 10 seconds:

```bash
kubectl exec -n database $LEADER_POD -- \
  pgbench -c 50 -j 4 -T 300 -P 10 -U postgres app
```

```
progress: 10.0 s, 1234.5 tps, lat 40.123 ms stddev 12.345
progress: 20.0 s, 1256.7 tps, lat 39.876 ms stddev 11.987
...
```

**How to read it:** `tps` is throughput (transactions per second), `lat` is average latency, `stddev` is the spread. On our trial-sized nodes — 2-vCPU application nodes, with synchronous replication — the headline number will be modest, and that's fine. Two things matter more than the peak:

1. **Stability** — the progress lines should stay flat. A benchmark that starts at 1200 tps and decays to 400 is a database that's bleeding somewhere; steady lines mean the system is at rest.
2. **The sync-replication tax is visible in the latency** — every write pays a round trip to a replica before the commit is acknowledged. That's the price of RPO ≈ 0, and it shows up in the benchmark. A faster cluster with async replication would post prettier numbers and lose acknowledged writes. We know which one we want.

## Step 3 — State the steady-state hypothesis

Before injecting chaos, write down what you believe — the experiment is only meaningful if you can fail:

> **Hypothesis:** Under continuous write load, killing the leader pod causes no failed transactions. The operator promotes the healthiest replica within seconds, the `cnpg.io/instanceRole=primary` label and the `-rw` service move with it, and pgbench's final report shows zero failed transactions.

That sentence is the whole point of the exercise. Everything below is just the procedure for testing it.

---

## Step 4 — Kill the leader, watch it heal

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

**To understand what the method achieves, I will highlight the choices that shaped this experiment.**

### 1. The kill is the harshest possible cut.

`--grace-period=0 --force` skips the entire shutdown sequence — no SIGTERM, no checkpoint-and-exit, the pod is simply gone. A graceful termination (or even a `kubectl drain`) would let Postgres flush and hand off politely, which is *easy mode*. The forced kill tests the operator against the worst thing that actually happens in production: a node that dies, a spot instance that's repossessed, a kernel panic. If promotion survives this, it survives the soft cases trivially.

### 2. The load is established *before* the fault.

The 30-second warm-up isn't ceremony — it's measurement hygiene. The "before" state (steady tps, flat latency) is the baseline the post-failover state is compared against. Kill during the warm-up and you can't tell a healthy transition from a cluster that was struggling before the chaos even started.

### 3. The measurement window contains the fault.

The load runs 10 minutes; the kill lands 30 seconds in. pgbench's final report therefore includes the transition itself — the failed-transactions counter, if any, appears in the same report that shows the throughput. The proof isn't a screenshot of a promotion; it's a benchmark report that *includes* the fault and shows no damage.

### 4. The 30-second poll loop is the observability.

The `for` loop watching `cnpg.io/instanceRole=primary` and the cluster phase is a primitive but honest telemetry channel: it shows the label moving from `ha-postgres-1` to `ha-postgres-2` (or 3), with the cluster phase staying `Ready` through the transition. In a later part, Prometheus and Grafana will watch this continuously — but the loop is how you first *see* a failover happen.

---

## Step 5 — Read the receipts

When the load finishes, pgbench prints its final report. The line that proves the hypothesis is the one at the bottom:

```text
number of transactions processed: 120000
number of failed transactions:    0
latency average = ...
tps = ...
```

**`number of failed transactions: 0`** — that is the zero-downtime promotion, in numbers. Every transaction that was acknowledged before the kill was safe (synchronous replication made sure of that), and the clients kept writing through the transition as if nothing happened.

[image]

One honest nuance worth stating plainly: in-flight requests still on the wire when the pod died may have been retried by the client — that's what retries are for. The guarantee — and the benchmark's pass criterion — is that **nothing acknowledged was lost**, and the cluster's ability to serve never required human intervention.

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

The first chaos experiment is a pass: a benchmarked baseline, a forced kill under load, a transparent promotion, receipts in hand. In the next part we stop flying blind — the **observability stack** (Prometheus + Grafana with database and WAF dashboards, plus the Datadog integration) so these numbers are watched continuously instead of on demand. And after that, the manual kill becomes an automated discipline: **Chaos Mesh** turns this script into repeatable experiments — pod kills, network latency, CPU stress, node failures — each one validating a steady-state hypothesis the way this part validated its own.
