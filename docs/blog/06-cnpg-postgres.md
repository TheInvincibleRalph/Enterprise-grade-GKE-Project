# Deploying a Highly Available PostgreSQL on Kubernetes with CloudNativePG

*Leader election, synchronous replication, and self-healing storage.*

Part 6 of the series. In Part 5 the storefront went live behind the WAF — but every store, sooner or later, needs a database. In this part we deploy **PostgreSQL as a fully managed, Kubernetes-native cluster** with CloudNativePG: one leader and two replicas spread across three zones, writes survive a leader dying mid-flight, and disk grows while the database keeps serving.

---

## Why CloudNativePG?

Running Postgres the old way means a VM you SSH into, `systemctl` you babysit, and backups you hope you remembered to script. CloudNativePG is the **operator pattern** applied to databases: a controller in the cluster watches a `Cluster` custom resource and converges the running state to whatever the spec says. Postgres becomes declarative — you write `instances: 3` and the operator makes it true, then keeps it true.

That one pattern buys the three things in this post's title:

1. **Leader election** — the operator decides who the leader is, watches it, and promotes a replica automatically when it dies. No manual failover at 3 a.m.
2. **Synchronous replication** — the leader refuses to acknowledge a write until at least one replica has it on disk. A leader that dies mid-write loses *nothing that was acknowledged*.
3. **Storage that grows in place** — the operator expands the underlying disk live when you bump the size in the spec. Capacity is a YAML number, not a maintenance window.

Plus the things operators are for: automated backups (barman), pod disruption budgets, and health monitoring, all as standard behavior.

---

## The following resources were provisioned

1. **CloudNativePG operator** (`cnpg-system` namespace) with its 6 CRDs
2. **Cluster `ha-postgres`** (`database` namespace) — 3 instances, PostgreSQL 16.4
3. **`pg-backup-sa`** — a GCP service account bound to the cluster via Workload Identity
4. **`gs://devops-portfolio-backups`** — the GCS bucket backups land in

## Step 1 — Install the operator

```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml

# Verify ALL 6 CRDs landed (a dropped connection can silently skip one):
kubectl get crd | grep cnpg

# The controller crash-loops until every CRD exists — watch it come up:
kubectl get pods -n cnpg-system -w
```

One YAML installs the controller *and* the CRDs. Note the `--server-side --force-conflicts` — this is a real-world detail: client-side apply rejects the `poolers` CRD (its schema annotation exceeds the 256 KB limit), and server-side apply conflicts with earlier client-side ownership. Server-side apply with force resolves both. And verify the CRD count — a flaky connection mid-apply can silently skip one, and the controller then crash-loops with `no matches for kind "Pooler"`.

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
      wal:
        compression: gzip
```

**To understand what this config achieves, I will highlight the decisions that shaped it.**

### 1. `instances: 3` — one leader, two replicas, and a label that says who's who.

The operator runs three Postgres pods: `ha-postgres-1` (the leader), `ha-postgres-2` and `ha-postgres-3` (replicas). Exactly one pod carries the `cnpg.io/instanceRole=primary` label — that label is how the rest of the world finds the leader, and the operator maintains it as a fact of life. It also creates the read-write service (`ha-postgres-rw`, always pointed at the leader) and the read-only service (`ha-postgres-ro`, spread across replicas) — so applications don't even need to know which pod is which.

### 2. One instance per zone — a zone failure costs one instance, never the cluster.

`enablePodAntiAffinity` + `topologyKey: topology.kubernetes.io/zone` tells the scheduler: never co-locate two of these pods in the same availability zone. A zone failure takes down exactly one instance — the quorum lives on, and with a leader + two replicas the cluster can still serve and still fail over. This is the same three-zone story as the cluster itself, applied one level down.

### 3. Synchronous replication — the commit that isn't acknowledged isn't lost.

With three instances we configure synchronous replication so the leader **waits for at least one replica to confirm a write on disk before acknowledging the client** — the classic `synchronous_standby_names = 'ANY 1 (ha-postgres-2, ha-postgres-3)'`. The first replica to ack makes the commit durable; the third replays asynchronously. The trade-off is a write-latency cost (one round trip to a replica per commit) — and in exchange you get the strongest guarantee Postgres offers: **RPO ≈ 0**. When the leader dies, the promoted replica already holds every transaction the clients were told was committed. That is what makes the failover test at the end of this part pass with *zero failed transactions*.

### 4. Leader election is the operator's job — and it's faster than your pager.

The operator owns leadership through a lease-based election, watches the leader's health, and on failure promotes the healthiest replica — moving the `cnpg.io/instanceRole=primary` label, re-pointing the `-rw` service, and letting the other replica re-sync. A PodDisruptionBudget protects the quorum during node drains, so a scheduled maintenance event can't accidentally take out two instances at once. The demo later in this post kills the leader *under a live write load* — and the load never notices.

### 5. Storage that grows in place.

Each instance gets its own PVC — 1 Gi on the default class, and that number is the whole interface. When the volume runs out, you don't rebuild anything; you change the number:

```bash
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"storage":{"size":"8Gi","resizeInUseVolumes":true}}}'
kubectl get pvc -n database -w    # volumes grow to 8Gi with no downtime
```

The operator expands the claim, the cloud disk, and the filesystem live, pod-by-pod, without a restart. This is the "storage grows in place" promise — and we prove it in the verification section with a benchmark that outgrows its own disk.

### 6. `250m` CPU — the free-trial math in a resource request.

The database pods share the application pool's 2-vCPU nodes with the storefront and the AI workloads, and that shapes the numbers: a `1000m` CPU request would pin each Postgres pod to a whole node and strand replicas as Pending. `250m` requests with a `1000m` limit keep three instances schedulable alongside everything else, with burst headroom. On a trial, resource requests are architecture decisions.

### 7. Backups via barman and Workload Identity — no JSON key anywhere.

The `barmanObjectStore` points at GCS (`gs://devops-portfolio-backups/postgres`, WAL compressed with gzip, 30-day retention). But notice what is **not** in the file: no `googleCredentials` block. barman falls back to the pod's default credentials — which on this cluster are Workload Identity credentials, bound to a dedicated GCS service account (Step 3). Consistent with everything in this series: the database backs up with an identity, not a key.


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
  --role="roles/iam.workloadIdentityUser"
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

### 1. Leader election — kill the leader under load

The strongest demonstration is failover while the database is actively being written to:

```bash
# Continuous write load for 10 minutes, in the background
kubectl exec -n database $(kubectl get pods -n database -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}') -- \
  pgbench -c 20 -j 2 -T 600 -P 10 -U postgres app &
LOAD_PID=$!

sleep 30

# Now kill the leader — force, no grace period
LEADER=$(kubectl get pods -n database -l cnpg.io/instanceRole=primary \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n database $LEADER --grace-period=0 --force

# Watch the operator promote a new leader
for i in $(seq 1 30); do
  NEW_LEADER=$(kubectl get pods -n database -l cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}')
  STATUS=$(kubectl get cluster -n database ha-postgres -o jsonpath='{.status.phase}')
  echo "[$i] New leader: $NEW_LEADER | Cluster phase: $STATUS"
  sleep 2
done

wait $LOAD_PID
```

The success criterion is the interesting part: **zero failed transactions during the switchover.** The load keeps running through the leadership change because the election, the promotion, and the `-rw` service re-pointing are all the operator's problem, and synchronous replication guarantees the promoted replica has every acknowledged write. The client keeps writing; it never learns the leader died.

[image]

### 2. Synchronous replication — why "zero data loss" is structural, not a promise

The load test itself is the proof of the sync config. `pgbench` writes with `synchronous_commit` in play, so every acknowledged transaction is on at least two pods by the time the client sees "committed." When the leader pod above was force-deleted, the replica that took over had everything. If the replication were asynchronous, that kill would have surfaced as failed transactions in the pgbench output — it didn't.

### 3. Storage that grows in place

The scale test outgrows its own disk on purpose. `pgbench -s 100` needs about 1.4 GB — more than the 1 Gi volume the manifest declares:

```bash
# The 1 Gi volumes can't hold scale-100 data (~1.4 GB).
# Grow them in place first — no downtime, no pod restarts:
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"storage":{"size":"8Gi","resizeInUseVolumes":true}}}'
kubectl get pvc -n database -w          # volumes grow to 8Gi, pods keep serving

# Then initialize the benchmark data (scale 100 = ~10M rows):
kubectl exec -n database ha-postgres-1 -- pgbench -i -s 100 -U postgres app

# And run the load — reads and writes, 50 clients, 4 threads, 5 minutes:
kubectl exec -n database ha-postgres-1 -- \
  pgbench -c 50 -j 4 -T 300 -P 10 -U postgres app
```

Capacity planning on this setup is editing a YAML number and watching the PVCs grow — the operator expands claim, disk, and filesystem in place. There is no "database maintenance window to add disk" in the operational vocabulary of this cluster.

[image]

---

## What's next

The database is HA, durable, backed up, and self-healing — but right now we're flying it blind. In the next part we build the observability stack: **Prometheus + Grafana** with dashboards for this database and the WAF, and the Datadog integration for enterprise-grade APM — because a database you can't see is a database you can't trust.
