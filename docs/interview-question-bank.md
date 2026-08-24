# Interview Question Bank — DevOps Portfolio Project

*A comprehensive, project-grounded question bank for interview prep: deep-level knowledge, scenario-based, application-specific, and behavioral questions covering the entire stack (GCP/GKE, Terraform, Cilium, Envoy Gateway + WAF, CloudNativePG/PostgreSQL, Chaos Mesh, KEDA, Redis, Ollama, observability).*

**How to use this document**
- **Part 1 (Application Questions)** — questions about *your* project specifically. Interviewers build 30–50% of a DevOps interview around this. Know these cold.
- **Parts 2–11 (Stack Questions)** — deep knowledge + scenarios per technology, researched from real interview sources. One line per question tells you what a strong answer must cover.
- **Part 12 (Behavioral)** — the "tell me about a time…" questions, with the project stories that answer them.
- **Part 13 (The Shortlist)** — the ~30 questions with the highest probability of appearing.
- **Appendix A** — numbers to memorize. **Appendix B** — gotchas you can talk about (each is a story).

---

## Part 1 — Application Questions (about YOUR project)

### 1.1 Walk me through your project

1. **"Walk me through this project — pretend I've never seen it. What did you build, and why?"**
   *Cover:* An enterprise-grade Kubernetes ecosystem on GKE: private multi-zone cluster, Cilium (eBPF + WireGuard), Envoy Gateway with an in-process Coraza WAF, HA PostgreSQL via CloudNativePG with proven zero-loss failover, queue-driven AI inference with scale-to-zero, Chaos Mesh validation, and cost controls (spot VMs, budget kill-switch). Four pillars: security, reliability, observability, cost-awareness.

2. **"What were your constraints, and how did they shape your architecture?"**
   *Cover:* GCP free trial: 12 vCPU global, 8 instances, 4 external IPs, 250 GB SSD, no GPUs, no quota increases. Result: 3× system nodes (1 vCPU/4 GB, `CriticalAddonsOnly` taint) + 3× app nodes (2 vCPU/8 GB, autoscaling 1–3), spot everywhere, private nodes, `pd-standard` 30 GB disks, LLM on CPU. Constraints made resource requests an architecture decision (e.g., `250m` CPU for Postgres, not `1000m`).

3. **"Draw your architecture. What happens when a user visits `boutique.invincibledevops.tech`?"**
   *Cover:* Browser → Cloudflare (HTTPS, WAF-lite, Flexible SSL) → GCP Load Balancer (1 of 4 IP quota) → one of 3 Envoy pods (in-process Coraza WAF checks payload → router) → boutique frontend → 11 microservices + redis-cart. Everything east-west encrypted by WireGuard; every flow visible in Hubble.

4. **"You said the project demonstrates security, reliability, observability, and cost-awareness. Map each pillar to a concrete component and a concrete proof."**
   *Cover:* Security → WAF 5/5 blocked attacks + WireGuard packet capture + Workload Identity (no keys); Reliability → CNPG failover under load with 0 failed transactions; Observability → Prometheus/Grafana/Datadog/Hubble dashboards; Cost → spot VMs + scale-to-zero + kill-switch, ~$20 for two weeks of full infra.

5. **"What was the hardest problem you solved in this project?"**
   *Cover:* Pick one story with real depth — the WireGuard route fix (`ipv4NativeRoutingCIDR /8` — encryption enabled but not happening), the CNPG CRD apply issue (server-side apply), or the node-starvation problem (98% allocatable on 1-vCPU nodes). State the symptom, the diagnosis path, the fix, and how you verified it.

6. **"What would you do differently if you had a real production budget?"**
   *Cover:* On-demand (non-spot) for system pool and database; GPU pool (L4) with DCGM-driven KEDA; GitOps (ArgoCD/Flux); PgBouncer pooling; mTLS via SPIFFE/SPIRE; multi-region DR; cert-manager TLS at the gateway; dedicated observability nodes. Acknowledge current limits honestly (kill-switch stops instances, not node pools).

### 1.2 Design-decision questions (why X?)

7. **Why a regional cluster, and why is a regional cluster still not automatically HA?** — Control plane replicated across 3 zones; but HA also requires multi-zone workloads, disks, and anti-affinity. Your CNPG anti-affinity + per-zone node pools close the loop.
8. **Why private nodes + Cloud NAT?** — No public IPs on nodes (fits 4-IP quota, better security posture); Cloud NAT gives private nodes egress for images, metrics, Datadog.
9. **Why spot for everything?** — 60–80% cost cut; on GKE with `CriticalAddonsOnly` system pool the risk is acceptable; spot interruptions are exactly the failure you design for (graceful termination, PDBs, fast rescheduling).
10. **Why two node pools with a taint?** — System pool (`CriticalAddonsOnly` taint) keeps Cilium, CoreDNS, operators from being crowded out by app pods; app pool for everything else.
11. **Why Cilium instead of GKE Dataplane V2?** — Dataplane V2 *is* Cilium but fully abstracted: no WireGuard control, no Hubble CLI/UI, no self-managed features. You needed Hubble observability + WireGuard.
12. **Why WireGuard instead of IPsec or mTLS sidecars?** — WireGuard: kernel-level, transparent, no app changes, minimal overhead, modern crypto. mTLS (Istio) = sidecar per pod (memory + latency). IPsec = enterprise standard, hardware offload. WireGuard encrypts node-to-node; it does NOT provide identity (that's mTLS's job).
13. **Why did you replace kube-proxy entirely?** — iptables is O(n) sequential rule traversal, full ruleset regen on any change; eBPF maps are O(1) lookups, incremental updates, in-kernel policy + metrics.
14. **Why Envoy Gateway instead of ingress-nginx?** — ingress-nginx retired March 2026 (no security fixes); Envoy Gateway is Gateway API-native, config pushed via xDS with no reloads, and supports the in-process WAF.
15. **Why Gateway API over Ingress?** — Role separation (GatewayClass/Gateway/HTTPRoute), no vendor annotations, cross-namespace routing, portability across implementations, L4+L7.
16. **Why run the WAF *in-process* (dynamic module) instead of a sidecar or separate proxy?** — Zero extra hop, the filter sees traffic in Envoy's own filter chain; needs K8s 1.35+ image volumes — that's why you upgraded 1.34→1.35.5.
17. **Why Cloudflare Flexible SSL instead of Full (strict)?** — Origin (Envoy) serves plain HTTP on :80; Flexible = HTTPS to the world, HTTP to origin. Full(strict) → 521/502. Security is maintained: WAF inspects plaintext anyway, east-west is WireGuard-encrypted.
18. **Why CloudNativePG instead of Cloud SQL / RDS / a hand-rolled StatefulSet?** — Operator pattern: declarative day-2 ops (failover, backups, storage growth, rolling updates) as a CRD. RDS = managed but no GitOps control; StatefulSet = no leader election, no backups, no storage growth.
19. **Why synchronous replication (`ANY 1`)?** — RPO ≈ 0: leader doesn't ack a commit until a replica has it on disk. Cost: write latency + a round trip; if the sync standby dies the primary silently falls back to async (two-safe window).
20. **Why anti-affinity by zone for Postgres?** — One instance per AZ; a zone failure costs one instance, never quorum.
21. **Why barman + GCS via Workload Identity?** — barmanObjectStore with no `googleCredentials` block: the pod uses its Workload Identity credentials. Consistent "identity, not keys" story end to end.
22. **Why pgbench, and why kill the leader with `--grace-period=0 --force`?** — pgbench ships with Postgres, standard TPC-B workload, zero install. The forced kill is the harshest real-world cut (no SIGTERM, no flush) — if promotion survives that, it survives spot repossessions and kernel panics.
23. **Why Redis as the queue instead of Kafka/RabbitMQ?** — Latency, simplicity, zero extra infra at this scale; at-least-once via BRPOPLPUSH/Streams pattern is hand-rolled, and deep backlogs live in memory (OOM risk) — acceptable trade-off you acknowledged.
24. **Why KEDA instead of plain HPA for the AI workers?** — Workers idle on BRPOP at ~0% CPU; CPU is a trailing indicator, queue depth is leading. And HPA can't scale to zero; KEDA can.
25. **Why Ollama on CPU?** — Trial can't attach GPUs. Small quantized model (llama3.2:3b Q4 ≈ 2 GB), ~2–5 tok/s on CPU. The scaling demo (queue → replicas → zero) is the point, not the speed.
26. **Why Chaos Mesh?** — CRD-driven experiments with selectors/modes/durations, web dashboard; pod-kill, network latency, CPU stress, node drain as repeatable experiments, not shell scripts.
27. **Why encode the steady-state hypothesis as a ConfigMap?** — A hypothesis that "applies cleanly" is versioned in Git and survives on the cluster; the before/during/after comparison is against a yardstick, not a memory.
28. **Why SA impersonation for Terraform instead of a service-account key?** — No long-lived secrets anywhere; `roles/iam.serviceAccountTokenCreator` lets your user mint short-lived tokens. An org policy (`constraints/iam.managed.disableServiceAccountKeyCreation`) blocks keys anyway.
29. **Why a Cloud Function kill-switch instead of just email alerts?** — Budget alerts lag real spend; a Pub/Sub-triggered function that stops instances is the automated backstop. Honest limits: it stops instances, not node pools; alerts lag by hours; budget must be set *below* the cap.
30. **Why `node_count: 1` per pool when you have 3 zones?** — GKE's `node_count` is **per-zone** for regional pools: 1 per zone = 3 nodes. Naive `node_count: 3` would have requested 9.

### 1.3 What broke — gotcha stories (interviewers love these)

31. **"Tell me about a bug that took you hours to fix."** — Any of the Appendix B stories. Format: symptom → hypothesis → investigation → root cause → fix → verification.
32. **Why did you use `kubectl apply --server-side --force-conflicts` for the CNPG operator?** — Client-side apply rejects the `poolers` CRD (schema annotation > 256 KB limit); server-side apply conflicts with earlier client-side ownership. Also: a dropped connection can silently skip a CRD → controller crash-loops with `no matches for kind "Pooler"` — verify all 6 CRDs landed.
33. **What happened when Cilium said "Encryption: WireGuard" but tcpdump showed no tunnel traffic?** — `ipv4NativeRoutingCIDR` was only the node /16; WireGuard routes were never programmed for pod CIDRs. Fix: `/8` covering `10.1.0.0/16` pods. Lesson: "enabled" ≠ "working" — verify at the packet level.
34. **Why did the Datadog agent fail on GKE?** — COS has a read-only `/usr`: system-probe failed `mkdir /usr/src`. Fix: `providers.gke.cos=true` (fixes the mount itself). Also: empty `$DD_API_KEY` deploys silently broken agents; site must match account region.
35. **Why was your Envoy metrics pipeline dead?** — EG v1.8 serves metrics on port **19001** (not 19000); the ServiceMonitor needed `release: monitoring` and `component: proxy` selector labels or it scraped the controller; datasource UID must be literal `prometheus`. Each was a real bug.
36. **Why did the storefront 521 through Cloudflare but 200 direct?** — SSL mode: Full(strict) assumes TLS origin; origin is plain HTTP → 521/502. Set Flexible.
37. **Why were pods stuck Pending on your "free" cluster?** — Allocatable at 98%: GKE daemonsets (cilium, kube-proxy, fluentbit, netd) eat ~0.5 vCPU/node; a 500m request was half a node. Fix: e2-custom-2-8192 app nodes, and 100m requests.
38. **Why did Ollama die with exit 137?** — OOMKilled: 3B Q4 model ≈ 2 GB against a 4 GB node under memory pressure. Fix: 8 GB nodes, 4 Gi limit, `OLLAMA_NUM_PARALLEL=1` (4 parallel on 1–2 vCPU = thrash).
39. **Why did pgbench fail with "relation pgbench_branches does not exist"?** — The trailing database-name argument was dropped: it ran against `postgres` instead of `app`. And scale-100 data (~1.4 GB) didn't fit 1 Gi volumes → `No space left on device` → the in-place resize demo became a prerequisite.
40. **Why did your Chaos Mesh NetworkChaos get rejected?** — `direction: both` requires a `targets` list; `direction: to` is the correct semantics. Similarly PodChaos `scheduler` is rejected by the installed CRD; and StressChaos targeting `role: gpu` matched nothing (no GPU nodes) — stress Ollama instead.
41. **What's the `jsonpath='{.items[0].metadata.name}'` race?** — Mid-promotion, no pod matches `cnpg.io/instanceRole=primary` yet → "array index out of bounds". Race in the watcher script, not the cluster.
42. **Why did your kill-switch function deploy ACTIVE but never fire?** — The budget alert must have "Notify on Pub/Sub topic" checked; also `--source` defaults to cwd, `--entry-point` must match the function name, and the zones list was wrong (`-a/-b/-c` vs the cluster's `-b/-c/-f`).

### 1.4 Numbers & evidence (know these by heart)

43. **"Give me three concrete numbers that prove your system works."**
   - WAF: 5/5 attack classes blocked (SQLi, XSS, path traversal, command injection, UNION SQLi) + ZAP baseline scan.
   - Failover: pgbench under 50-client load, leader force-killed mid-run → **119,079 transactions, 0.000% failed**, 396.6 tps, avg latency 124.7 ms; also an *automatic* failover fired by failing readiness probes with 0 failed transactions.
   - Cost: full environment (6 nodes, 90+ pods, 200+ containers, live AI inference) for two weeks **< $20**; scale-to-zero: queue length 0 → 3 Ollama replicas → back to 0 after 60s cooldown.
   - Quota headroom: 9/12 vCPU, 6/8 instances, 2/4 external IPs.

44. **"What would you monitor after this project goes live in production?"** — Prometheus/Grafana: Postgres (replication lag, TPS, cache hit ratio, WAL rate, connections), WAF (request rate by status, 403s, latency p50/p95/p99), kube-state + node metrics; Datadog for APM traces and host map; Hubble for flow-level denials. Alert on failover time < 30s, error rate < 1%, p99 < 500 ms per your steady-state ConfigMap.

### 1.5 Improvement / follow-up questions

45. **How would you make this GitOps-driven?** — ArgoCD/Flux, promotion pipelines, drift detection; the repo's manifests are already declarative.
46. **How would you add mTLS to this cluster?** — SPIFFE/SPIRE + Cilium mTLS or Istio Ambient; WireGuard covers transport, mTLS adds identity per workload.
47. **How would you handle 10× the traffic?** — HPA/CA limits, PgBouncer pooling, read replicas + `-ro` service, cache layer, GPU workers with continuous batching (vLLM), multi-region.
48. **How would you recover the database from a full region failure?** — Restore barman base backup + WAL to a new cluster (PITR), validate RPO/RTO with a real restore drill — Extension F in your README.
49. **What's the security gap in this project?** — Be honest and specific: TLS terminates at Cloudflare (origin plain HTTP), no encryption at rest for the GCS bucket/PVCs mentioned, RBAC wildcard on chaos-mesh resources (`rbac.yaml`), no GitOps admission control, kill-switch stops instances only, no network policies applied in the final state (they're part of the design but not the verified manifests).

---

## Part 2 — GCP & Terraform

### 2.1 Terraform core & workflow

1. **What's the difference between `terraform plan` and `terraform apply`, and what happens during the refresh phase?** — Plan diffs config vs. state (after refresh detects drift) without mutating; apply executes the plan and writes state; both lock state.
2. **How does Terraform determine execution order?** — Dependency graph: implicit (references) + explicit (`depends_on`) edges; parallel where independent.
3. **What if you plan while someone else's apply holds the state lock?** — Plan blocks until the lock is released rather than planning against stale state.
4. **Why is `terraform apply -target` dangerous in production?** — Bypasses dependencies; can skip resources that depend on the target. Emergency only; follow with a full plan.
5. **Why pin providers, and what's the risk of upgrading?** — `required_providers` constraints; upgrades can change plans (attribute drift). Version bumps go through the same review as code changes.
6. **`terraform refresh` vs `terraform plan -refresh-only`?** — Refresh silently mutates state; `-refresh-only` shows the diff first — safer for drift recovery.
7. **An apply fails halfway — some resources created, some not. What now?** — Terraform doesn't roll back; next plan/apply converges. For created-but-unrecorded resources, `terraform import` — never let it create duplicates.
8. **Plan in CI, apply in production: what's the safe flow?** — Plan on PR, human approval gate, apply the *saved plan file* (not a fresh plan), least-privilege service accounts in CI, never local machines.

### 2.2 Terraform state & lifecycle (highest-probability category)

9. **Why is state called the single source of truth, and what happens if you lose it?** — State maps config addresses to real IDs; losing it means re-importing everything manually. Hence remote state + versioning + backups.
10. **How do you set up remote state with GCS, and what does it give you?** — `backend "gcs"` + bucket/prefix per environment; team sharing, state locking, object versioning. (Your `backend.hcl`: bucket `devops-portfolio-tfstate`, prefix `terraform/state`.)
11. **What is state locking, how does GCS implement it, and how do you clear a stale lock?** — Locks prevent concurrent corruption; verify the holder is truly dead, then `terraform force-unlock <id>`, then plan to verify integrity.
12. **`state rm` vs `state mv` vs `import` vs `taint`?** — rm = stop managing (resource survives); mv = rename in state avoiding destroy+recreate; import = adopt existing; taint = mark for recreate (deprecated → `apply -replace=<addr>`).
13. **A colleague deleted a resource in the console. `terraform plan` shows a recreate. Options?** — Accept recreation; or `state rm` (accept deletion); or `import` a replacement created out-of-band.
14. **What are `moved` blocks, and why do they beat `state mv`?** — Declarative `moved { from/to }` (1.1+): migrate state during normal plan/apply, reviewable in PRs, no destroy+recreate.
15. **What is drift, how do you detect and remediate it?** — Reality diverging from state/config; detect via scheduled plan in CI; remediate by reviewing, applying, or importing — never silently overwrite.
16. **Can sensitive data live in state, and does `sensitive = true` protect it?** — Yes — state holds secrets in plaintext; `sensitive` only hides plan output. Protect the backend: IAM, encryption, versioning, never commit state.
17. **`lifecycle { prevent_destroy }` and `create_before_destroy`?** — Prevent deletion of critical resources; reverse replacement order for zero-downtime. Overuse masks real problems and complicates plans.
18. **How do you share outputs between separate configs?** — `data "terraform_remote_state"`; trade-off: smaller blast radius per state vs cross-config coupling.
19. **Plan errors "instance not found" for a state entry instead of planning recreation. What now?** — `state rm` the stale entry or `plan -refresh-only` to reconcile, then plan again.
20. **One state file vs split state?** — Split per environment/service (`{env}/{service}/terraform.tfstate`): smaller blast radius, narrower permissions.

### 2.3 Terraform language & meta-arguments

21. **`count` vs `for_each`?** — count indexes by integer (removing a middle element shifts indices → churn); `for_each` keys by map/set (stable identity). Prefer `for_each`.
22. **What happens when you remove one element from a `count` list?** — Every subsequent resource shifts and plans destroy+recreate; with `for_each` only the removed key dies.
23. **Can `for_each` take a list?** — No — wrap with `toset()`, or build a keyed map in `locals`.
24. **Dynamic blocks: when and why?** — Generate repeated nested blocks (IAM bindings, firewall rules) from collections; name iterators explicitly to avoid shadowing.
25. **`validate` vs `fmt` vs `init -upgrade` in CI?** — fmt normalizes, validate checks syntax/semantics without state, `init -upgrade` updates provider locks — the last one deliberately, since it can change plans.

### 2.4 GKE

26. **What is a node pool, and how do you decide how many you need?** — Identically configured node group; separate pools per workload class (system/spot/GPU/memory) with taints/tolerations pinning workloads.
27. **Zonal vs regional cluster — and when is a regional cluster still not HA?** — Regional replicates the control plane; HA still fails if workloads/disks/deps are single-zone. (Your design: regional + per-zone pools + CNPG anti-affinity.)
28. **GKE Standard vs Autopilot?** — Standard: you manage nodes, VM billing, full control (spot, GPU, custom kernels); Autopilot: Google manages nodes, pod billing, node-level control constrained.
29. **What are you responsible for vs Google in GKE?** — Google: control plane, etcd, API server, node OS patches (in Standard, largely). You: workloads, node pools, RBAC, cluster config.
30. **Taints and tolerations — how do they work?** — Taints repel pods unless the pod tolerates; `CriticalAddonsOnly=true:NoSchedule` on your system pool keeps app workloads off it.
31. **Pods stuck Pending with "free" CPU — debug order?** — Node selectors/affinity vs taints, requests vs allocatable, autoscaler disabled/maxed, quotas. (Your story: 98% allocatable, 500m = half a node.)
32. **HPA vs Cluster Autoscaler?** — "HPA scales pods, CA scales nodes." HPA on CPU/custom metrics; CA adds nodes when pods are unschedulable.
33. **What is Node Auto-Provisioning?** — CA dynamically creates/deletes whole node pools and picks machine types; plain CA only resizes existing pools.
34. **A spike hits and pods stay Pending. Walk through debugging.** — `kubectl describe pod` events → HPA status → `kubectl top` → autoscaler enabled + max-nodes → quotas. Remember: autoscaling doesn't fix downstream bottlenecks (DB connections).
35. **How do GKE surge upgrades work, and how do you upgrade prod without downtime?** — Add new nodes before draining old; pair with PDBs, rolling updates, release channels; test in staging first.
36. **What is node auto-repair, and why might pods not restart when a node dies?** — Detects/recreates unhealthy nodes; pods fail to reschedule if auto-repair is off, cluster is single-zone, or workloads lack ReplicaSets.
37. **PodDisruptionBudgets — why do they matter during drains/upgrades?** — Cap voluntary-disruption unavailability; a PDB misconfiguration is a classic cause of upgrade outages. (Your CNPG PDB protects the Postgres quorum during drains.)
38. **Release channels and version skew?** — Node pools can lag the control plane within supported skew; channels (Rapid/Regular/Stable) control upgrade cadence. (You pinned `min_master_version 1.35.5` on STABLE for the WAF's image-volume requirement.)
39. **What is a VPC-native GKE cluster, and why is it preferred?** — Pods get real IPs from VPC alias ranges: direct connectivity, NetworkPolicies, no pod→VPC NAT. Not resizable after creation — sizing math matters.
40. **What is a private GKE cluster, and how do you reach the control plane?** — Nodes have no public IPs; API endpoint internal. Access via authorized networks/VPN/bastion; never expose to the internet. (You set `enable_private_endpoint = false` so your laptop can reach it.)
41. **Workload Identity — how does it work, and why is it better than keys or node-pool SAs?** — K8s SA annotated `iam.gke.io/gcp-service-account`, bound via `roles/iam.workloadIdentityUser`; pods exchange OIDC tokens for short-lived GCP creds. Keyless, least-privilege, per-workload. (Your `pg-backup-sa` → `database/default` chain.)
42. **Pod needs GCS access — options?** — Best: Workload Identity with minimal storage role; alternatives (node-pool default SA, static keys) are broader/long-lived — avoid.
43. **IAM vs RBAC in GKE?** — IAM: who can call GCP APIs against the cluster; RBAC: what identities can do inside the cluster. Lock down both.
44. **How do you implement NetworkPolicies in GKE?** — Requires VPC-native; enforced via Dataplane V2 or a CNI (you use Cilium, which enforces natively — GKE-level `network_policy` is disabled in your main.tf).

### 2.5 GCP IAM & service accounts

45. **Walk the GCP resource hierarchy and IAM inheritance.** — Org → Folders → Projects → Resources; policies inherit downward and union. Org/folder guardrails, minimal project grants.
46. **Basic vs predefined vs custom roles?** — Basic (Owner/Editor/Viewer) too broad for prod; predefined cover job functions; custom roles for exact least privilege.
47. **IAM Conditions — give an example.** — CEL constraints on grants (time windows, resource tags); e.g., deploy SA can modify prod only in a change window.
48. **How do you secure service accounts?** — One SA per workload, no keys (impersonation/short-lived), narrow default SAs, audit who-can-impersonate.
49. **A SA gets 403s on a GCS bucket. Debug?** — IAM bindings on bucket + project, uniform bucket-level access vs ACL conflicts, KMS key permissions if CMEK-encrypted.
50. **IAM policies vs Org policies (constraints)?** — IAM: who can do what; Org policies: what can exist (region restrictions, disabling SA key creation) — even project Owners can't override.

### 2.6 Cloud Functions (incl. your kill-switch)

51. **What is a cold start, and how do you reduce it?** — First invocation initializes runtime + deps; mitigate with concurrency, fewer deps, `--min-instances` warm instances, pre-warming.
52. **Gen1 vs Gen2 Cloud Functions?** — Gen2 = Cloud Run/Eventarc: ~1000 concurrent requests/instance, richer triggers; Gen1: no concurrency, simpler. Gen2 for event-driven pipelines (you deployed gen2).
53. **HTTP vs event triggers — delivery guarantees?** — HTTP: at-most-once (caller retries); Pub/Sub/Eventarc: at-least-once → functions must be **idempotent** because duplicates are possible.
54. **Your Pub/Sub function fails — does Google retry?** — Default: no retries, message dropped. With `--retry`: exponential backoff (10–600s), ~24h window. Return non-retryable statuses for permanent errors.
55. **How do you make a kill-switch function idempotent?** — At-least-once delivery → same event twice. Check state before acting (instance already stopped? billing already disabled?), use event ID as a key, make side effects re-runnable.
56. **How does the budget-alert → Pub/Sub → Cloud Function kill-switch work end to end?** — Budget threshold → Pub/Sub notification (payload: `costAmount`/`budgetAmount`) → function decodes → `cost/budget ≥ 0.95` → stops GCE instances via Compute API with the SA's IAM roles.
57. **What are the kill-switch gotchas?** — Budget alerts lag real spend (hours) → set budget below your cap; disabling billing kills ALL services; function stops instances not node pools (documented limitation); the budget alert must publish to the topic or it never fires.
58. **Would you disable billing or selectively stop resources?** — Selective stop (label-gated) preserves data and avoids collateral; full billing disable is the hard backstop with data-loss risk.
59. **What IAM roles does the kill-switch need, and what if they're wrong?** — `compute.instances.stop` scope; misconfigured roles = silent failure — message arrives, API calls denied. (Your function runs on the default runtime SA; the deployment adds `GCP_PROJECT` env var.)

### 2.7 Terraform/GCP scenarios

60. **Plan shows 20 resources being replaced that you never touched. What do you do?** — Don't apply blindly: provider version drift? count index churn? renames? `plan -refresh-only` to separate refresh noise; fix root cause first.
61. **A 2 AM apply crashed: half-created resources, state lock held. Walk the recovery.** — Confirm lock holder dead → `force-unlock` → `state list/show` → import partials or `state rm` ghosts → reviewed plan to converge → add prevention (CI gates, saved plans).
62. **Someone deleted the managed GKE cluster in the console. Plan wants to recreate it. What do you check?** — Is recreation intended (data loss risk)? Dependents (static IPs, disks, namespaces) need re-adoption via import; verify plan matches desired config.
63. **`state rm` vs `destroy` — when would you accidentally do the wrong one?** — rm detaches (resource survives); destroy deletes real infra. Mixing them up orphans resources or deletes things still in use.
64. **A resource exists in the cloud but was created outside Terraform. Adopt it.** — Write the matching block, `terraform import <addr> <id>`, plan, reconcile diffs, apply. Import never modifies the resource itself.
65. **`apply` vs `apply -refresh-only` vs `state rm` as drift-recovery tools?** — Apply converges config to reality; refresh-only updates state to reality without infra changes; state rm surgically detaches one resource. Choose by whether config or reality should win.
66. **How do you prevent deletion of prod infra through Terraform?** — `prevent_destroy`, separate prod state with restricted IAM, plan approval gates, org-policy guardrails.
67. **Design Terraform state for a 5-engineer team on GCP.** — GCS backend, per-env prefixes, object versioning, locking, plan-on-PR/apply-on-merge CI, env-scoped SAs, elevated prod approvals.
68. **Your kill-switch function triggered twice for the same alert. What went wrong and how do you prevent it?** — At-least-once redelivery; make it idempotent (check instance state before stopping, dedupe by event ID).

---

## Part 3 — Kubernetes Core & Workloads

### 3.1 Scheduling, lifecycle, self-healing

1. **How does the scheduler decide where a pod goes?** — Filtering (node selectors, affinity, taints, resources) then scoring (spread, balance). Requests matter, not limits.
2. **`requests` vs `limits` — and what happens when you set one but not the other?** — Requests for scheduling + guaranteed quota; limits for throttling. No requests → BestEffort pod can get evicted/OOM first. Set limits without requests → guaranteed-class behavior. Your project: `250m` request / `1000m` limit for Postgres was deliberate schedulability math.
3. **Why was Ollama OOMKilled even though the limit was 4 Gi?** — 3B Q4 model ≈ 2 GB, plus context windows and `OLLAMA_NUM_PARALLEL` — memory is the binding constraint on CPU inference; that's why 8 GB nodes.
4. **What's the difference between a `Deployment`, a `StatefulSet`, and a `DaemonSet`?** — Stateless with stable identity/order vs persistent identity (CNPG uses StatefulSets under the hood — your pods are named `ha-postgres-1/2/3`) vs exactly-one-per-node (Cilium agent, kube-proxy).
5. **What is a PodDisruptionBudget, and when is it useless?** — Protects only *voluntary* disruptions (drains, evictions), never involuntary ones (node loss, OOM). A PDB of 1 for CNPG means one instance can go down for maintenance — but a dead node still takes the instance on it.
6. **Walk through a pod's lifecycle from Pending to Running.** — Scheduler assigns node → kubelet pulls image, creates containers → init containers → readiness gate → Running. CrashLoop → BackOff → eviction on node pressure.
7. **What are the three eviction thresholds, and what order do they bite?** — Node pressure: disk, memory, PID. Evict BestEffort first, then Burstable by usage, then Guaranteed (only memory).
8. **`kubectl get events` vs `describe pod` — where do you look for a scheduling failure?** — Events for transient; describe's Events section for persistent. A stuck Pending almost always has a `FailedScheduling` event with the real reason (taint, quota, capacity).
9. **What is a taint, a toleration, and a node selector, and where does each apply?** — Taint repels pods that don't tolerate; toleration admits a pod to tainted nodes; nodeSelector pins to labeled nodes. Your system pool: `CriticalAddonsOnly` taint + Cilium tolerations.
10. **Affinity vs anti-affinity — give a project example.** — `enablePodAntiAffinity` + `topologyKey: zone` on CNPG: never two Postgres pods in the same zone, so one zone loss ≠ quorum loss.
11. **What's the difference between soft and hard affinity, and when do you use soft?** — preferred (best-effort spread, ignore if impossible) vs required (mustPlace). Soft for latency; hard for quorum.
12. **Readiness vs liveness probes — a pod that's alive but not ready.** — Liveness restarts dead processes; readiness removes from service endpoints. A misconfigured liveness probe (crash-loop) is worse than a readiness probe. CNPG uses both: the primary's liveness failing is what drives automatic failover.
13. **What does a readiness probe failure do to a Service?** — Pod stays running, endpoints removed. Envoy would stop routing to it. If *all* endpoints fail readiness, traffic errors — probe with a `startupProbe` first for slow apps.
14. **Startup probe — why does it exist?** — Slow-booting containers would be killed by liveness before ready; startup gates the liveness clock. (Your Ollama model-load cold start is exactly this case.)
15. **What is a ReplicaSet and why do Deployments manage them?** — Desired-count controller; Deployment adds rollout/rollback semantics on top. Scaling, updates, and versioning all happen through the RS.
16. **Rolling update vs recreate vs blue-green vs canary?** — Recreate: down-time but simple; rolling: default, `maxUnavailable`/`maxSurge`; blue-green: instant rollback, double cost; canary: progressive traffic. Gateway API + Envoy make weighted canaries a YAML change.
17. **A pod is CrashLooping — debug sequence?** — `logs --previous` (killed process) → describe (events, image pull, probe failures) → check exit code (137 = OOM, 1 = app error) → `kubectl exec` a known-good image for environment comparison.

### 3.2 Services & networking

18. **ClusterIP, NodePort, LoadBalancer, ExternalName — when is each appropriate?** — Internal-only (default), node-visible (debug/edge), external LB (Envoy gateway), DNS alias. The `-rw`/`-ro` services for CNPG are ClusterIP; Envoy is the only LoadBalancer (your 4-IP quota).
19. **How does `kube-proxy` implement ClusterIP, and what are its problems at scale?** — iptables DNAT, random across backends, O(n) rule traversal and full regen on any change → replaced by Cilium's eBPF in your cluster.
20. **kube-proxy replacement — what does that mean and who validates it?** — Cilium's eBPF datapath implements Service load balancing in the kernel (O(1) map lookups, no userspace hop); `kubeProxyReplacement: true` and the `cilium status` KubeProxyReplacement line is the check.
21. **What is the Service session affinity, and when would you need it?** — Sticky sessions per client IP; needed for in-memory state — at the price of uneven distribution.
22. **Headless services — what are they and why would you use one?** — No virtual IP; DNS returns pod IPs directly; used by StatefulSets for stable discovery and by CNPG for direct pod addressing.
23. **Pod IP churn — why do apps fail on reconnect, and what's the fix?** — New pod IPs on every restart; apps must resolve by service name, not cached IPs.

### 3.3 Storage

24. **PersistentVolume, PersistentVolumeClaim, StorageClass — the division of labor.** — PV is the physical volume, PVC the request, StorageClass the provisioning policy (type, reclaim, speed). The admin writes PV/StorageClass; the app writes PVC.
25. **Static vs dynamic provisioning?** — Static: admin pre-creates PVs; dynamic: StorageClass provisions on demand. GKE: `standard`/`pd-standard` class, dynamically provisioned for your CNPG PVCs.
26. **Why is CNPG's in-place resize possible, and what are its limits?** — StatefulSet PVCs are immutable, so the operator grows the existing claim + disk + filesystem; limits: class must support expansion, and the filesystem must grow online (ext4 does).
27. **What is `emptyDir` and when should you NOT use it?** — Ephemeral per-pod scratch (your Ollama models live here — re-download on pod reschedule). Not for anything durable; `medium: Memory` is RAM-backed tmpfs.
28. **Local vs network storage on GKE?** — pd-standard/SSD regional or zonal disks vs local SSDs (ephemeral). Your Postgres uses zonal pd-standard with node-affinity — a zone death loses the instance but not the data.
29. **What happens to PVCs when a StatefulSet scales down or the pod dies?** — PVCs persist (retain); the pod rebinds on reschedule. Scaling a StatefulSet down never deletes claims — that's manual and dangerous.

### 3.4 Controllers, operators, CRDs

30. **What is a controller, in one sentence?** — A reconciliation loop: observe the desired state (spec), compare to reality (status), take actions to converge, forever.
31. **What is an operator, and why is a database a natural fit?** — Controller + domain knowledge (failover, backups, storage growth) wrapped in a CRD. Declarative day-2 operations — this is the entire CNPG premise.
32. **What are CRDs and what's the difference between a CRD and a controller?** — CRD is the schema (data); the controller is the behavior (code). A CRD without a controller is just storage.
33. **Why does the CNPG controller crash-loop on a partially applied install?** — It watches `postgresql.cnpg.io` resources; if one of the 6 CRDs is missing (flaky apply), informers fail → `no matches for kind "Pooler"`. Verify CRD count, not just pod status.
34. **Client-side vs server-side apply — what changed and why did you need `--force-conflicts`?** — SSA stores ownership in `managedFields`, no 256 KB annotation limit, detects conflicts (vs last-applied annotation blowing up on schema growth). Your CNPG `poolers` CRD exceeded the client-side limit.

### 3.5 Config, secrets, RBAC

35. **ConfigMap vs Secret — and why does Secret feel like ConfigMap?** — Same mechanism; Secret is base64 + etcd (encrypted at rest) + RBAC-visible; nobody reads ConfigMaps off disk. Vault/external-secrets for real secret management.
36. **How does a pod consume a Secret, and when is it mounted vs env-injected?** — Volume mounts update live; env vars are snapshots at container start. Secrets in env are visible in `describe pod` — another reason for volumes or CSI.
37. **RBAC: Role vs ClusterRole, RoleBinding vs ClusterRoleBinding.** — Namespaced vs cluster-scoped pairings; ClusterRole can be bound namespaced (the common pattern: cluster-wide template, per-ns grants).
38. **Your chaos-mesh RBAC ships `*` on chaos-mesh resources — what's the risk?** — Any pod impersonating the controller SA could run experiments. In production: bind only the manager's SA and scope verbs.
39. **ServiceAccount vs User — where does Workload Identity plug in?** — SA is an in-cluster identity; WI maps the K8s SA to a GCP SA via the `iam.gke.io/gcp-service-account` annotation + `workloadIdentityUser` binding, minting short-lived GCP tokens at runtime.
40. **How do you audit who did what in the cluster?** — Kubernetes Audit Logs (control plane) + GCP Cloud Audit Logs; enable on admin actions; the SA-to-user mapping matters for attribution.

### 3.6 Cluster lifecycle & operations

41. **What are release channels on GKE, and why did you pin `min_master_version`?** — Rapid/Regular/Stable gate control-plane upgrades; pinning gives deterministic behavior. You pinned 1.35.5 for image-volume support (needed by the Envoy dynamic WAF module).
42. **How do you upgrade a GKE cluster safely?** — Control plane first (channel), then node pools (surge/maxUnavailable), PDBs in place, watch disruption budget usage; test in a dev cluster first; `kubectl get nodes` version spread.
43. **What is node auto-repair and why does it sometimes not save you?** — Detects broken nodes and recreates; unschedulable pods still need capacity and a scheduling decision. A spot node killed mid-drain leaves pods re-pending.
44. **Cluster Autoscaler — what does it consider before scaling a node pool?** — Unschedulable pods + per-pool min/max + spare capacity; it doesn't scale for CPU headroom, only for unschedulable pods.
45. **Your cluster runs at 98% allocatable CPU with free quota — what's actually going on?** — GKE system daemonsets (Cilium, kube-proxy, netd, fluentbit, node metrics) consume ~0.5 vCPU/node before any workload; per-pool sizing must budget them.
46. **What is the `CriticalAddonsOnly` taint, and what happens to core addons if you remove it?** — Keeps user workloads off system nodes; removing it lets app pods land on system nodes and evict core addons (DNS outage, network outage).
47. **How do you drain a node without downtime?** — `kubectl drain` with PDBs honored, daemonsets tolerated (`--ignore-daemonsets`), then evictions complete; verify cluster capacity can absorb the load first.
48. **What's the difference between a voluntary and an involuntary disruption — give examples from this project.** — Voluntary: node drain, autoscaler scale-down, upgrade (controllable, PDB-protectable). Involuntary: spot preemption, zone outage, kernel panic (not PDB-protectable — this is why you test failover with a force-kill).

---

## Part 4 — Cilium, eBPF & WireGuard

### 4.1 eBPF fundamentals

1. **What is eBPF, and why is it a revolution for networking and observability?** — A kernel VM: safe programs (verified bytecode) attached to hooks (packets, syscalls, tracepoints) running in kernel space with O(1) map data structures — without modules or kernel rebuilds.
2. **What are eBPF maps, and why is the O(1) claim true?** — Hash tables/arrays shared between kernel programs and userspace; lookups constant-time regardless of rule count — vs iptables' linear chain traversal and full-rebuild churn.
3. **Why is iptables the bottleneck at scale?** — Every new service adds a chain of rules; packets traverse sequentially (O(n)); any change regenerates the whole ruleset. Thousands of services → hundreds of thousands of rules.
4. **What is Cilium, architecturally?** — Agent (per-node daemon, watches the API server, compiles desired state to eBPF programs and loads them), Operator (cluster-wide: IPAM, identity allocation), datapath (in-kernel L3/L4/L7), Hubble (observability), CLI/UI.
5. **How does Cilium program the datapath — what happens when a new Service is created?** — Agent watches API events → translates Service/Endpoints into eBPF map entries → packets get hashed to backends in-kernel. No ruleset regeneration, no userspace hop.
6. **What does "kube-proxy replacement" mean operationally?** — The kube-proxy DaemonSet becomes optional; Cilium's datapath does Service load balancing. `kubeProxyReplacement: true` + the `KubeProxyReplacement` status line is your proof. (Your main.tf removes the default node pool, so kube-proxy never ran as a pod.)
7. **Cilium uses BPF for the dataplane — what do the CNI plugins it replaces do?** — CNI (flannel/calico/weave) is just IP assignment + routing; Cilium keeps the CNI contract (pod network setup via the plugin interface) while owning the datapath underneath.

### 4.2 WireGuard & encryption

8. **WireGuard vs IPsec — trade-offs?** — WireGuard: ~4k LOC, kernel-resident, modern Noise protocol, very high throughput, zero config churn; IPsec: established standard, hardware offload, interop with non-Linux peers, but complex (IKE, SAs, lifetimes). Cilium supports both; you chose WireGuard for simplicity and performance.
9. **Where does WireGuard encryption happen in the kernel, and what's the actual packet path?** — Pod sends plaintext → pod's `eth0` (encrypted *inside* the `cilium_wg0` device) → node's physical NIC as UDP/51871 node-to-node datagram. Your three-point capture: plaintext at pod, plaintext at tunnel mouth (tcpdump taps before encryption), ciphertext on the wire.
10. **What does WireGuard NOT protect you from?** — Nothing on the same node (same-node traffic never enters the tunnel), nothing inside the pod (app-level), and no workload *identity* (mTLS territory). WireGuard is transport encryption, not authentication of the peer workload.
11. **What is the cost of WireGuard in throughput/latency?** — Small CPU cost per packet (encryption in kernel), ~µs added latency; your project measured nothing alarming and the trade is paying one node-hop crypto for entire-cluster confidentiality.
12. **How do you prove encryption is working — what's the three-point tcpdump story?** — 1) pod eth0: plaintext HTTP; 2) node `cilium_wg0`: still plaintext (capture is pre-device); 3) node eth0, `udp port 51871`: opaque 464-byte datagrams. Plus `cilium encrypt status` and the toggle test (`encrypt disable` → plaintext on eth0 → enable → opaque again).
13. **Why did encryption not actually happen when you first enabled it?** — `ipv4NativeRoutingCIDR` was the node subnet only; WireGuard routes for pod CIDRs were never programmed. The `/8` fix covers pods (`10.1.0.0/16`) and services. Lesson: config "enabled" ≠ traffic "encrypted" — verify with packets, not with status output.
14. **What is a node-to-node handshake and how often do keys rotate?** — WireGuard peers exchange keys once per node pair (re-key periodically); no per-flow handshake, so no per-connection latency cost.
15. **Where would you run WireGuard and where wouldn't you?** — Nodes in your own VPC: yes. Anything with a public IP, or where you need identity: mTLS instead. A WAF boundary (public-to-Envoy) is TLS, not WireGuard.

### 4.3 Hubble & observability

16. **What is Hubble and why does Cilium need its own observability layer?** — Cilium bypasses netfilter; tcpdump/netstat see nothing useful. Hubble taps the eBPF datapath to expose flow logs: source, destination, verdict, latency — pod-aware, policy-aware.
17. **Hubble Relay vs the agent vs the UI?** — Agent per node captures local flows; Relay aggregates across nodes (cluster-wide view); UI is the web lens. CLI (`hubble observe`) talks to Relay — that's why you port-forward the Relay, not the agents.
18. **A checkout call fails. Hubble shows the flow is dropped. What does that mean vs kube logs?** — Hubble sees the denial before the app ever gets the packet (e.g., NetworkPolicy, policy verdict); `kubectl logs` would show nothing because the app never saw the request. Flow-level debugging is the *first* place to look for network failures.
19. **What metrics does Cilium expose and how do you scrape them?** — Agent/operator Prometheus endpoints; `prometheus.enabled: true` in your values; the ServiceMonitor becomes active when kube-prometheus-stack lands — metrics (packet drops, policy verdicts, endpoint health) flow continuously.
20. **How does Cilium do identity — what's a security identity and how is it different from an IP?** — Labels → identity (numeric ID) shared by all pods with the same labels; policy is written against identities, not IPs, so pod churn never breaks policy and rules stay small.
21. **CiliumNetworkPolicy vs Kubernetes NetworkPolicy — which one wins and why?** — Both work; Cilium's is richer (L7 HTTP rules, identity-based, DNS-aware). K8s NetworkPolicy is L3/L4 by IP — brittle with churn.
22. **Does the WAF (in Envoy) conflict with Cilium policies?** — No: different layers. WAF blocks at the edge before routing; Cilium enforces east-west between pods. Defense in depth: edge for external payloads, mesh for internal compromise.

### 4.4 Troubleshooting scenarios

23. **Pods in different nodes can't talk. Where do you look?** — Hubble flow log verdict → `cilium status` (datapath) → node-level `tcpdump` on `cilium_wg0` vs eth0 → route table (`ip route`) for pod CIDRs → NetworkPolicy in effect.
24. **After enabling WireGuard, all cross-node traffic drops. Debug?** — Check the route for `10.1.0.0/16` (your `/8` fix) and the handshake state; verify UDP/51871 is open on node firewalls; check `cilium encrypt status` and the agent logs for missing peer config.
25. **`cilium connectivity test` fails on the L7 test — what does that isolate?** — L7 policy vs datapath: if L3/L4 passes but L7 fails, the policy allow-list is wrong (missing method/path), not the network.
26. **Cilium agent won't start on GKE — what's the `cni.binPath` story?** — COS mounts `/opt/cni/bin` read-only; Cilium's installer needs a writable path. Your values set `cni.binPath: /home/kubernetes/bin` (the GKE convention). Classic platform-vendor integration gotcha.
27. **Why did you set `tolerations` for the operator and agents?** — Cilium must run on the tainted system pool too; without tolerations the agents land only on app nodes and system nodes get no datapath.

---

## Part 5 — Gateway API, Envoy Gateway & the WAF

### 5.1 Gateway API fundamentals

1. **What is the Gateway API and how does it differ from Ingress v1?** — Role separation (Cluster operator: GatewayClass/Gateway; app teams: HTTPRoute), no annotation-driven config, cross-namespace routing, L4+L7, extensibility (policies), portability across implementations.
2. **Name the four object types and who owns each.** — GatewayClass (cluster operator, provider-defined), Gateway (cluster operator), HTTPRoute (app team), Service (app team). Your `boutique-gateway` in `envoy-gateway-system`, route in `boutique`.
3. **Cross-namespace routing — how does it work and what controls it?** — The Gateway's `allowedRoutes.from: All`; the route's `parentRefs` references a Gateway in another namespace. Without `allowedRoutes`, only same-namespace routes bind.
4. **What happens when a Gateway is created — what's the "Accepted" condition?** — The controller (Envoy Gateway) takes the Gateway, provisions the LB + Envoy deployment, and sets `Accepted=True` when the config is valid. `Programmed` means the dataplane is live. Your script waits on exactly that condition.
5. **How does Envoy Gateway turn YAML into running Envoy?** — Control plane watches Gateway API resources → translates to Envoy xDS config (LDS/RDS/CDS/EDS) → pushes over gRPC to the data-plane pods. Config changes are pushed, not reloaded — no connection drops on route updates.
6. **Why did you replace ingress-nginx, and what did the transition involve?** — ingress-nginx is retired (no security fixes since 2026); Envoy Gateway is the actively maintained successor with Gateway API native support. Transition: swap GatewayClass/gateway, convert annotations to HTTPRoutes, no app changes.

### 5.2 Envoy specifics

7. **What is Envoy, and why is it the proxy of choice?** — High-performance L4/L7 proxy with xDS-based dynamic config, rich observability (stats, access logs, tracing), extensible filters (Lua, WASM, dynamic modules), battle-tested at scale.
8. **What are Envoy's filter chains and where does the WAF sit in one?** — Listeners run filter chains in order; Coraza is a WAF filter in the chain, so payloads are inspected before routing. The order matters: WAF before router.
9. **Envoy's config is notoriously complex — how does Envoy Gateway solve that?** — Humans write Gateway API objects; the controller synthesizes xDS. The 20k-line config problem is delegated to the controller, and it's versioned declaratively.
10. **How does Envoy do load balancing, retries, and timeouts on the data plane?** — Weighted round-robin/least-request per cluster; retry policies (idempotent verbs only), circuit breakers (max connections/pending/rq), timeouts per route. All configurable via HTTPRoute/BackendTrafficPolicy.

### 5.3 The WAF (Coraza / OWASP CRS)

11. **What is Coraza, and what does "in-process WAF" mean?** — A Go WAF engine implementing the OWASP ModSecurity (SecRules) language; runs as an Envoy dynamic module — the filter executes inside the proxy's process, no extra hop or sidecar.
12. **What are the OWASP CRS (Core Rule Set) rules, and what do they protect against?** — ~200+ rules: SQLi, XSS, path traversal, command injection, scanner detection, protocol anomalies, LFI/RFI, SSRF-ish payloads. Your `waf-test.sh` covers five classes, all blocked 5/5.
13. **How did you integrate Coraza with Envoy — walk through the mechanism.** — EnvoyExtensionPolicy (WAF filter for the gateway) → dynamic module (`.so` compiled from the `composer` image, mounted via image volumes) → `GODEBUG=cgocheck=0` → directives: `Include @coraza.conf`, `SecRuleEngine On`, `Include @owasp_crs/*.conf`, `SecResponseBodyAccess Off`.
14. **Why does this WAF setup need Kubernetes 1.35+?** — Image volumes (sharing a layer from one image into another pod without a sidecar) landed in 1.35 — the reason you upgraded the cluster from 1.34 → 1.35.5.
15. **`SecResponseBodyAccess Off` — what does that mean and why turn it off?** — Don't buffer/inspect response bodies (only requests) — saves memory, avoids scanning your own responses; acceptable because attacks arrive in request bodies/params.
16. **WAF ruleset is false-positive prone. How would you tune it?** — CRS has paranoia levels (1–4), anomaly score thresholds, rule exclusions per path/app; test with OWASP ZAP + real traffic, whitelist specific rules for known-good patterns.
17. **WAF vs IDS/IPS — where does Coraza fit?** — WAF: inline, app-aware, blocks payloads (it's also a detection engine, but inline placement makes it preventive). IDS: passive, network-level, alerts; IPS: inline, network-level. Coraza = inline + app-aware.
18. **How did you prove the WAF is actually the thing blocking — and not Cloudflare or the app?** — The toggle test: delete the EnvoyExtensionPolicy → 5/5 payloads pass; reapply → blocked. Receipts in Envoy logs (`coraza`/`denied`). Also Cloudflare is in front, so the same test through CF proves the 403s come from Coraza, not CF.
19. **What attacks did you test and what were the results?** — `1' OR '1'='1` (SQLi), `<script>alert('xss')</script>` (XSS), `../../../etc/passwd` (path traversal), `; cat /etc/passwd` (command injection), `' UNION SELECT * FROM users--` (UNION SQLi) → all 403. Plus an OWASP ZAP passive scan.
20. **SQLi that's encoded/obfuscated — does CRS catch it?** — CRS normalizes: URL decoding, backslash escaping, comment stripping, repeated decoding; paranoia level 4 catches most obfuscation at the cost of false positives. WAFs are not perfect — layered defenses (parameterized queries) still mandatory.
21. **What is a false positive and what's your process for handling them?** — Legit traffic blocked by rules; triage via Envoy access logs + rule IDs, then exclusion rules or rule tuning, retest with the same traffic.
22. **Where does Cloudflare fit in the security story?** — CDN + DDoS absorption + TLS termination (Flexible: HTTPS to world, HTTP to origin); the origin WAF (Coraza) inspects plaintext — which is why Flexible doesn't weaken the WAF. Note the honest caveat: origin-to-CF TLS is not end-to-end.
23. **Why 403 with an empty body, and how would a client see it?** — Blocked requests return 403 without body — clean, fast, no info leak; the WAF's default denial behavior. Clients just see a 403.
24. **HTTP/2, gRPC, or WebSockets through Envoy — does the WAF inspect those?** — Envoy speaks all three; Coraza inspects HTTP/1.1 and HTTP/2 request payloads; gRPC (protobuf bodies) needs content-type-aware rules; WebSockets are upgraded connections — a WAF gap to acknowledge.
25. **You have one LB IP (quota). How would you host a second site?** — One Gateway, multiple HTTPRoutes by hostname; same LB IP, virtual hosting. This is exactly why the Gateway is shared and routes are namespaced.

---

## Part 6 — PostgreSQL & CloudNativePG

### 6.1 Postgres core

1. **What is WAL, and why does every backup/replication mechanism in Postgres hang off it?** — Write-Ahead Log: every change first appended (durably) to the log, then applied to data pages. Crash recovery replays WAL; replication ships WAL; PITR replays WAL over a base backup.
2. **What is a checkpoint and what does it mean for recovery time?** — Periodically writes dirty buffers to data files, advancing the WAL replay point; longer checkpoint distance = longer crash recovery. `checkpoint_timeout`/`max_wal_size` trade durability-consistency against recovery time.
3. **WAL archiving vs streaming replication — how do they differ and why does CNPG use both?** — Archiving: ship WAL segments to storage (barman → GCS) for backup/PITR; streaming: ship to replicas continuously for replication. CNPG runs both: replicas stream, and everything (including on replicas) archives to the object store.
4. **What does `synchronous_commit` actually guarantee?** — The commit isn't acknowledged until WAL is durable *on the standby* (per `synchronous_standby_names`). Every acknowledged write survives leader loss — that's your RPO ≈ 0 and the 0.000% failed-transaction result.
5. **What happens to synchronous replication if the sync standby dies?** — The primary silently demotes to async (two-safe window: acknowledged commits no longer protected until it re-syncs or promotion happens). `synchronous_commit = remote_apply` vs `on` vs `local` trade what's durable-when-acknowledged.
6. **What is the performance cost of synchronous replication?** — A round trip to the standby per commit (unless `group_commit` batches); your 396.6 tps at scale-100 with 50 clients includes that cost — write latency grows, read latency doesn't.
7. **Replication slots — what happens when a replica falls too far behind?** — A slot pins WAL on the primary until consumed; a dead replica with a slot grows WAL forever (disk-fill). CNPG manages slots and warns on lag — this is the "lag <100 ms" SLI in your steady-state check.
8. **What is PITR, and what does "30d" retention mean for it?** — Point-in-time recovery: base backup + replay of WAL to an arbitrary timestamp. Your `retentionPolicy: 30d` keeps base backups + WAL for 30 days → restore to any moment in that window.
9. **What is a vacuum, and why does the system care?** — MVCC dead rows need reclamation; autovacuum runs it; a DB without vacuuming bloat-dies. The "vacuum bloat" metrics exist in your Grafana dashboard for a reason.
10. **What is connection pooling, and why didn't you deploy PgBouncer?** — Postgres forks a process per connection; 50 pgbench clients × threads exhaust memory; poolers (PgBouncer/CNPG Pooler) multiplex. You didn't need one at demo scale — and being able to name this as a known scale-up step is the right answer.
11. **What is a connection limit and what happens when you hit it?** — `max_connections` (default 100): further connections rejected (`too many clients`) — apps fail, not gracefully. Poolers + connection monitoring prevent this.
12. **`pgbench` — what is it actually measuring?** — TPC-B-ish workload (branches/tellers/accounts, 90% update-10% insert-ish); tps = transactions/sec at given concurrency; your numbers: scale 100, 50 clients, 4 threads, 5 min → 396.6 tps, 0 failed. Scale-100 ≈ 10M rows ≈ 1.4 GB.

### 6.2 CloudNativePG operator

13. **What is the operator pattern and why for databases?** — Controller watching a CRD with domain knowledge: the CNPG operator owns leader election, failover, backups, storage growth, PDBs, upgrades — the day-2 work that used to be "SSH + shell script."
14. **What is in the CNPG `Cluster` spec, and what does the operator do with it?** — instances, image, affinity, resources, storage, backup (barman) — converges the cluster to spec and keeps it there (self-healing: a dead instance is replaced, the role label re-pointed).
15. **How does CNPG do leader election?** — Lease-based election among instances; the operator watches health, promotes the healthiest replica on failure, moves the `cnpg.io/instanceRole=primary` label and re-points the `-rw` service. Failover in your tests: seconds.
16. **`-rw` vs `-ro` services — what's the semantic contract?** — rw always → current leader; ro → replicas (read scaling). Apps encode topology in the service name, not by guessing pod names.
17. **How does CNPG do storage growth?** — The operator expands the PVC (allowed in-place on GKE), the underlying disk, and the filesystem — pod-by-pod, no restart. Your demo: 1 Gi → 8 Gi while pgbench was running against it.
18. **How does barman fit in — base backups + WAL archiving?** — barmanObjectStore: scheduled base backups (from `backup.retentionPolicy`) + continuous WAL archiving (gzip) to GCS; restore is a `Cluster` with a bootstrap `recovery` block.
19. **No `googleCredentials` in the barmanObjectStore — how does the backup authenticate?** — Workload Identity fallback: the pod's metadata-server credentials are the bound GCP SA (`pg-backup-sa` → `database/default`). No keys anywhere — the whole chain is identity-based.
20. **Why `enablePodAntiAffinity` + `topologyKey: zone`, and what happens if a zone fails?** — Max spread: one instance per zone; a zone failure loses one instance, quorum survives, failover can still happen. Without it, two replicas could sit in one zone and a zone loss could kill quorum.
21. **What is the CNPG PodDisruptionBudget, and what does it protect?** — Voluntary disruptions can't take out quorum: the operator writes a PDB (e.g., minAvailable based on quorum) so drains/upgrades degrade gracefully.
22. **What is `resizeInUseVolumes` and when is it required?** — Required on the spec change to resize online; without it the operator may still resize claims, but the flag makes it in-place across the cluster.
23. **What happens when a CNPG instance pod is force-deleted — walk the event chain.** — Pod disappears (no graceful shutdown) → operator detects missing primary → promotes a replica (label + service re-point + re-sync of the third) → new primary is already current (sync replication) → the old pod is replaced as a replica. Your watch loop saw `New leader` inside seconds with zero failed pgbench transactions.
24. **What's a promotion vs a failover?** — Promotion: intentionally promoting a replica (maintenance). Failover: responding to primary failure. CNPG handles both; a failover is a promotion triggered by failure detection.
25. **How would you do a planned failover for maintenance with CNPG?** — `kubectl cnpg promote` (or `switchover` via plugin) with `synchronous_standby_names` already set; the operator does a graceful switch — your tests show it can also be done with a forced kill to prove the ungraceful path.
26. **Restore from backup — what does the YAML look like?** — New Cluster CR with `bootstrap.recovery: { source: <backup>, pointInTimeRecovery: { timestamp } }`, backups defined with barmanObjectStore. RTO/RPO depend on base backup + WAL replay speed.
27. **What if the whole cluster is lost — how do you restore?** — Recreate the operator, apply a recovery Cluster CR pointing at the GCS store, let the operator rebuild from base + WAL; validate with a real restore drill (that's what your README's Extension F is for).
28. **How do you monitor CNPG?** — Built-in metrics endpoint + `enablePodMonitor: true` → Prometheus: replication lag, TPS, connections, WAL rate, bloat, backup status. Your Grafana dashboard is built on exactly these.
29. **Spot preemption hits a Postgres node — what happens?** — Involuntary disruption: PDB can't help; the pod dies; operator fails over; storage (zonal disk) survives in the zone; new replica rebuilds. This is exactly the scenario your force-kill failover test simulates.

### 6.3 Deep scenarios

30. **You see replication lag climbing. What's the investigation path?** — Check WAL shipping vs replay: standby CPU (single-threaded replay), network (WireGuard tunnel in between — check Hubble for drops), oversized transactions, `max_standby_streaming_delay`. Lag >100 ms trips your steady-state check.
31. **A transaction runs for 40 minutes. What breaks?** — WAL growth, vacuum can't clean, replica replay stalls; standby might lag past your threshold. Long transactions are a design smell — batch them.
32. **The `-rw` service times out during failover — what's the window?** — Between primary death and service re-point: your observed seconds; clients with no retry fail, retrying clients don't. The k8s service selector updates are near-instant; the operator's promotion is the floor.
33. **How do you scale reads in this setup?** — Add instances (replicas serve `-ro`); but streaming replicas add write amplification and WAL traffic. Beyond 2-3 replicas: external read replicas or a pooler.
34. **Why did pgbench initially fail with `relation "pgbench_branches" does not exist`?** — The trailing DB-name argument was dropped, running against the `postgres` database instead of `app` — init and run must target the same DB.
35. **Backup retention "30d" — what does CNPG actually delete?** — Old base backups (barman policy: keep at least N, prune beyond retention); WAL is pruned when no base backup needs it. Verify with `kubectl cnpg backup list`.

---

## Part 7 — Chaos Engineering

1. **What is chaos engineering, and what is it NOT?** — The practice of injecting failures in a controlled, observable way to prove hypotheses about resilience. It's not random destruction; it's hypothesis-driven experimentation with a steady-state baseline and a blast radius.
2. **What are the three components of a chaos experiment?** — Steady-state hypothesis (what "healthy" looks like — your SLIs ConfigMap), injection (the fault), and comparison (before vs after). No hypothesis, no chaos engineering — just sabotage.
3. **What is the blast radius, and how did you bound yours?** — The scope of impact: your experiments target `boutique` workloads, the `database` namespace, or a specific app (`app: ollama`) — never the control plane or core addons.
4. **Why encode the steady-state hypothesis as a ConfigMap?** — Versioned in Git, readable on-cluster, auditable: p99 < 500 ms, error rate < 1%, availability > 99.5%, replication lag < 100 ms, failover < 30 s, data loss = 0. The experiment script reads it as the yardstick.
5. **PodChaos — what does `fixed-percent: 50` mean?** — The experiment kills 50% of matching pods (by count) once, at start, when no scheduler is set. Your pod-kill experiment on the boutique replicas proves the Deployment recovers; a `scheduler` would add repeated kills.
6. **NetworkChaos — what's the `direction: to` about?** — Direction of the delay relative to the target pod (inbound); `direction: both` requires a `targets` list and is more complex — your 500 ms ± jitter 100 ms correlation-50 on the DB tests what a chatty app does under partial latency.
7. **StressChaos on Ollama — what does 90% CPU × 2 workers for 180s prove?** — The pod keeps serving (limits + QoS work) or fails predictably; it also proves the CPU-bound LLM path degrades gracefully instead of OOM-thrashing.
8. **`node-drain.sh` — cordon then drain. Why both, and what are the flags?** — Cordon stops new scheduling; drain evicts (honoring PDBs). `--ignore-daemonsets` keeps Cilium running; `--delete-emptydir-data` acknowledges Ollama models will be lost.
9. **Voluntary vs involuntary disruptions — how do they change your testing?** — Voluntary (drains, upgrades) are PDB-controllable and scheduled; involuntary (node loss, preemption) are not — you test both: the drain script for voluntary, PodChaos/force-kill for involuntary.
10. **Why Chaos Mesh instead of plain `kubectl delete pod`?** — Repeatable, declarative, selective (labels/modes), with duration/cooldown semantics and a dashboard; a chaos experiment is a reviewed artifact, not an ad-hoc command.
11. **How does Chaos Mesh implement pod kill — what's under the hood?** — A chaos-daemon pod on each node manipulates the target pods/containers (via containerd socket, PTRACE injection for some experiments) per the CRD schedule.
12. **What would you NOT chaos-test, and why?** — Control plane, node pools with no PDB coverage, the operator itself in production (chaos on the controller = chaos on recovery), storage media. Start small, widen after the hypothesis holds.
13. **Your NetworkChaos delays the DB — what's the expected effect on the steady-state check?** — p99 rises > 500 ms, error rate may climb past 1% — the check should *catch* the violation. The value is knowing the thresholds trip before users do.
14. **How do you automate chaos in CI?** — Chaos experiments as CRs applied in a staging environment after deploy, steady-state checks gating promotion; or experiment suites (like `chaos-mesh`'s test framework) that assert the hypothesis passes.
15. **What did chaos testing actually change in your project?** — Honest answers: confirmed PDB necessity, exposed that the storefront tolerates latency (or didn't), validated the failover design under load, and surfaced the reaper/queue behavior under pod churn.
16. **GameDay vs chaos engineering — same thing?** — GameDay is the organized practice (scheduled, cross-team, with runbooks); chaos engineering is the technique. Your experiments are chaos engineering; a scheduled multi-team exercise is a GameDay.
17. **What's the difference between fault injection and failure testing?** — Fault: a single deviation (a 500 ms delay, a dropped packet). Failure: the resulting system-level outage (timeout cascade, retry storm). You inject faults to study failures.
18. **How do you know chaos testing is done?** — When every hypothesis in your steady-state ConfigMap holds under every experiment in your library — and you've documented the ones that didn't, with fixes.

---

## Part 8 — KEDA & Autoscaling

1. **How does the Horizontal Pod Autoscaler actually compute replicas?** — `desiredReplicas = ceil(currentReplicas × currentMetric / targetMetric)` (and special-cases for 0/unknown), evaluated every `--horizontal-pod-autoscaler-sync-period`, respecting min/max and scale-down stabilization.
2. **Why is CPU a bad metric for a queue worker?** — CPU is a trailing indicator: a worker blocked on BRPOP idles at ~0% CPU with a growing queue behind it. Queue depth is the *leading* indicator — scale on it directly.
3. **What does "scale to zero" require that HPA can't do?** — HPA's spec forbids `minReplicas: 0`; only an external scaler can. KEDA's ScaledObject drives the Deployment to 0 and back — the demo you ran (queue empty → 3 Ollama replicas → back to 0 after 60s).
4. **KEDA architecture — what are the components?** — Operator (watches ScaledObjects), Metrics Adapter (exposes external metrics to HPA), Scaler implementations (Redis, Prometheus, etc.). The ScaledObject → HPA bridge is automatic.
5. **Walk through your Redis ScaledObject and what each field means.** — `listName: inference_queue` + `listLength: 5` = scale when the queue holds ≥ 5 items (per target listLength); `activationListLength: 0` = when to start/stop scaling at all (activation threshold); `minReplicaCount: 0`, `maxReplicaCount: 3`; `cooldownPeriod: 60` (wait after scale-down signal before actually scaling down — prevents flapping); `pollingInterval: 10` (how often to check).
6. **`listLength` vs `activationListLength` — one is a target, one is a gate. Explain.** — listLength is the HPA target (scale up to match depth/listLength); activation is a separate threshold below which scaling is entirely inactive. Setting both gives hysteresis: no flapping between 0 and 1 replica.
7. **What is cooldown, and what happens if it's too short?** — The minimum time after a scale-down before the next scale-down; too short → thrash (down to 1, back up to 2, down…). Your 60s stabilizes the queue-worker churn.
8. **Scale-to-zero: what happens to in-flight work when the pod dies?** — Pods are terminated; BRPOP-held items are unacked in Redis (the queue keeps them) — the work isn't lost, it's redelivered. At-least-once semantics make this safe; that's why the workers are idempotent.
9. **Scale-up latency — how fast can your system go from 0 to serving?** — KEDA polling (10s) + HPA evaluation + pod scheduling + image pull + Ollama model load (cold start). Total minutes, not seconds — that's the honest answer, and why `OLLAMA_KEEP_ALIVE` matters.
10. **KEDA scaler options for this workload — why Redis and not Prometheus?** — Redis queue length is the direct driver (simple, low-latency); Prometheus scaler would be useful for rate-based metrics (e.g., requests/sec). Multiple scalers = max() semantics.
11. **Cluster Autoscaler vs KEDA at scale — how do they interact?** — KEDA scales pods; CA adds nodes when pods are unschedulable. With scale-to-zero, CA can also scale *down* whole nodes — the combined win of your design.
12. **What's a scaling policy, and how do you stop a thundering herd at scale-up?** — `scaleUp`/`scaleDown` policies (percent, pods/min, periodSeconds) on the HPA; sudden spikes × N replicas can overwhelm the DB — your maxReplicaCount: 3 is itself a backstop.
13. **How would you autoscale on request latency?** — HPA external metrics from Prometheus (e.g., p99 of Envoy latency) via KEDA's Prometheus scaler; latency is trailing but for *serving* workloads it's the right driver.
14. **What breaks scale-to-zero for stateful workloads?** — Any workload with warm caches, in-memory state, long-lived sessions, or connection pools — Postgres cannot scale to zero, which is why the DB (and Redis itself) stay up while only workers scale. "Scale to zero" is per-workload, not per-cluster.
15. **How do you debug "it didn't scale"?** — `kubectl get hpa -o yaml` (conditions, events), `kubectl get scaledobject`, check the scaler's connection (Redis reachable? auth?), verify the ScaledObject's metric name matches the queue, and check activation thresholds weren't tripped.

---

## Part 9 — Redis & Queues

1. **BRPOP — what does it do and why is it the queue primitive?** — Blocking list pop with timeout: a worker blocks on the list and wakes only when an item arrives — the polling-free, low-CPU pattern your workers use (300s timeout, then re-BRPOP).
2. **At-least-once vs at-most-once vs exactly-once — which does this queue give you?** — At-least-once: BRPOP removes the item before processing; a crash mid-work loses the ack — the item is gone, so delivery is at-least-once only if the pattern is BRPOPLPUSH (atomic move to a processing list) + reaper. Your design: at-least-once + idempotency by job ID.
3. **What's the BRPOPLPUSH pattern, and why the "reaper"?** — Atomically move item from main list to an in-progress list, process, LPOP-ack; a crashed worker leaves the item in the in-progress list — a reaper moves stale items back after a timeout. This is the canonical reliable-queue pattern without a broker.
4. **Streams vs lists for queues — when do you graduate?** — Streams add consumer groups, XACK-based acking (per-message, no reaper needed), and replay history. Lists are simpler; Streams are the upgrade path at more scale.
5. **What is an eviction policy, and what's `maxmemory-policy` gotcha on a queue?** — When memory hits maxmemory, Redis evicts; `allkeys-lru`/`noeviction` — evicting *queued work* is data loss. Queues should use `noeviction` and be sized.
6. **RDB vs AOF — what does each guarantee for the queue?** — RDB: periodic snapshots (lose seconds of work on crash). AOF: append-only log (fsync policy trades durability for throughput). Your queue data is ephemeral-but-live: a reasonable trade-off, name it.
7. **A worker crashes mid-JSON-parse — what's the failure mode?** — With BRPOP: item lost (at-most-once!). With BRPOPLPUSH: item stuck in in-progress until reaper. With Streams + XACK: item stays pending, redelivered by XAUTOCLAIM. Know which semantics your queue actually has.
8. **What is a dead-letter queue, and what would push an item to it?** — Items that fail repeatedly (poison messages) — retry N times then park in a DLQ for inspection; without one, a poison message blocks the queue (or burns the reaper forever).
9. **Backpressure — what happens when the queue grows unbounded?** — Memory growth → eviction/OOM; the KEDA scaler spawns workers up to maxReplicaCount (3), and beyond that, the API should reject (503) rather than buffer forever. Your `listLength` threshold is the backpressure trigger.
10. **What's a "hot key" in Redis and why do queues avoid them?** — A single key receiving all traffic (one queue, one shard). Your single `inference_queue` is a hot key by design — fine at this scale, but a sharded design (key by worker) is the scale-up path.
11. **Redis persistence for this workload — would you enable AOF?** — If the queue holds paid work: yes (everyfsync for safety). For inference jobs: RDB is a defensible default — name the trade and the recovery path either way.
12. **`OLLAMA_KEEP_ALIVE=24h` — why does keep-alive matter for the queue?** — Model load is seconds-to-minutes; keeping the model warm (24h) avoids the cold-start tax on every batch — directly relevant to scale-down/up churn.
13. **How do you test queue reliability?** — Kill a worker mid-job (you did with PodChaos): verify the item is re-queued/redelivered, verify idempotency (job IDs), verify the reaper's timeout vs worker processing time.
14. **Queue length as a leading metric — what dashboards did you build around it?** — Queue depth (Redis), worker replicas (HPA), latency of `/infer` → `/result`, cold-start time. The queue chart is the one that *predicts* the rest.

---

## Part 10 — LLM Serving (Ollama)

1. **Why serve an LLM on CPU, and what's the honest performance?** — Trial has no GPUs; llama3.2:3b Q4 ≈ 2 GB fits memory; CPU inference runs 2–5 tok/s — usable for a demo, not production. The scaling infrastructure (queue → workers → zero) is the point.
2. **What is quantization (Q4)?** — 4-bit weight quantization: ~4× memory reduction with modest quality loss. Why it matters on CPU: memory bandwidth is the bottleneck, and fewer bytes per weight = faster decoding.
3. **What does `OLLAMA_NUM_PARALLEL` do, and why 1?** — Concurrent requests per model; parallel >1 on CPU means context swapping and thrash — at 2 vCPU, 1 is optimal for latency; the queue is the concurrency mechanism.
4. **`OLLAMA_KEEP_ALIVE=24h` — what is it doing?** — Time the model stays loaded after last use; without it, the model unloads after 5m default and every request pays a cold start. With scale-to-zero, keep-alive is what makes the *next* scale-up fast.
5. **Why emptyDir for models, and what's the trade-off?** — Models re-download on pod recreation (no state, ephemeral); with scale-to-zero that's fine (pods die anyway) and it avoids PVC churn. Alternative: a shared PVC + cache warm-up script.
6. **The `/infer` → `/result` pattern — why async instead of a synchronous endpoint?** — Inference takes tens of seconds on CPU; a sync HTTP call would hold connections and couple the client to the worker. Queue + poll = decoupling, retries, and the scale-to-zero architecture.
7. **What are tokens and what does tok/s actually measure?** — Token ≈ sub-word unit; tok/s is decode throughput; ~2–5 tok/s is the model output speed on this CPU — the user-perceived metric.
8. **Cold start — what's in the path from 0 replicas to first token?** — KEDA poll (10s) → HPA → pod schedule → image pull → model load (~GB from emptyDir/registry) → first token. Minutes. `OLLAMA_KEEP_ALIVE` + keeping one warm replica trades cost for latency — the classic autoscaling trade.
9. **How would you serve this in production?** — GPU (L4/H100), vLLM/TGI with continuous batching and PagedAttention, tensor parallelism, and KEDA on queue length with GPU-aware metrics (DCGM) instead of CPU-bound Ollama.
10. **How do you monitor an inference service?** — Queue depth (leading), workers (current), `/infer`→`/result` latency (user-perceived), tok/s, model memory (OOM risk), error rate by job ID. Your StressChaos + steady-state check covers the failure side.
11. **Model updates — how do you roll out a new model?** — New tag + rolling update (with emptyDir the pods re-download); canary by serving both models behind different queue keys; pin the digest for reproducibility.

---

## Part 11 — Security (Deep-Dive)

1. **Defense in depth — name the layers in this project and what each blocks.** — Cloudflare (DDoS/TLS) → GCP LB (transport) → Envoy + Coraza WAF (payload attacks) → Gateway API routing (only routes to valid backends) → Cilium + WireGuard (east-west encryption, policy-ready) → Workload Identity (identity, no keys) → private nodes (no public attack surface) → budget kill-switch (cost blast radius).
2. **What is the OWASP Top 10, and which does your WAF defend?** — A1 Injection (SQLi — blocked), A3 XSS (blocked), A5 broken access control (WAF doesn't help — app layer!), A8 insecure deserialization (partially), A9 logging/monitoring failures (observability stack addresses detection). WAFs cover a slice — name the slice.
3. **WAF vs Web Application Firewall vs RASP — what's the difference and why not RASP?** — WAF: inline proxy inspecting payloads (your Coraza). RASP: runtime protection *inside* the app (agent). WAF protects the perimeter; RASP protects the process — they complement; RASP is per-application instrumentation you didn't add.
4. **What is OWASP ZAP and what's the difference between passive and active scanning?** — ZAP is an open-source DAST tool; passive scans observe traffic without attacking (safe to run anywhere — you ran it in CI); active scans fire payloads (must be scoped + authorized).
5. **How do you handle a 403 flood — is that an attack?** — 403s can be bots/scanners (CRS has scanner rules) or legit blocked traffic; correlation: per-IP rate, rule IDs in Envoy logs, anomaly score. Envoy access logs + Hubble + Grafana panels make this a query, not a mystery.
6. **Your WAF runs in Envoy's process — what's the attack surface of the WAF itself?** — The dynamic module runs in-process: a WAF parser bug = proxy crash (your `GODEBUG=cgocheck=0` notes Go/C interop hazards). Mitigation: pin versions, crash-tolerance (Envoy restarts), and never let WAF config errors block traffic silently.
7. **Secrets management — where are secrets in this project, and where should they be?** — Workload Identity eliminates GCP keys; Redis/DB passwords are K8s Secrets (etcd, encrypted at rest) — acceptable; at scale: Vault/External Secrets + rotation. Name what exists and what's next.
8. **What is the "runbook" for a compromised pod?** — Containment: NetworkPolicy to isolate (Cilium identities), kill + reschedule, revoke Workload Identity bindings, rotate anything it could touch, audit logs (K8s audit + GCP logs) for lateral moves, rebuild from GitOps source of truth.
9. **How would an attacker actually get in? (threat model)** — Public surface: Cloudflare→Envoy (WAF'd). Internal: a compromised pod with a service account (RBAC scope!), a leaked secret, or a supply-chain image. The honest gaps you named: RBAC wildcards on chaos-mesh, no network policies enforced in the final state, origin plain HTTP at Cloudflare, no admission control (Gatekeeper/OPA).
10. **SBOM, image scanning, supply chain — what would you add?** — Sigstore/trivy scanning in CI, pinned digests (you pin versions everywhere — extend to images), SBOM per image, admission-time verification (attestations) — the modern chain from build to run.
11. **What's the difference between authentication and authorization — example from the project?** — AuthN: Workload Identity proves *who* the pod is (token → GCP SA). AuthZ: IAM roles decide *what* it can do (objectAdmin on the bucket only). Same token, different decisions.

---

## Part 12 — Observability (Prometheus, Grafana, Datadog, Hubble)

1. **Metrics vs logs vs traces — what does each answer, and what's in this project?** — Metrics (what's trending: Prometheus/Grafana/Datadog), logs (what happened exactly: Envoy access logs, kube logs), traces (which call in a chain is slow: Datadog APM). Your stack: all three, with Hubble's flows as a fourth (what the network did).
2. **Prometheus architecture — pull model, scrape, service discovery?** — Prometheus pulls targets on intervals; kube-prometheus-stack deploys operator + exporters + ServiceMonitors; ServiceMonitor defines what to scrape (namespace selectors, port, labels).
3. **ServiceMonitor vs PodMonitor — when each, and why did you need selector overrides?** — ServiceMonitor scrapes via Service (headless works); PodMonitor scrapes pod IPs directly. Your Envoy pods needed ServiceMonitor with explicit selectors because kube-prometheus defaults (`nilUsesHelmValues`) filtered out non-Helm-managed targets.
4. **Why was the Envoy metrics endpoint on 19001, and why does that matter?** — EG v1.8 serves proxy metrics on 19001 (not the classic 19000) — a ServiceMonitor pointing at 19000 silently scraped nothing. Port + path + labels all have to line up.
5. **What is a metric relabel, and what's the classic use?** — Rewrite labels at scrape time (drop noisy series, set namespace, map `__meta_kubernetes_*`). The WAF Grafana panels' `prometheus` UID datasource fix is the same class of glue.
6. **What's a recording rule and why would you use one?** — Precompute expensive queries (e.g., failover rate) at scrape time; dashboards stay fast, alerting stays cheap. At this scale, mainly a good habit to name.
7. **Alertmanager — routing, inhibition, and why `for: 5m` matters?** — Routes to receivers, inhibits noise, and `for` requires the condition persist before firing (avoids flapping alerts on brief spikes). Your steady-state SLIs are the alert criteria.
8. **SLOs — error budget, and what did your steady-state ConfigMap encode?** — SLO = availability target (99.5%), error budget = tolerated failure share; the ConfigMap's p99 < 500 ms, error < 1%, availability > 99.5% are the SLOs; the chaos experiments *check* them.
9. **Datadog vs Prometheus — why both?** — Prometheus: in-cluster, free, GitOps-able (kube-prometheus-stack). Datadog: managed, APM traces, host map, team-wide access. Both scrape the same kubelet/cadvisor endpoints — complementary, not redundant.
10. **What was the Datadog install gotcha on GKE?** — COS's read-only `/usr` broke system-probe (`mkdir /usr/src`); `providers.gke.cos=true` fixes the mount. Also: empty `DD_API_KEY` = silently broken agent; site (`us5.datadoghq.com`) must match the account.
11. **What is cadvisor and why does every Kubernetes monitoring stack depend on it?** — A daemon that exposes container CPU/mem/net from cgroups — the raw data every metrics system re-exports. GKE runs it on the node (or via Cilium's replacement metrics).
12. **What's the difference between `kubectl top` and Prometheus metrics?** — `top` reads the metrics API snapshot (cadvisor-backed); Prometheus is historical + dimensional. `top` answers "now," Prometheus answers "when."
13. **How do you alert on "slow"?** — PromQL on latency percentiles (histogram_quantile): p99 > 500 ms for 5m. Percentiles, not averages — averages hide tail latency (your pgbench 124.7 ms avg had a much higher p99).
14. **What is Hubble's unique observability contribution?** — Flow-level: per-connection source/dest/verdict/latency — the network's own story, independent of app instrumentation. When checkout fails, Hubble shows whether the packet was dropped by policy *before* the app saw it.
15. **What's the first panel you'd add to a new cluster's dashboard?** — Node CPU/mem (allocatable vs used — your 98% story), pod count/restarts, Service latency + error rate (RED), Postgres replication lag (for CNPG). RED/USE mnemonic: Rate-Errors-Duration / Utilization-Saturation-Errors.
16. **How do you trace a slow request end to end?** — Datadog APM trace: frontend → cartservice → redis; or Hubble flow latency + Envoy access log timings. Without traces, the WAF/mesh layers are blind spots.
17. **What are the gaps in this observability stack?** — Log aggregation is kube-logs only (no Loki/ELK for cluster-wide search), no SLO dashboard as a single pane, no alerting rules committed in the repo (they're in the Helm values — check), no trace context propagation through the queue (job IDs, not trace IDs). Name gaps confidently — interviewers reward it.
18. **How do you version dashboards?** — kube-prometheus-stack ships ConfigMaps as dashboards; commit them, review changes, promote via GitOps. Grafana as a service (the "open dashboards for new stuff" path) is the anti-pattern to name.
19. **What is kube-state-metrics and why does it matter?** — Exposes cluster *state* (deployments desired vs ready, PVC status) — the "declared vs actual" view every dashboard needs. kube-prometheus-stack installs it by default.
20. **Design an alert for the kill-switch firing.** — The function emits a metric/log; alert on `cost/budget ≥ 0.9` (before the kill) → warn; ≥ 0.95 → critical with runbook link. Budget alerts alone arrive hours late — that's exactly why the function exists.

---

## Part 13 — Behavioral & SRE Questions

1. **"Tell me about a time you broke something in production."** — Use a project story with the full arc: what broke (e.g., the 98% allocatable Pending storm), how you found it (events → `kubectl top` → allocatable math), the fix (bigger nodes, 100m requests), and what you changed to prevent recurrence (documented quota math, resource-request reviews).
2. **"Tell me about a time you disagreed with a teammate about an approach."** — Pick a real trade-off (e.g., kube-proxy vs Cilium, or Flexible vs Full-strict TLS) and show you can argue both sides, then commit when the evidence points.
3. **"How do you handle an on-call page at 3 AM?"** — Pattern: triage (is it real? scope?) → mitigate (roll back, scale, blocklist — not "fix root cause under pressure") → document → postmortem. Tie to your kill-switch as an automated mitigation and your failover design as the 3 AM answer for Postgres.
4. **"What's the worst outage you've seen and what did you learn?"** — The WireGuard "encrypted but not actually" incident is perfect: enabled ≠ working; verification at the packet level; the difference between status and truth.
5. **"How do you prioritize between reliability work and feature work?"** — Error-budget framing: SLOs make the call objective; chaos experiments turned "I think we're resilient" into measured SLIs.
6. **"Tell me about a time you had to learn a new technology quickly."** — Cilium/eBPF, Gateway API, or CNPG — you went from docs to verified proof (tcpdump receipts, failover numbers) in days. Mention the verification habit.
7. **"How do you document your work?"** — Your blog series + README: decision logs (why, not just what), verified commands (the "Xb" receipts), and honest "what I'd change" sections. That's documentation with engineering evidence.
8. **"What's your process for debugging a system you don't understand?"** — Follow the data: metrics → logs → flows → reproduce → isolate → fix → verify. Your three-point tcpdump and the 19001 port hunt are the concrete instances.
9. **"How do you handle being wrong?"** — Concrete: the `ipv4NativeRoutingCIDR` mistake — wrong first hypothesis (config issue) corrected by packet evidence. Owning it in the blog and README gotchas.
10. **"Describe a project you're proud of and why."** — This one — and make the case specific: measured outcomes (0.000% failed transactions, 5/5 blocked, < $20 for two weeks), not just tech names.
11. **"What do you do when requirements are vague?"** — Scope by constraints (the quota table), build the smallest verifiable version, surface assumptions in writing, iterate — the exact shape of this project.
12. **"How do you keep yourself current as an engineer?"** — Concrete: tracking GKE/EG release notes (the 1.35 image-volumes pin, ingress-nginx retirement), reading failure postmortems, building (this project is the evidence).
13. **"What's a system you'd like to tear down and rebuild?"** — Have an opinion: the queue is a candidate (Streams, or a real broker), or the WAF-to-origin TLS path (Full-strict with cert-manager). Answers with reasoning beat generic enthusiasm.
14. **"Where do you see yourself in five years?"** — Align with the role: platform engineering, SRE, or infra leadership — and tie it to demonstrated interests (reliability, security, cost, automation).
15. **"Why do you want to work here?"** — Do the homework on their stack — and note where it overlaps this project (k8s, GCP, observability, eBPF).

---

## Part 14 — The Shortlist (highest-probability questions)

*If you only prepare 30 questions, these are the ones.*

### Application (project walkthrough)
1. Walk me through this project — what did you build, why, and what does the architecture look like?
2. What were your constraints and how did they shape the design?
3. What was the hardest problem you solved? (WireGuard `/8` story)
4. What would you do differently with production resources?
5. Give me three concrete numbers that prove it works.
6. Why did you choose Cilium over GKE's built-in networking?
7. Why CloudNativePG over managed Postgres or a hand-rolled StatefulSet?
8. Why KEDA and scale-to-zero instead of just HPA?
9. How does Workload Identity work and why no service-account keys?
10. What's your security story — layer by layer?

### Terraform & GCP
11. How does Terraform state work, and how do you secure it?
12. What's the difference between `count` and `for_each`? (With the element-removal consequence.)
13. What is drift and how do you detect/remediate it?
14. `state rm` vs `state mv` vs `import` vs `taint` — when each?
15. How does a regional GKE cluster stay HA — and when doesn't it?
16. Taints/tolerations and node pools — design a production cluster's pools.
17. Workload Identity vs keys — the full chain.
18. How does the budget kill-switch work end to end? (Cloud Function + Pub/Sub + Compute API.)

### Kubernetes & Networking
19. Requests vs limits — and what does BestEffort mean in an OOM?
20. How does the scheduler decide where a pod lands?
21. PDBs — what do they protect and what don't they?
22. How does kube-proxy implement Services, and why is it a scale problem?
23. What is eBPF, and what does Cilium replace?
24. Where does WireGuard encrypt — packet path + your three-point proof?
25. Gateway API: the four objects and who owns them.
26. How does Envoy Gateway get config from YAML to running Envoy? (xDS)

### Databases
27. What does synchronous replication guarantee, and what does it cost?
28. Walk through a CNPG failover — what happens and why zero data loss?
29. How do backups work (barman + WAL + GCS + Workload Identity)?
30. Why did the in-place resize work, and what's the limit?

### Autoscaling & Reliability
31. How does HPA compute desired replicas? (The formula.)
32. Why can't HPA scale to zero and how does KEDA?
33. What's `activationListLength` vs `listLength`? (Hysteresis.)
34. What is a steady-state hypothesis, and how do you prove it? (Chaos.)
35. Voluntary vs involuntary disruption — and your force-kill failover test.

---

## Appendix A — Numbers to Memorize

| Fact | Number |
|---|---|
| Cluster | Regional GKE, 3 zones: us-central1-b / -c / -f |
| Quota headroom | 9/12 vCPU, 6/8 instances, 2/4 external IPs, ~250 GB SSD |
| Node pools | System 3× e2-small (1 vCPU/4 GB, CriticalAddonsOnly), App 3× e2-custom-2-8192 (2 vCPU/8 GB), autoscale 1–3, spot |
| Networking | VPC 10.0.0.0/16, pods 10.1.0.0/16, services 10.2.0.0/20, `ipv4NativeRoutingCIDR` 10.0.0.0/8 |
| GKE version | 1.35.5 (upgraded from 1.34 for image volumes) |
| Cilium | v1.16.19, WireGuard on UDP 51871, Hubble Relay + UI |
| Envoy Gateway | v1.8.3, proxy metrics on port 19001 |
| WAF | Coraza in-process dynamic module, OWASP CRS, `SecResponseBodyAccess Off` |
| WAF test | 5/5 attack classes blocked + ZAP passive scan |
| Postgres | CNPG 1.24, Postgres 16.4, 3 instances, `ANY 1` sync, 250m/1000m CPU, 1 Gi→8 Gi storage |
| pgbench | Scale 100 (~1.4 GB), 50 clients, 4 threads, 5 min → **396.6 tps, 0.000% failed, avg 124.7 ms** |
| Failover | Force-killed leader under load → **119,079 txn, 0.000% failed**; automatic failover also tested |
| Backups | barman → `gs://devops-portfolio-backups/postgres`, WAL gzip, 30-day retention, Workload Identity |
| KEDA | Redis scaler `inference_queue`, listLength 5, activation 0, min 0 / max 3, cooldown 60 s, poll 10 s |
| Ollama | llama3.2:3b Q4 ≈ 2 GB, 2–5 tok/s CPU, NUM_PARALLEL=1, KEEP_ALIVE 24 h, emptyDir 50 Gi |
| Kill-switch | Budget threshold ≥ 0.95, stops instances in -b/-c/-f, Pub/Sub-triggered gen2 Cloud Function |
| Cost | Full env, 2 weeks, **< $20** |
| SLIs (steady-state) | p99 < 500 ms, error < 1%, availability > 99.5%, lag < 100 ms, failover < 30 s, data loss = 0 |

## Appendix B — Gotcha Stories (interview gold — each is a symptom→diagnosis→fix→verification arc)

1. **"Encryption: WireGuard" but plaintext on the wire.** Symptom: `cilium encrypt status` says enabled; tcpdump on eth0 shows plaintext HTTP. Root cause: `ipv4NativeRoutingCIDR` only covered the node subnet; pod-CIDR routes never got WireGuard peers. Fix: `/8`. Verify: Point-3 capture + the enable/disable toggle test. Lesson: enabled ≠ working; verify at the packet.
2. **`kubectl apply` fails on the CNPG `poolers` CRD.** Symptom: apply error >256 KB annotation; controller crash-loop `no matches for kind "Pooler"`. Fix: `--server-side --force-conflicts` + verify all 6 CRDs. Lesson: SSA vs client-side apply; a dropped connection can skip a CRD.
3. **98% allocatable with quota free.** Symptom: pods Pending, quota says free. Root cause: GKE daemonsets consume ~0.5 vCPU/node; 500m request = half a node. Fix: e2-custom-2-8192 + 100m requests. Lesson: allocatable ≠ capacity.
4. **Ollama exit 137.** OOMKilled: 3B model ≈ 2 GB vs 4 GB node under pressure. Fix: 8 GB nodes, 4 Gi limit, NUM_PARALLEL=1. Lesson: memory is the CPU-inference constraint.
5. **Datadog agent broken on COS.** `mkdir /usr/src` failure on read-only `/usr`; and empty `$DD_API_KEY` deploys silently broken. Fix: `providers.gke.cos=true`; site must match account (`us5.datadoghq.com`).
6. **Envoy metrics dead on 19000.** EG v1.8 uses 19001; ServiceMonitor also needed `release: monitoring`/`component: proxy` selectors + literal `prometheus` datasource UID. Three separate silent failures — dashboard debugging.
7. **Cloudflare 521/502 through Full(strict).** Origin is plain HTTP; Full(strict) assumes TLS origin. Fix: Flexible. Lesson: proxy SSL modes are a 3-state machine, not a toggle.
8. **pgbench: "relation pgbench_branches does not exist".** Trailing DB arg dropped → ran against `postgres` DB. And scale-100 (~1.4 GB) exceeded 1 Gi → "No space left on device" → the resize demo became a prerequisite.
9. **Chaos Mesh CRD rejections.** `direction: both` needs `targets`; PodChaos `scheduler` rejected; StressChaos on `role: gpu` matched nothing (no GPUs). Each: read the CRD schema, not the docs example.
10. **`jsonpath='{.items[0].metadata.name}'` index-out-of-bounds.** Mid-promotion, no pod carries `cnpg.io/instanceRole=primary` → watch script race, not a cluster fault.
11. **Kill-switch deployed ACTIVE but never fired.** Budget alert lacked "Notify on Pub/Sub topic"; zones list was `-a/-b/-c` vs cluster `-b/-c/-f`; `--source`/`--entry-point` mismatches. Three independent silent failures.
12. **Cilium agent won't start on COS.** `/opt/cni/bin` read-only; fix `cni.binPath: /home/kubernetes/bin` (GKE convention).
13. **`node_count: 3` creates 9 nodes.** Regional pools multiply node_count by zones — the quota table is why you set 1.

## Appendix C — Questions to ASK the interviewer (come prepared)

1. "How is your team handling the ingress-nginx retirement — what's your migration path?"
2. "What's your SLO culture — are error budgets part of planning?"
3. "How do you handle chaos/GameDays — is there a regular practice?"
4. "What's your observability stack today, and what's the biggest gap?"
5. "How do you manage the balance between platform team ownership and app-team self-service?"
6. "What does on-call look like here — load, rotation, postmortem culture?"
7. "Where would this project's architecture surprise you, and what would you push back on?"

---

*End of question bank. Good luck — you know this project better than anyone you'll be interviewed by.*
