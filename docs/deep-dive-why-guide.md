# DevOps Portfolio: Deep-Dive WHY Guide

> A beginner-friendly explanation of how everything fits together — especially networking.

This guide explains **why** each step in the devops-portfolio project exists, how the pieces connect, and what you'd say in an interview or architecture review. Read this alongside the main [README](../README.md).

---

## Table of Contents

1. [The Big Picture: What You're Building](#1-the-big-picture-what-youre-building)
2. [How Traffic Flows End-to-End (Networking First)](#2-how-traffic-flows-end-to-end-networking-first)
3. [Phase 0: Foundation — Domain, Cloudflare, GCP Organization](#3-phase-0-foundation--domain-cloudflare-gcp-organization)
4. [Phase 1: Core Infrastructure & Security](#4-phase-1-core-infrastructure--security)
5. [Phase 2: Stateful Workloads & Observability](#5-phase-2-stateful-workloads--observability)
6. [Phase 3: AI Model Serving & Event-Driven Autoscaling](#6-phase-3-ai-model-serving--event-driven-autoscaling)
7. [Phase 4: Chaos Engineering & Resilience](#7-phase-4-chaos-engineering--resilience)
8. [How It All Fits Together](#8-how-it-all-fits-together)
9. [Interview Talking Points](#9-interview-talking-points)
10. [Appendix: IP Address Cheat Sheet](#10-appendix-ip-address-cheat-sheet)

---

## 1. The Big Picture: What You're Building

You're not building "an app on Kubernetes." You're building a **mini enterprise platform** that demonstrates four pillars senior engineers care about:

| Pillar | What you prove |
|--------|----------------|
| **Security** | WAF at the edge, private nodes, encrypted pod traffic, IAM |
| **Reliability** | HA database, multi-zone nodes, chaos-tested failover |
| **Observability** | Metrics, traces, logs — you can *see* failures and recovery |
| **Cost awareness** | Spot VMs, scale-to-zero, budget alerts |

Each phase adds a layer:

- **Phase 0** — Foundation (identity, DNS, billing)
- **Phase 1** — Network + cluster + edge security
- **Phase 2** — Data that survives failures
- **Phase 3** — Expensive GPU workloads that only run when needed
- **Phase 4** — Proof that the design actually works under stress

Most DevOps portfolios stop at deploying an app. This project proves you understand **Day 2 Operations** — the ongoing work of keeping production systems secure, observable, and cost-efficient.

---

## 2. How Traffic Flows End-to-End (Networking First)

Before diving into phases, understand the **full network path**. This is the story you'll tell most often in interviews.

```
Internet User
    │
    ▼
┌─────────────────────────────────────┐
│  Cloudflare (DNS + HTTPS proxy)     │  ← Layer 7 edge: DDoS, TLS, caching
│  boutique.yourdomain.dev            │
└─────────────────┬───────────────────┘
                  │ HTTPS (TLS terminated at Cloudflare)
                  ▼
┌─────────────────────────────────────┐
│  GCP Global HTTP(S) Load Balancer   │  ← Created by Ingress NGINX Service
│  (External IP from LoadBalancer Svc)│     type=LoadBalancer
└─────────────────┬───────────────────┘
                  │ Health checks from 130.211.0.0/22, 35.191.0.0/16
                  ▼
┌─────────────────────────────────────┐
│  Ingress NGINX + Coraza WAF         │  ← OWASP rules, rate limits
│  (pods in ingress-nginx namespace)  │
└─────────────────┬───────────────────┘
                  │ Routes by Host header to backend Service
                  ▼
┌─────────────────────────────────────┐
│  Kubernetes Service (ClusterIP)     │  ← Virtual IP inside cluster
│  e.g. frontend.boutique.svc         │
└─────────────────┬───────────────────┘
                  │ kube-proxy OR Cilium eBPF (this project: Cilium)
                  ▼
┌─────────────────────────────────────┐
│  Application Pod(s)                 │  ← e.g. Online Boutique frontend
│  IP from pod CIDR 10.1.0.0/16       │
└─────────────────┬───────────────────┘
                  │ May call other services (cart, checkout, etc.)
                  ▼
┌─────────────────────────────────────┐
│  Other pods (same or other NS)      │  ← Traffic encrypted via WireGuard
│  e.g. PostgreSQL in database NS     │     (Cilium), invisible to apps
└─────────────────────────────────────┘
```

### Three separate "networks" to keep straight

1. **Public internet path** — User → Cloudflare → GCP LB → Ingress → app  
   *Why Cloudflare?* Free DDoS protection, TLS, and you don't expose raw GCP IPs to the world without a shield.

2. **GCP VPC** — Your custom network (`10.0.0.0/16` subnet, nodes get internal IPs)  
   *Why custom VPC?* Control over IP ranges, NAT, firewall rules, and alignment with GKE's VPC-native model.

3. **Kubernetes overlay (pod/service CIDRs)** — Pods `10.1.0.0/16`, Services `10.2.0.0/20`  
   *Why secondary ranges?* GKE assigns each pod a real VPC-routable IP (VPC-native), which makes NetworkPolicy and Cilium work correctly — no double NAT confusion.

### Private nodes + Cloud NAT (critical concept)

Your Terraform sets:

```hcl
private_cluster_config {
  enable_private_nodes    = true   # Nodes have NO public IP
  enable_private_endpoint = false  # API server still reachable from your laptop
}
```

**Why private nodes?**  
If a node had a public IP, anything on the internet could theoretically reach it (subject to firewall). Private nodes only have internal IPs — they are not directly reachable from the internet. That's defense in depth.

**But then how do pods pull Docker images or call external APIs?**  
**Cloud NAT.** Outbound traffic from private nodes goes through a NAT gateway with a shared public IP. Inbound from the internet never hits nodes directly — only the Load Balancer → Ingress path does.

**Why not private endpoint for the API server?**  
`enable_private_endpoint = false` keeps the Kubernetes API reachable from your laptop via the public endpoint (authenticated). A fully private endpoint requires VPN or Cloud Shell — fine for production, harder for learning.

### DNS resolution inside the cluster

When a pod calls `redis.ai-inference.svc.cluster.local`:

1. Pod's `/etc/resolv.conf` points to CoreDNS (cluster DNS).
2. CoreDNS resolves the Service name to a **ClusterIP** (from the `10.2.0.0/20` range).
3. Cilium's eBPF datapath load-balances to one of the backing pod IPs (from `10.1.0.0/16`).
4. If WireGuard is enabled, packets are encrypted before leaving the source node.

This is **east-west traffic** — entirely inside your infrastructure, but still worth encrypting.

---

## 3. Phase 0: Foundation — Domain, Cloudflare, GCP Organization

Phase 0 isn't "DevOps fluff." It unlocks everything else.

### Step 0.1 — Free domain (GitHub Student Pack)

**What:** Get `yourname.dev` or similar from Namecheap, Name.com, or .TECH Domains via the GitHub Student Developer Pack.

**Why not skip it?**

- Cloudflare wants a domain you control.
- Google Cloud **Organization** requires proving you own a domain (`admin@yourdomain.dev`).
- A real hostname (`boutique.yourdomain.dev`) makes TLS, Ingress rules, and portfolio demos credible.

**Alternative rejected:** Using `nip.io` or raw IP — works for labs, looks unprofessional, breaks the Cloudflare Full (strict) SSL story.

### Step 0.2 — Cloudflare nameservers

**What:** Point your registrar's nameserver (NS) records to Cloudflare.

**Why Cloudflare over registrar DNS?**

- Free CDN, DDoS mitigation, and SSL modes.
- **Full (strict)** means: browser ↔ Cloudflare encrypted, Cloudflare ↔ origin encrypted with a valid cert.
- **Always Use HTTPS** — no accidental HTTP leaks.
- **Brotli compression** — smaller payloads, faster page loads.

**What happens under the hood:**  
When you add `boutique.yourdomain.dev` → Ingress external IP, Cloudflare becomes the **authoritative resolver** for your zone. User queries DNS → gets Cloudflare anycast IP → Cloudflare proxies to your GCP LB IP.

**SSL modes explained:**

| Mode | Browser → Cloudflare | Cloudflare → Origin | Use case |
|------|---------------------|---------------------|----------|
| Flexible | HTTPS | HTTP | ❌ Insecure — avoid |
| Full | HTTPS | HTTPS (any cert) | Okay for self-signed origin |
| Full (strict) | HTTPS | HTTPS (valid cert) | ✅ Production — use this |

### Step 0.3 — Google Cloud Organization (Cloud Identity)

**What:** Sign up at Cloud Identity Free with `admin@yourdomain.dev`, verify domain via TXT record in Cloudflare.

**Why not a personal @gmail.com project?**  
Enterprises use **Organizations → Folders → Projects**. You practice:

- IAM at org/folder/project level
- Service accounts with least privilege
- Workload Identity Federation (later)
- Destroying whole projects without touching your personal account

**Why it matters for networking:** Organization is also where org policies live (e.g. `constraints/compute.restrictVpcPeering`) — real companies use these to prevent accidental network exposure.

**Hierarchy you'll create:**

```
Organization (yourdomain.dev)
└── Folder: Infrastructure Engineering
    └── Project: devops-portfolio-prod
        └── Resources: VPC, GKE, buckets, etc.
```

### Step 0.4 — Billing & $300 credits

**Why credit card if it's free?**  
Google needs identity verification. Credits apply first; you are not charged until credits expire (90 days).

### Step 0.5 — Budget alerts at $250 (not $300)

**Why $250?**  
Credits don't stop spend automatically. Alerts at 50%, 75%, 90%, and 100% give you time to run `emergency-cleanup.sh` before you're surprised. This is **FinOps hygiene** — senior engineers set budgets *before* provisioning.

### Step 0.6 — GCP project, folder, APIs, Terraform service account

**Folder `Infrastructure Engineering`:** Logical grouping — in a real company you'd have `prod`, `staging`, `sandbox` folders.

**APIs enabled:**

| API | Why |
|-----|-----|
| `compute.googleapis.com` | VPC, subnets, NAT, firewall, load balancers |
| `container.googleapis.com` | GKE clusters and node pools |
| `cloudresourcemanager.googleapis.com` | Folders, projects, org resources |
| `iam.googleapis.com` | Service accounts, roles, policies |
| `monitoring.googleapis.com` | GKE integrated monitoring |
| `logging.googleapis.com` | GKE integrated logging |

**Terraform service account:**  
IaC runs as a robot identity, not your user account. Roles like `container.admin`, `compute.admin` are broad for a portfolio; production would use custom roles with minimal permissions.

**Why no JSON key — impersonation instead (see README §0.4)?**  
Terraform needs credentials, but a key file is a standing leak risk (a leaked key = full control of your infrastructure). This project authenticates via **service account impersonation**: `gcloud auth application-default login --impersonate-service-account=terraform-sa@...` — Terraform mints short-lived `terraform-sa` tokens on the fly, and nothing long-lived ever touches disk.

**Org policy note:** Some orgs enforce `constraints/iam.managed.disableServiceAccountKeyCreation`, so key creation fails anyway. Impersonation sidesteps the problem entirely (no key to create). Production extends the same no-key idea with **Workload Identity Federation** from GitHub Actions.

---

## 4. Phase 1: Core Infrastructure & Security

This is the densest networking phase. Everything else builds on the network you create here.

### 4.1 — Terraform: VPC, subnet, NAT, GKE

#### Custom VPC (`auto_create_subnetworks = false`)

**Why custom?**  
Auto-mode VPCs create subnets per region with fixed `/20` slices you don't control. Custom VPC lets you define:

- Node subnet: `10.0.0.0/16`
- Pod secondary range: `10.1.0.0/16`
- Service secondary range: `10.2.0.0/20`

**Why separate CIDRs?**  
GKE **VPC-native (alias IP)** assigns each pod an IP from the `pods` range that's routable inside the VPC. Cilium, NetworkPolicy, and Hubble all reason about real IPs. Older overlay networks (Flannel without VPC-native) hid pod IPs from the VPC — harder to debug and worse performance.

**Why `routing_mode = "REGIONAL"`?**  
Routes are learned regionally, which is the standard for regional GKE clusters spanning multiple zones.

#### `private_ip_google_access = true`

Nodes can reach Google APIs (`storage.googleapis.com`, Artifact Registry, etc.) over Google's **private network** without going through NAT. Cheaper, faster, more secure than routing Google API traffic through the public internet.

#### Cloud NAT

**Purpose:** Egress only for private nodes.

**Flow when a pod pulls an image:**

```
Pod (10.1.x.x) → Node (10.0.x.x) → Cloud NAT → Public IP → Docker Hub
```

**Why `source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"`?**  
NAT applies to both primary subnet (nodes) and secondary ranges (pods). Without this, pod egress might fail.

**Why `AUTO_ONLY` for NAT IPs?**  
Google automatically allocates external IPs for NAT. Fine for a portfolio; production might use reserved static IPs for allowlisting.

#### Firewall rule for health checks

```hcl
source_ranges = [
  "130.211.0.0/22",
  "35.191.0.0/16",
  "209.85.152.0/22",
  "209.85.204.0/22",
]
```

GCP load balancers probe your Ingress on ports 80/443/8080 from these IP ranges. **Without this rule**, health checks fail, the LB marks backends unhealthy, and your site returns 502 even if pods are running fine.

**Why this matters in interviews:** Health check failures are a common "everything looks fine in kubectl but URL is 502" bug.

#### Regional GKE cluster

**Regional vs zonal:**

| | Zonal | Regional |
|---|-------|----------|
| Control plane | Single zone | Replicated across 3 zones |
| Cost | Lower | ~15% higher |
| Availability | Zone outage = cluster down | Survives single zone failure |
| Node distribution | One zone unless you add pools | Spread across zones by default |

**Why regional for this project:** You're demonstrating HA — regional is the right choice.

#### `remove_default_node_pool = true`

GKE requires an initial pool to create the cluster; you immediately replace it with tuned pools (system, app, GPU). The default pool would have wrong size, wrong labels, and no taints.

#### `networking_mode = "VPC_NATIVE"`

Required for alias IP (pod IPs from secondary range). This is the modern default and prerequisite for Cilium's advanced features.

#### Node pools strategy

| Pool | Machine | Spot? | Purpose |
|------|---------|-------|---------|
| **system** | e2-standard-4 | Yes | Cilium, CoreDNS, operators — tainted `CriticalAddonsOnly` |
| **application** | e2-standard-8 | Yes | Boutique, inference API — autoscale 2–8 |
| **gpu** | g2-standard-8 + L4 | Yes | Ollama — autoscale 0–4 |

**Why spot VMs?** 60–80% discount. Tradeoff: Google can reclaim the VM with ~30 seconds notice. For stateless app pods, Kubernetes reschedules elsewhere. **Caution:** Using spot for the system pool is aggressive — in true production, system/CNI nodes are usually on-demand for stability.

**Why taint on system pool?**

```hcl
taint {
  key    = "CriticalAddonsOnly"
  value  = "true"
  effect = "NO_SCHEDULE"
}
```

Prevents random app pods from consuming resources needed by Cilium/DNS. Only pods with matching tolerations schedule there.

**Why separate pools at all?**  
Different workload profiles need different machine types, scaling policies, and isolation. GPU nodes are expensive — you don't want a frontend pod accidentally scheduling there.

#### Workload Identity

```hcl
workload_pool = "${var.project_id}.svc.id.goog"
```

**Problem it solves:** Pods shouldn't use downloaded JSON keys to call GCS (backups). Workload Identity maps `K8s ServiceAccount` → `GCP ServiceAccount`.

**How it works:**

1. Create GCP SA with `storage.objectAdmin` on backup bucket.
2. Annotate K8s SA: `iam.gke.io/gcp-service-account: cnpg-backup@project.iam.gserviceaccount.com`
3. Bind: `roles/iam.workloadIdentityUser` on GCP SA for the K8s SA member.
4. Pod using that K8s SA gets tokens from the metadata server — no key file.

CloudNativePG backup to `gs://devops-portfolio-backups` uses this pattern.

#### Binary Authorization

Blocks container images that aren't attested/signed per policy. Portfolio sets enforce mode — demonstrates security posture. You'll need to allow your actual images or signing breaks deploys.

#### Shielded nodes

VMs with secure boot and integrity monitoring — prevents rootkits at the hypervisor level. Enterprise security baseline.

#### Network policy disabled at GKE level

```hcl
network_policy {
  enabled  = false
  provider = "PROVIDER_UNSPECIFIED"
}
```

**Why disabled?** Cilium enforces NetworkPolicy natively via eBPF. Enabling GKE's Calico-based provider would be redundant and potentially conflicting.

---

### 4.2 — Cilium CNI (the heart of in-cluster networking)

**What is a CNI?**  
When a pod starts, something must assign it an IP, configure routes, and enforce network rules. The CNI (Container Network Interface) plugin handles this. Default GKE can use Dataplane V2 — **this project explicitly installs Cilium** for learning and advanced features.

#### Why Cilium over default kube-proxy?

| kube-proxy (iptables/ipvs) | Cilium (eBPF) |
|----------------------------|---------------|
| Service rules in iptables — O(n) as services grow | eBPF maps in kernel — O(1) lookups |
| NetworkPolicy via separate add-on | Native NetworkPolicy + CiliumNetworkPolicy |
| No built-in encryption | WireGuard transparent encryption |
| Limited observability | Hubble — flow-level visibility |
| Userspace proxy for some features | Kernel-level processing |

**eBPF in plain English:** Programs run *inside the Linux kernel* on events (packet arrives, syscall). Cilium uses them to route, encrypt, and filter without copying every packet to userspace. Result: lower latency, higher throughput, better scalability.

#### Installation flags explained

```bash
cilium install \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set kubeProxyReplacement=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

| Flag | Why |
|------|-----|
| `encryption.enabled=true` | Turn on pod-to-pod encryption |
| `encryption.type=wireguard` | Use WireGuard (modern, fast) vs IPsec |
| `kubeProxyReplacement=true` | Cilium handles Service load balancing instead of kube-proxy |
| `hubble.relay.enabled=true` | Aggregate flows from all nodes for the UI |
| `hubble.ui.enabled=true` | Web UI for network observability |

#### WireGuard encryption

**What it does:** Every pod-to-pod packet is encrypted on the wire between nodes. Applications speak plain HTTP to each other; Cilium encrypts at the node boundary via the `cilium_wg0` interface.

**Why not just TLS everywhere in apps?**

- Every microservice would need certs, rotation, mTLS libraries.
- WireGuard is **transparent** — zero app changes.
- Defense in depth: even if an attacker is inside the VPC, pod traffic is encrypted.

**How to prove it:**

```bash
# Deploy test pods in different namespaces
kubectl create ns test-a && kubectl create ns test-b
kubectl run netshoot-a -n test-a --image=nicolaka/netshoot -- sleep 3600
kubectl run netshoot-b -n test-b --image=nicolaka/netshoot -- sleep 3600

# On a node: tcpdump on WireGuard interface shows encrypted packets,
# not plaintext HTTP, even when pods send unencrypted HTTP
sudo tcpdump -i cilium_wg0 -nn port 80
```

#### Hubble

UI and CLI for **who talked to whom**, dropped flows, DNS queries. When debugging "checkout can't reach cart," Hubble beats `kubectl logs`.

```bash
cilium hubble observe --namespace boutique
```

#### Cilium connectivity test

```bash
cilium connectivity test
```

Runs a suite of pod-to-pod, network policy, and DNS checks — validates the CNI before you deploy apps. Fail here before wasting time on app debugging.

---

### 4.3 — Ingress NGINX + Coraza WAF

#### Why Ingress instead of LoadBalancer per service?

Each `Service type=LoadBalancer` gets its own GCP external IP (~$18/month each plus forwarding rules). **Ingress** is one entry point with host/path routing:

- `boutique.yourdomain.dev` → frontend
- `ai.yourdomain.dev` → inference-api

One IP, many backends — cost-efficient and manageable.

#### LoadBalancer Service → GCP LB

When you `helm install ingress-nginx` with `controller.service.type=LoadBalancer`, GKE provisions a **Google Cloud External TCP/UDP Load Balancer**. Traffic flow:

```
Internet → GCP LB (external IP) → NodePort on worker nodes → Ingress controller pod
```

The annotation `cloud.google.com/load-balancer-type=External` ensures a public-facing LB (vs internal).

#### Coraza / ModSecurity + OWASP CRS

**WAF = Web Application Firewall.** Inspects HTTP **content** (query strings, bodies, headers) for attack patterns.

**Why at Ingress, not in each app?**

- Central policy — one place to update OWASP rules.
- Apps stay simple — no SQLi regex in every microservice.
- Blocks attacks **before** they hit vulnerable app code.

**OWASP Core Rule Set (CRS)** covers:

- SQL Injection (SQLi)
- Cross-Site Scripting (XSS)
- Local/Remote File Inclusion
- Command Injection
- Scanner/bot detection
- 50+ other attack categories

#### Metrics on Ingress

Prometheus scrapes port 10254 — request rate, latency, 403 count. Feeds Grafana WAF dashboard in Phase 2.

---

### 4.4 — Sample app (Online Boutique)

**Why Google's microservices demo?**  
11 services with gRPC/HTTP between them — realistic **east-west traffic** inside the cluster. When WireGuard is enabled, all those inter-service calls are encrypted transparently.

**Ingress manifest:**

```yaml
host: boutique.yourdomain.dev
```

Ingress controller matches the `Host` header to route. DNS in Cloudflare must point to the LB IP.

**Namespace isolation:** Boutique runs in its own namespace — NetworkPolicy (if applied) can restrict which namespaces talk to which.

---

### 4.5 — OWASP ZAP scan

**Why?** Portfolio claim "WAF blocks attacks" needs evidence. ZAP is industry-standard.

```bash
docker run --rm zaproxy/zap-stable zap-baseline.py \
  -t https://boutique.yourdomain.dev \
  -r zap_report.html
```

Verify blocks in Ingress logs:

```bash
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx | grep ModSecurity
# Expected: 403 responses for blocked attacks
```

---

## 5. Phase 2: Stateful Workloads & Observability

Phase 1 asked: "Can we secure and route traffic?" Phase 2 asks: "Can data survive failures, and can we *see* it?"

### 5.1 — CloudNativePG (HA PostgreSQL)

#### Why an operator?

Running PostgreSQL on Kubernetes naively (single Deployment + PVC) loses HA, backups, and failover. **Operators** encode domain expertise in a controller — watches `Cluster` CRD, creates StatefulSets, handles failover, manages backups.

The operator pattern is central to Kubernetes at scale: CloudNativePG, Cilium, KEDA, Chaos Mesh — all operators.

#### `instances: 3`

One **primary** (accepts writes), two **replicas** (reads + standby). If primary dies, operator promotes the healthiest replica.

#### Synchronous replication

```yaml
synchronous_commit: "on"
synchronous_standby_names: "ANY 1 (ha-postgres-2,ha-postgres-3)"
```

**Why synchronous vs asynchronous?**

| | Async | Sync |
|---|-------|------|
| Primary acknowledges | Before replica confirms | After ≥1 replica confirms |
| Speed | Faster | Slightly slower |
| Data loss on primary crash | Possible | Zero for committed writes |
| Use case | Analytics, logs | Orders, payments, critical data |

**Tradeoff:** Sync adds latency (especially cross-zone). You choose consistency over speed — correct for order data.

#### Pod anti-affinity across zones

```yaml
topologyKey: "topology.kubernetes.io/zone"
```

**Why?** If all 3 Postgres pods land in `us-central1-a`, one zone outage kills the entire database. Spreading across `a`, `b`, `c` survives single-zone failure — pairs with **regional GKE**.

**Networking angle:** Replication traffic is pod-to-pod across zones over the VPC, encrypted by Cilium WireGuard. Replication lag metrics in Grafana show impact when chaos adds 500ms latency (Phase 4).

#### Backups to GCS

```yaml
backup:
  barmanObjectStore:
    destinationPath: "gs://devops-portfolio-backups/postgres"
```

**Why GCS?** Durable (11 nines), cheap, integrated with GCP IAM via Workload Identity. Barman handles continuous WAL archiving + periodic base backups.

**RPO/RTO concepts:**

- **RPO (Recovery Point Objective):** How much data you can lose — sync repl + WAL archiving → near-zero RPO.
- **RTO (Recovery Time Objective):** How long to restore service — operator failover target < 30 seconds.

#### Resource limits

```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "1000m"
  limits:
    memory: "2Gi"
    cpu: "2000m"
```

**Why requests and limits?** Requests = guaranteed resources for scheduling. Limits = cap to prevent one pod starving others. PostgreSQL is memory-sensitive — OOM kill corrupts data.

---

### 5.2 — Load test + chaos script

**pgbench** — industry-standard PostgreSQL benchmark.

```bash
pgbench -i -s 100    # Initialize scale factor 100 (~1.6 GB)
pgbench -c 50 -j 4 -T 300   # 50 clients, 4 threads, 5 minutes
```

Running pgbench **during** `kubectl delete pod` on the primary proves failover doesn't lose committed writes.

**The chaos script (`scripts/db-chaos-test.sh`):**

1. Start continuous load in background.
2. Wait 30 seconds for steady state.
3. Force-delete the leader pod.
4. Monitor for new leader every 2 seconds.
5. Wait for load test to finish.

**Success criteria:** Zero failed transactions = sync replication + operator failover worked.

---

### 5.3 — Observability stack

#### Prometheus + Grafana (kube-prometheus-stack)

**Why Prometheus?** Pull-based metrics — scrapes `/metrics` endpoints from pods, Ingress, CNPG PodMonitor, DCGM later. Time-series database optimized for operational metrics.

**Why Grafana?** Visualization layer. CNPG exports replication lag, TPS, connections — screenshot failover dips for portfolio.

**Critical dashboards:**

1. **PostgreSQL Overview** — replication lag, TPS, connections, cache hit ratio, WAL rate
2. **Kubernetes Cluster Health** — node CPU/memory/disk, pod restarts, network I/O per namespace
3. **WAF/Ingress** — request rate by status, 403 count (blocked attacks), latency percentiles

**PodMonitor selector config:**

```yaml
prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
```

Default Helm values restrict Prometheus to monitors in its own release. Setting to `false` lets it discover CNPG PodMonitors in the `database` namespace.

#### Datadog

**Why both Prometheus and Datadog?**

- **Prometheus:** Open source, KEDA queries it for GPU metrics, no vendor lock-in.
- **Datadog:** What many enterprises use — APM traces, log correlation, infra host maps. GitHub Student Pack gives Pro tier.

**What Datadog adds beyond Grafana:**

- **APM traces** — follow a request across all 11 Boutique microservices
- **Log correlation** — click a trace, see related logs
- **Infrastructure map** — visual service dependency graph
- **Alerting** — PagerDuty/Slack integration

**Networking:** Datadog agents run as DaemonSet — one per node, collect network metrics and traces. Cluster Agent aggregates Kubernetes metadata.

---

### 5.4 — Failover validation

```bash
# Terminal 1: continuous writes
while true; do psql -c "INSERT INTO ..."; sleep 1; done > write_log.txt &

# Terminal 2: kill leader
kubectl delete pod $LEADER_POD

# After recovery:
grep -c "ERROR\|FATAL" write_log.txt
# Expected: 0 or very few transient errors (auto-retried)
```

**Portfolio documentation:** Capture screenshots showing:

- Grafana dashboard during failover (TPS drops briefly, recovers)
- Datadog traces showing the failover event
- Log output with zero permanent errors
- New leader pod logs showing promotion

---

## 6. Phase 3: AI Model Serving & Event-Driven Autoscaling

Phase 3 adds **GPU scheduling**, **queues**, and **scale-to-zero** — the cost optimization story.

### 6.1 — NVIDIA GPU Operator + DCGM Exporter

**Problem:** Kubernetes doesn't natively understand GPUs. A node might have an L4 GPU physically attached, but the scheduler sees only CPU and memory unless a **device plugin** advertises `nvidia.com/gpu`.

**GPU Operator installs:**

- NVIDIA device plugin (registers GPUs with kubelet)
- DCGM (Data Center GPU Manager) — NVIDIA's GPU monitoring
- DCGM Exporter — exposes `DCGM_FI_DEV_GPU_UTIL` to Prometheus

**Why `driver.enabled=false` on GKE?**  
GKE pre-installs NVIDIA drivers on GPU nodes. Installing again would conflict.

**Why metrics matter for scaling:** CPU-based HPA is useless for LLM inference — GPU can be 100% utilized while CPU sits idle. You scale on **GPU utilization** and **queue depth**.

---

### 6.2 — Ollama on GPU nodes

```yaml
nodeSelector:
  cloud.google.com/gke-accelerator: "nvidia-l4"
tolerations:
- key: "nvidia.com/gpu"
  operator: "Exists"
  effect: "NoSchedule"
```

**nodeSelector:** Only schedule on GPU pool nodes.  
**tolerations:** GPU nodes often have taints so normal pods don't accidentally land on expensive GPU machines.

**Resource requests:**

```yaml
limits:
  nvidia.com/gpu: 1
  memory: "24Gi"
  cpu: "6"
```

Reserving 1 GPU tells the scheduler exactly one GPU pod per L4. Memory/CPU limits prevent OOM on the node.

**OLLAMA_KEEP_ALIVE=24h:** Keeps model loaded in VRAM — avoids **cold start** (reload multi-GB model weights) on every request. Tradeoff: uses GPU memory even when idle.

**OLLAMA_NUM_PARALLEL=4:** Handle 4 concurrent inference requests per pod.

**ClusterIP Service:** Inference is internal only until Ingress in 6.7 — not exposed to internet directly.

**East-west networking:** `inference-api` → `ollama:11434` is ClusterIP routing via Cilium, encrypted by WireGuard.

---

### 6.3 — Redis queue + inference API

**Why a queue?**  
LLM inference is slow (seconds to minutes). Synchronous HTTP would timeout and lose work under burst load. A queue decouples **accepting** requests from **processing** them.

**Flow:**

1. Client `POST /infer` → API pushes JSON to Redis list `inference_queue`, returns `task_id`.
2. Worker (Ollama or sidecar) pops from queue, runs inference, stores result in Redis key `result:{task_id}`.
3. Client polls `GET /result/{task_id}` until complete.

**Why Redis over Kafka/RabbitMQ for this portfolio?**  
Simpler, fewer moving parts, sufficient for demo scale. Production at high volume would use Kafka for durability and replay.

**DNS inside cluster:**

```
redis.ai-inference.svc.cluster.local
│      │            │   │         │
│      │            │   │         └── cluster domain suffix
│      │            │   └── "service" resource type
│      │            └── namespace
│      └── service name
```

CoreDNS resolves this to the Redis ClusterIP.

---

### 6.4 — KEDA (event-driven autoscaling)

**Why not standard HPA?**  
HPA scales on CPU/memory/custom metrics API. **KEDA** scales on **external events**: Redis list length, Prometheus query, Kafka lag, cloud queue depth, etc. It can also scale **to zero** — HPA cannot go below 1 replica.

**Installation:** KEDA operator watches `ScaledObject` CRDs and creates/manages HPAs behind the scenes.

**ScaledObject with two triggers:**

```yaml
triggers:
- type: prometheus
  metadata:
    query: avg(DCGM_FI_DEV_GPU_UTIL{exported_pod=~"ollama.*"})
    threshold: "70"
- type: redis
  metadata:
    listName: inference_queue
    listLength: "10"
```

| Trigger | Scale when | Why |
|---------|-----------|-----|
| GPU util > 70% | GPU saturated | Add replica to share inference load |
| Queue length > 10 | Backlog building | Requests arriving faster than processing |

**cooldownPeriod: 300** — Wait 5 minutes before scale-down to avoid flapping when traffic oscillates.

**minReplicaCount / maxReplicaCount:** Bound cost. Setting `minReplicaCount: 0` enables **scale to zero** — no GPU pods when idle, and cluster autoscaler can remove GPU nodes entirely.

**Cluster autoscaler interaction:**

```
KEDA increases pod count
  → Pending pods (no GPU node capacity)
    → Cluster Autoscaler adds GPU node
      → GPU Operator registers nvidia.com/gpu
        → Pod schedules and runs
```

Reverse on scale-down: pods terminate → node empty → autoscaler removes node → $0 GPU cost.

---

### 6.5 — GPU load test

```bash
# Submit 100 inference requests concurrently
for i in $(seq 1 100); do
  curl -X POST http://inference-api:8080/infer -d '{"prompt":"..."}' &
done
```

**Watch:**

```bash
kubectl get hpa -n ai-inference -w
kubectl get pods -n ai-inference -w
```

**Success criteria:**

- Queue depth exceeds 10 → KEDA triggers scale-up
- New Ollama pods spin up on GPU nodes (autoscaler adds nodes if needed)
- GPU utilization stays manageable across replicas
- Queue drains → after cooldown, replicas scale down
- Empty queue + cooldown → scale to zero, GPU nodes removed

---

### 6.6 — AI Ingress with WAF + rate limit

```yaml
nginx.ingress.kubernetes.io/limit-rps: "10"
nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
nginx.ingress.kubernetes.io/proxy-body-size: "10m"
```

| Annotation | Why |
|------------|-----|
| `limit-rps: "10"` | LLM endpoints are expensive — prevent abuse/DDoS |
| `proxy-read-timeout: "300"` | Generation takes minutes — default 60s timeout kills responses |
| `proxy-body-size: "10m"` | Allow larger prompts |

**Public path:** User → Cloudflare → GCP LB → Ingress (WAF + rate limit) → inference-api → Redis/Ollama.

---

## 7. Phase 4: Chaos Engineering & Resilience

**Principle (Netflix Chaos Monkey):** Break things on purpose in controlled ways to verify resilience **before** real incidents.

"If you haven't tested failure modes, you don't have a reliable system — you have an untested one."

### 7.1 — Chaos Mesh

CRD-based experiments (`PodChaos`, `NetworkChaos`, `StressChaos`) + web dashboard. Runs privileged daemons on nodes to inject faults at the kernel/network level.

```bash
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --set chaosDaemon.runtime=containerd \
  --set dashboard.create=true
```

---

### 7.2 — Steady-state hypothesis

Define **normal** before chaos:

```yaml
steady_state:
  boutique_app:
    p99_latency: "< 500ms"
    error_rate: "< 1%"
    availability: "> 99.5%"
  postgres:
    replication_lag: "< 100ms"
    failover_time: "< 30s"
    data_loss: "0"
  ai_inference:
    queue_processing_rate: "> 5 req/s"
    gpu_utilization: "< 85%"
    cold_start_time: "< 60s"
```

**Why?** Chaos without measurement is just breaking things. You compare metrics before, during, and after to prove the system recovers.

---

### 7.3 — Experiment 1: Pod kill (50% frontend)

```yaml
action: pod-kill
mode: fixed-percent
value: "50"
selector:
  namespaces: [boutique]
  labelSelectors:
    app: frontend
duration: "60s"
```

**Tests:** Deployments recreate pods, Service endpoints update, Ingress health checks pass, HPA may scale up.

**Observe:**

```bash
watch "kubectl get pods -n boutique && curl -s -o /dev/null -w '%{http_code}' https://boutique.yourdomain.dev"
```

**Expected:** HTTP 200 throughout (maybe brief blips). Datadog shows retry spikes. Kubernetes self-heals.

---

### 7.4 — Experiment 2: Network delay on database (500ms)

```yaml
action: delay
delay:
  latency: "500ms"
  jitter: "100ms"
selector:
  namespaces: [database]
  labelSelectors:
    cnpg.io/cluster: ha-postgres
direction: both
```

**Tests:** Sync replication under latency, app connection pool behavior, Grafana replication lag.

**Why both directions:** Simulates congested network between zones — realistic for cross-AZ traffic.

**Expected:** Application slows but stays correct. Replication lag rises during experiment, catches up within seconds after it ends.

**Deep networking point:** Chaos Mesh injects delay via Linux `tc` (traffic control) or eBPF. Packets still route through Cilium; WireGuard encryption still applies on top.

---

### 7.5 — Experiment 3: CPU stress on GPU node

```yaml
action: stress-cpu
stressors:
  cpu:
    workers: 6
    load: 90
selector:
  labelSelectors:
    role: gpu
```

**Tests:** Validates you're scaling on the **right metric**. CPU stress ≠ GPU stress.

**Expected:** DCGM GPU utilization unchanged. API gateway may throttle. KEDA may scale API pods to other nodes. After experiment, metrics return to baseline.

---

### 7.6 — Experiment 4: Node drain

Simulates node maintenance or spot VM preemption.

```bash
kubectl cordon $NODE    # No new pods scheduled here
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
```

**Tests:** PodDisruptionBudgets, anti-affinity, regional spread, WAL replay if Postgres replica was on that node.

**Expected:** Pods reschedule to other nodes. Database replica (if affected) catches up from WAL. Application traffic shifts seamlessly.

**Restore:**

```bash
kubectl uncordon $NODE
```

---

### 7.7 — WAF under chaos

Run OWASP ZAP full scan while pods are being killed — security controls should hold even when the application is degraded. A WAF that only works when the app is healthy isn't real protection.

---

### 7.8 — Portfolio documentation per experiment

For each chaos experiment, document:

1. Steady-state metrics **before**
2. Experiment definition (YAML + description)
3. Observed behavior **during** (Grafana/Datadog screenshots, log excerpts, HTTP timeline)
4. Recovery time and data integrity verification
5. Lessons learned and architectural improvements

---

## 8. How It All Fits Together

### Layer model (bottom to top)

```
┌────────────────────────────────────────────────────────────┐
│  Phase 4: Chaos — validates everything below               │
├────────────────────────────────────────────────────────────┤
│  Phase 3: AI + KEDA — event scaling on GPU pool            │
├────────────────────────────────────────────────────────────┤
│  Phase 2: PostgreSQL + Prometheus/Datadog — state + sight  │
├────────────────────────────────────────────────────────────┤
│  Phase 1: Cilium + Ingress WAF + GKE — network + edge      │
├────────────────────────────────────────────────────────────┤
│  Phase 0: Domain, Cloudflare, Org, billing — identity/DNS  │
└────────────────────────────────────────────────────────────┘
```

### Identity & trust chain

1. **Human** → `gcloud auth login` → GCP IAM user
2. **Terraform** → service account key → creates VPC, GKE
3. **Nodes** → private, no SSH from internet
4. **Pods** → Workload Identity → GCS backups (no JSON keys)
5. **Pod-to-pod** → WireGuard keys managed by Cilium (transparent)
6. **Users to app** → Cloudflare TLS → Ingress → WAF inspects HTTP

### Data flow for a boutique purchase (end-to-end example)

1. Browser resolves `boutique.yourdomain.dev` via Cloudflare DNS.
2. HTTPS to Cloudflare edge; Cloudflare forwards to GCP LB IP.
3. LB health-checks Ingress nodes, forwards to Ingress controller pod.
4. Coraza WAF inspects request; malicious patterns get 403.
5. Clean request passes to `frontend` Service ClusterIP.
6. Cilium eBPF load-balances to a frontend pod IP (`10.1.x.x`).
7. Frontend calls `checkoutservice` — east-west, WireGuard encrypted.
8. Checkout calls `cartservice`, `paymentservice`, etc. — all encrypted.
9. Eventually data persists to PostgreSQL via `ha-postgres-rw.database.svc`.
10. Sync replication ensures the write exists on at least one replica before acknowledgment.

### Cost flow

| Technique | Savings | Applied to |
|-----------|---------|------------|
| Spot VMs | 60–80% | App, GPU, system pools |
| Scale-to-zero (KEDA) | ~100% when idle | AI inference |
| GPU pool min=0 | No GPU charges idle | L4 nodes |
| e2 machine family | 30–50% vs n2 | System/monitoring |
| Budget alerts | Prevents surprise bills | All resources |

### Cleanup & project isolation

Because you use a GCP Organization, you can create per-phase projects and delete them entirely:

```bash
gcloud projects delete devops-phase1-infra
```

This prevents orphaned load balancers, disks, and IPs from silently consuming credits.

---

## 9. Interview Talking Points

### "Walk me through your architecture."

Start with the **user path** (Section 2), then **east-west security** (Cilium WireGuard), then **data** (CNPG sync repl), then **operational proof** (chaos + Grafana screenshots). Total: 3–5 minutes.

### "Why private GKE nodes?"

Nodes aren't on the public internet. Inbound traffic only through LB → Ingress. Outbound via NAT for image pulls and external APIs. Reduces attack surface — an attacker can't scan node IPs directly.

### "Why Cilium instead of a service mesh like Istio?"

For this project: kernel-level performance via eBPF, WireGuard encryption without sidecar proxies, Hubble for L3/L4 flow visibility. Istio adds L7 mTLS, traffic splitting, and retries — heavier operational overhead. Extension C in the README adds SPIFFE/SPIRE for identity-based mTLS if you need per-service authorization at L7.

### "How do you know the WAF works?"

OWASP ZAP baseline + full scan, manual curl tests with SQLi/XSS payloads expecting 403, ModSecurity logs correlated with Prometheus 403 rate metric.

### "How do you know Postgres HA works?"

pgbench during forced leader deletion, `synchronous_commit=on`, zero ERROR in continuous write log, Grafana shows TPS dip < 30s, CNPG operator logs show promotion event.

### "How does AI autoscaling save money?"

KEDA scales on queue depth + GPU metrics (not CPU). Cluster autoscaler scales GPU node pool 0–N. Spot GPUs for 50–70% discount. Scale-to-zero when queue empty. `OLLAMA_KEEP_ALIVE` trades memory for latency — explain both sides.

### "What would you do differently for real production?"

- On-demand (not spot) nodes for system pool and database
- Private GKE endpoint with VPN/bastion access
- Workload Identity Federation instead of SA keys for Terraform CI
- PodDisruptionBudgets on all critical workloads
- Separate projects/environments with promotion pipeline (GitOps)
- Signed images with Binary Authorization attestation
- Multi-region DR with cross-region GCS replication

### Common mistakes beginners make (shows you understand ops)

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Missing health check firewall rule | 502 from LB | Add GCP probe IP ranges to firewall |
| DNS not pointing to LB IP | Cloudflare 522/525 | Update A record in Cloudflare |
| SSL mode "Flexible" | Origin traffic unencrypted | Set Full (strict) |
| Pod CIDR overlaps node CIDR | Scheduling failures | Use separate non-overlapping ranges |
| No NAT on private cluster | ImagePullBackOff | Enable Cloud NAT |
| Forgetting budget alerts | Surprise bill | Set alerts at 50/75/90% |

---

## 10. Appendix: IP Address Cheat Sheet

| Range | Purpose |
|-------|---------|
| `10.0.0.0/16` | Node (primary subnet) IPs |
| `10.1.0.0/16` | Pod IPs (VPC-native secondary range) |
| `10.2.0.0/20` | Kubernetes Service ClusterIPs |
| `172.16.0.0/28` | GKE control plane (private cluster master CIDR) |
| `130.211.0.0/22` | GCP LB health probe source (global) |
| `35.191.0.0/16` | GCP LB health probe source (regional) |
| `209.85.152.0/22` | GCP health check source |
| `209.85.204.0/22` | GCP health check source |

### Kubernetes DNS names

| Pattern | Example | Resolves to |
|---------|---------|-------------|
| `<service>` | `redis` | ClusterIP (same namespace) |
| `<service>.<namespace>` | `redis.ai-inference` | ClusterIP (cross-namespace) |
| `<service>.<namespace>.svc` | `redis.ai-inference.svc` | ClusterIP (FQDN short form) |
| `<service>.<namespace>.svc.cluster.local` | Full FQDN | ClusterIP |

### Key ports to remember

| Port | Service |
|------|---------|
| 443 | HTTPS (Cloudflare, Ingress) |
| 80 | HTTP (redirect to 443) |
| 10254 | Ingress NGINX Prometheus metrics |
| 5432 | PostgreSQL |
| 6379 | Redis |
| 9090 | Prometheus |
| 11434 | Ollama inference API |
| 9400 | DCGM Exporter metrics |

---

## Next Steps

1. As you complete each phase, add **your** actual IPs, timings, and screenshots to a personal runbook.
2. For each phase, try explaining it out loud in 2 minutes — that's interview prep.
3. When something breaks (it will), document the debugging process — employers value problem-solving over perfect configs.

---

*Companion to the main [README](../README.md). Built for the Cloud-Native DevOps Portfolio project.*
