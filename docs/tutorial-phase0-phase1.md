



# Building an Enterprise-Grade Kubernetes Ecosystem on GKE

A hands-on engineering series featuring Cilium, Envoy Gateway, and Chaos Mesh.

First thing first: Why this project?

If you have ever been curious as to how different tools integrate into a resilient system together beyond merely deploying an isolated app on the cloud or deploying a few pods. Then be my guest on this hands-on series where I build a resilient, highly available and secure K8s environement on GKE. 

This post is the first of 11-series where walk you through building a a live, WAF-protected website on a 3-AZ GKE cluster, step-by-step, every command, every decision, and every error. Each phase builds on the previous one, culminating in a single, cohesive architecture that demonstrates **security, reliability, observability, and cost-awareness** — the four pillars of production infrastructure.

I had fun while iworking on this, and leartnt a lot too and can't wwait to pour all my learnings out here and bring you into the fun. 

What Is In It For You (and Me)?

Completeing this whole project gives you a massive senior-level inisight into enterprise-grade ecosystem and puts you in the know about amazing tools and technologies in the cloud ecosystem. The complete project is hotcake for your DevOps portfolio and a senior-level talking point for you in interviews.

You will also learn the following:

### Infrastructure as Code & GitOps
- Terraform for provisioning GKE clusters, node pools, and networking
- Helm for packaging and deploying complex workloads
- ArgoCD or Flux for GitOps-driven continuous delivery
- GitHub Actions for CI/CD pipelines

### Kubernetes Deep Knowledge
- Operator pattern (CloudNativePG, Istio, KEDA)
- Custom Resource Definitions (CRDs) and controllers
- Pod Disruption Budgets, affinity/anti-affinity, topology spread constraints
- Horizontal Pod Autoscaling (HPA) vs. event-driven autoscaling (KEDA)
- Spot VM node pools and graceful termination handling

### Networking & Security
- Cilium CNI with eBPF — replacing kube-proxy entirely
- Transparent mTLS / WireGuard encryption between pods
- SPIFFE/SPIRE for cryptographic workload identity
- Gateway API (GatewayClass/Gateway/HTTPRoute) on Envoy Gateway — the actively
  maintained successor to the retired ingress-nginx
- Web Application Firewall (Coraza) with OWASP Core Rule Set, running in-process
  as a native Envoy dynamic module (requires Kubernetes 1.35+ — this cluster
  was upgraded from 1.34 to 1.35.5 for exactly this)
- NetworkPolicy and CiliumNetworkPolicy for microsegmentation

### Observability & Chaos Engineering
- Prometheus + Grafana for metrics collection and visualization
- Datadog integration for enterprise-grade APM and infrastructure monitoring
- Chaos Mesh for injecting faults: pod kills, network latency, CPU stress, node failures
- Defining and validating steady-state hypotheses

### AI Infrastructure
- Deploying LLM inference servers (vLLM / Ollama)
- NVIDIA DCGM Exporter for GPU telemetry
- KEDA with Prometheus scalers for queue-driven and GPU-utilization-driven autoscaling
- Model preloading and cold-start optimization on spot instances

### Real-World Enterprise Practices
- Google Cloud Organization hierarchy, IAM, and service accounts
- Cloudflare DNS management with free HTTPS proxying
- Cost optimization with spot VMs and scale-to-zero patterns
- Clean project isolation for budget control


## Constraints and Decisions Made for this Project.

The project runs on a **GCP free trial**: 90 days, $300 credit, no quota increases, no GPUs. The quotas that actually governed the design:

| Metric | Region/Scope | Limit |
|---|---|---|
| `INSTANCES` | us-central1 | 8 |
| `CPUS_ALL_REGIONS` | global | 12 |
| `IN_USE_ADDRESSES` | us-central1 | 4 |
| `SSD_TOTAL_GB` | us-central1 | 250 |
| Quota increases | — | not available on trial |
| GPUs | — | not attachable on trial |

Two GKE behaviors amplified these constraints:

1. **Regional cluster `node_count` is per-zone.** `node_count = 3` creates 3 nodes per zone (9 total) and the creation quota request is multiplied by the 3 zones. This caused the "request requires 18.0 / 24.0" failures (see Cheat-Sheet).
2. **The default node pool is created at cluster creation with 100 GB pd-balanced disks per node** — 3 zones × 100 GB = 300 GB SSD, over the 250 GB limit. The default pool must be created on small HDD disks.

**Final sizing** (in `infra/terraform/terraform.tfvars`):

- System pool: `e2-custom-1-4096` (1 vCPU / 4 GB), `node_count = 1` per zone → 3 nodes, 3 vCPU
- Application pool: `e2-custom-1-4096`, autoscaling min 1 / max 3 (total) → up to 3 nodes, 3 vCPU
- All nodes: spot, `pd-standard` 30 GB, private (no external IPs)
- Totals: 6 vCPU of 12 used, 6 of 8 instances used, 2 of 4 addresses used (NAT + LoadBalancer), ~$50/month

That said, there is a caveat to following this project to the end. Implementing this project for your portfolio can take weeks (if you are the busy type or you decide to add it to one of your weekend projects), or days if you are a student and have the time for stretch commitment. Either one, don’t expect to tear down your infra once you begin. Expensive, right? You don’t have to worry, we are using Spot instances and running on a generous $300 GCP credits! Can I shock you? My full infra—7 nodes, 90+ pods, 200+ containers, and AI inference—stayed up for two weeks on less than $20. So?

Let's get to it!

---

## 1. Phase 0 — Foundation

Goal: domain, GCP project, service account, and state bucket so Terraform can build everything unattended.

### 1.1 Domain and Cloudflare

- Domain obtained via the GitHub Student Pack; nameservers moved to Cloudflare.
- SSL/TLS mode set to **Flexible**: Cloudflare terminates HTTPS at the edge and connects to the origin over plain HTTP. Required because the cluster's gateway (Phase 1.3) serves HTTP on port 80 with no certificate. "Full (strict)" would cause 521/502 errors.

### 1.2 Google Cloud project and APIs

Commands:

```bash
gcloud auth login
gcloud organizations list

# create a folder and the project inside it
gcloud resource-manager folders create --display-name="Infrastructure Engineering" --organization=<ORG_ID>
gcloud projects create devops-portfolio-prod --folder=<FOLDER_ID>
gcloud config set project devops-portfolio-prod
gcloud beta billing projects link devops-portfolio-prod --billing-account=<ACCOUNT_ID>

# enable APIs
gcloud services enable \
  compute.googleapis.com container.googleapis.com cloudresourcemanager.googleapis.com \
  iam.googleapis.com monitoring.googleapis.com logging.googleapis.com
```

### 1.3 Terraform service account

Commands:

```bash
gcloud iam service-accounts create terraform-sa --display-name="Terraform Service Account"

gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/container.admin"
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/compute.admin"
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"
# ADDITIONAL — not in the README, but required for the state backend:
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# NO JSON KEY — impersonation instead. Grant your user the right to
# impersonate the SA, then log in with impersonation (see §1.5):
gcloud iam service-accounts add-iam-policy-binding \
  terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com \
  --member="user:<YOUR_EMAIL>" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud auth application-default login \
  --impersonate-service-account=terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com
```

Without `storage.admin`, the GCS backend fails with a 403 that looks like an auth problem but is a permissions problem.

### 1.4 State bucket

```bash
gcloud storage buckets create gs://devops-portfolio-tfstate/ --uniform-bucket-level-access
```

Referenced by `infra/terraform/backend.hcl` (bucket + `terraform/state` prefix).

### 1.5 Local environment

Tools: terraform, gcloud, kubectl, helm.

**Every terraform command authenticates as `terraform-sa` via ADC impersonation** (set up in §1.3): `gcloud auth application-default login --impersonate-service-account=...` writes an impersonated ADC profile that both the provider **and** the GCS state backend honor. No key file exists, and `GOOGLE_APPLICATION_CREDENTIALS` must NOT be set — it would override the impersonation and point at a key that doesn't exist.

```bash
# one-time setup (see §1.3); afterwards there is nothing to export:
gcloud auth application-default login \
  --impersonate-service-account=terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com
```

---

## 2. Phase 1.1 — Cluster via Terraform

Files: `infra/terraform/main.tf`, `variables.tf`, `terraform.tfvars`, `outputs.tf`, `backend.hcl`.

### 2.1 Networking (main.tf)

- **VPC** `devops-portfolio-vpc`, custom mode, regional routing.
- **Subnet** `10.0.0.0/16` with two secondary ranges: pods `10.1.0.0/16`, services `10.2.0.0/20`; `private_ip_google_access = true`.
- **Cloud Router + Cloud NAT** — required because nodes are private but must pull images and reach Google services.
- **Firewall rules**:
  - `allow-ingress-health-checks`: ports 80/443/8080 from the GCP load-balancer probe ranges (`130.211.0.0/22`, `35.191.0.0/16`, `209.85.152.0/22`, `209.85.204.0/22`). Without it, GCP LBs mark backends unhealthy and serve 502s.
  - `allow-master-to-nodes`: 10250/443 from the master CIDR.
  - `allow-nodes-internal`: full internal traffic within node/pod/service ranges.

### 2.2 Cluster resource — decisions

- **Regional** (`location = var.region`): HA across 3 zones.
- **`networking_mode = "VPC_NATIVE"`** with `ip_allocation_policy` mapping the secondary ranges.
- **`datapath_provider = "LEGACY_DATAPATH"`** — GKE's Dataplane V2 is itself Cilium-based; disabled so the self-managed Cilium (Phase 1.2) owns the datapath and can provide WireGuard encryption.
- **Private cluster**: `enable_private_nodes = true`, `enable_private_endpoint = false` (nodes internal-only; master keeps a public endpoint so kubectl works). Private nodes use zero external IPs — the key to the 4-address quota.
- **Workload Identity**: `workload_pool = "<project>.svc.id.goog"`.
- **`remove_default_node_pool = true` + cluster-level `node_config { disk_size_gb = 30, disk_type = "pd-standard", spot = true }`** — the default pool must be born small and on HDD or cluster creation blows the SSD quota (3 × 100 GB pd-balanced = 300 GB > 250 GB). `spot = true` was aligned with what GKE actually created (a stale-state `spot` diff would otherwise force a pointless full-cluster replacement).
- **`release_channel = "STABLE"` + `min_master_version = "1.35.5-gke.1057002"`** — the Coraza WAF (Phase 1.3) needs Kubernetes image volumes (1.35+). The channel owns patch versions; the floor guarantees fresh deploys never land below 1.35.
- `logging_service` / `monitoring_service` on GKE-managed; `network_policy` disabled (Cilium handles it); `enable_shielded_nodes = true`.

### 2.3 Node pools — the per-zone rule

- **System pool**: `node_count = 1` → **1 node per zone = 3 total** (3-AZ HA). Tainted `CriticalAddonsOnly=NO_SCHEDULE`. `e2-custom-1-4096`, 30 GB `pd-standard`, spot, label `role: system`.
- **Application pool**: autoscaling min 1 / max 3 (**total** counts). Same machine/disk/spot, label `role: application`.
- **`network_config { pod_range = "pods", enable_private_nodes = true }` on every pool** — critical: the Terraform provider sends `enable_private_nodes = false` on any pool with a `network_config` block, silently making the pool public even in a private cluster. This happened in practice: all nodes got external IPs, the 4-address quota collapsed, and pool creation failed with `IN_USE_ADDRESSES exceeded`. The fix is this one line per pool.
- All disks HDD because SSD quota is 250 GB total.
- `e2-custom-1-4096` everywhere: global CPU quota is 12 vCPU and the per-zone multiplication rule means every machine must be 1 vCPU to fit 6 nodes across 3 AZ. 4 GB RAM is the floor for GKE system pods + Cilium.

### 2.4 Commands — init, validate, plan, apply

```bash
cd infra/terraform
# auth comes from ADC impersonation (§1.5) — nothing to export

terraform init -backend-config=backend.hcl
terraform validate
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Quota and state checks used during the process:

```bash
gcloud compute regions describe us-central1 --format=json | jq '.quotas[] | select(.metric=="SSD_TOTAL_GB" or .metric=="CPUS" or .metric=="INSTANCES" or .metric=="IN_USE_ADDRESSES")'
gcloud compute project-info describe --format=json | jq '.quotas[] | select(.metric|contains("CPUS"))'   # global CPUS_ALL_REGIONS
gcloud compute instances list --format="table(name,zone,status,networkInterfaces[0].accessConfigs[0].natIP)"
gcloud container clusters describe devops-portfolio --region us-central1 --format="value(status,currentNodeCount)"

# before replacing a node pool, shrink it to avoid a transient quota peak:
gcloud container clusters resize devops-portfolio --node-pool application-pool --num-nodes 2 --region us-central1 --quiet
```

State recovery procedures (when an apply dies):

```bash
# inspect what's actually in GCS vs. the local errored.tfstate
gcloud storage cat gs://devops-portfolio-tfstate/terraform/state/default.tfstate | jq '{serial, resources: [.resources[].type]}'
terraform state pull | jq '.serial'       # auth: ADC impersonation
# stale lock from a crashed apply:
terraform force-unlock -force <LOCK_ID>  # auth: ADC impersonation
```

**The final apply:** `Plan: 2 to add, 1 to change, 2 to destroy` — cluster updated in-place (private pools, new sizing, autoscaling cap), both node pools recreated. Result: cluster RUNNING, 6 nodes (3 system + 3 app, one per zone), 6 of 12 vCPU used, 6 of 8 instances used.

### 2.5 Cluster upgrade (1.34 → 1.35.5) — why the WAF needs it

The Coraza WAF dynamic module uses Kubernetes image volumes (1.35+). GKE STABLE channel carried `1.35.5-gke.1057002`; the cluster was upgraded deliberately:

```bash
gcloud container get-server-config --region us-central1 --format=json | jq -r '.channels[] | "\(.channel): \(.validVersions | join(", "))"'

gcloud container clusters upgrade devops-portfolio \
  --region us-central1 --master --cluster-version 1.35.5-gke.1057002
gcloud container clusters upgrade devops-portfolio \
  --node-pool system-pool --region us-central1 --cluster-version 1.35.5-gke.1057002
gcloud container clusters upgrade devops-portfolio \
  --node-pool application-pool --region us-central1 --cluster-version 1.35.5-gke.1057002

kubectl get nodes -o wide     # all nodes on 1.35.5
```

Note: a manual `--cluster-version` must be a version the cluster's own channel offers — the first attempt used a REGULAR/RAPID-only patch (1.35.6) and was rejected by GKE with a release-channel error. Check the channel list first.

---

## 3. Phase 1.2 — Cilium CNI + WireGuard encryption

Files: `kubernetes/cilium/values.yaml`, `scripts/install-cilium.sh`, `kubernetes/cilium/encryption-test.yaml`.

### 3.1 What Cilium provides

- **CNI on eBPF**: pod networking programmed as kernel programs; pod IPs from the VPC-native secondary range.
- **kube-proxy replacement** (`kubeProxyReplacement: true`): service handling in eBPF instead of iptables.
- **Transparent WireGuard encryption** of pod-to-pod traffic between nodes.
- **Hubble**: relay + UI for flow observability.

Architecture: one **agent** DaemonSet pod per node, an **operator** deployment, Hubble relay/UI.

### 3.2 values.yaml — decisions

- `kubeProxyReplacement: true`
- `encryption: { enabled: true, type: wireguard }`
- `hubble: { relay.enabled: true, ui.enabled: true }`
- `ipam: { mode: kubernetes }` — GKE VPC-native alias IPs
- `routingMode: native` + **`ipv4NativeRoutingCIDR: 10.0.0.0/8`** — must cover the **pod** CIDR (10.1.0.0/16), not just nodes. With only the /16, pod destinations were outside the native-routing range and the WireGuard logic never engaged (traffic flowed unencrypted; tcpdump on `cilium_wg0` was silent).
- `gke: { enabled: true }`
- **`cni: { binPath: /home/kubernetes/bin }`** — Cilium's default `/opt/cni/bin` is read-only on GKE's Container-Optimized OS; the mount-cgroup init container failed with `cp: cannot create regular file '/hostbin/cilium-mount': Read-only file system`. GKE's real CNI path is `/home/kubernetes/bin`. (Upstream: cilium/cilium#35336.)
- `tolerations: [operator: Exists]` so agents run on the tainted system pool.
- `prometheus.enabled: true` (serviceMonitor off until Phase 2).

### 3.3 Installation and verification commands

```bash
# cluster access first
gcloud container clusters get-credentials devops-portfolio --region us-central1 --project devops-portfolio-prod
kubectl config current-context          # must be the gke_... context
kubectl get nodes                       # 6 nodes

# install / upgrade Cilium (script does helm upgrade --install with the values file)
./scripts/install-cilium.sh

# status + encryption state
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
kubectl exec -n kube-system $(kubectl get pod -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}') -- cilium status | grep -i encryption
# Expect: Encryption: Wireguard [NodeEncryption: Disabled, cilium_wg0 (Pubkey: ..., Port: ..., Peers: 5)]

# WireGuard route check (the fix for "encryption enabled but not happening"):
kubectl exec -n kube-system <cilium-agent-on-node-X> -- ip route show table 2004
# Before fix: only "local default dev lo" — after: 10.1.x.0/24 dev cilium_wg0 per remote node
```

Installation method notes:

- **No `--wait`** in the script — a wait timeout marks the release failed even when resources applied and leaves a stuck "operation in progress" marker that blocks all subsequent runs. Readiness is verified with `kubectl rollout status daemonset/cilium`.
- **Version 1.16.19**, not 1.16.0 — the 1.16.x patch line contains the WireGuard route-programming fixes.
- Recovery from a stuck marker:

```bash
helm history cilium -n kube-system      # find the revision that actually applied the fix
helm status cilium -n kube-system
helm rollback cilium <revision> -n kube-system
```

### 3.4 How the WireGuard encryption works

1. Each node's agent creates a WireGuard interface `cilium_wg0` with its own keypair.
2. Agents build a peer mesh — every node peers with every other node.
3. Each agent programs an encryption routing table (table `2004`) with one route per remote node's pod CIDR, via `cilium_wg0`.
4. The eBPF datapath marks packets destined for remote pods (fwmark `0x200`); an `ip rule` sends marked packets to table 2004, exiting through `cilium_wg0` encrypted.
5. The destination node's device decrypts and delivers the inner packet to the pod.

Result: pods exchange plain HTTP; the wire carries only WireGuard UDP. No application changes.

### 3.5 The verification test (commands run)

`kubernetes/cilium/encryption-test.yaml`: two `netshoot` pods in separate namespaces. Rules: pods on **different nodes** (same-node traffic never touches `cilium_wg0`); the capture pod is a **host-network pod on the destination node**.

```bash
# 1. deploy the test pods
kubectl delete ns test-a test-b --ignore-not-found
kubectl apply -f kubernetes/cilium/encryption-test.yaml
kubectl wait --for=condition=Ready pod/netshoot-a -n test-a --timeout=120s
kubectl wait --for=condition=Ready pod/netshoot-b -n test-b --timeout=120s

# 2. verify placement (NODE column must differ for a and b)
kubectl get pods -n test-a -o wide
kubectl get pods -n test-b -o wide
# if needed, pin b to another node:
kubectl run netshoot-b -n test-b --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"<other-app-node>"}}}' -- sleep 3600

# 3. create the host-network capture pod ON netshoot-b's node
kubectl run netshoot-host -n test-a --image=nicolaka/netshoot --restart=Never \
  --overrides='{"spec":{"hostNetwork":true,"nodeSelector":{"kubernetes.io/hostname":"<node-of-netshoot-b>"},"containers":[{"name":"netshoot-host","image":"nicolaka/netshoot","command":["sleep","3600"]}]}}'
kubectl wait --for=condition=Ready pod/netshoot-host -n test-a --timeout=120s

# 4. start a web server on b
kubectl exec -n test-b netshoot-b -- sh -c 'echo "wireguard works" > /tmp/index.html && cd /tmp && httpd -f -p 80 &'

# 5. terminal A — capture
kubectl exec -n test-a netshoot-host -- tcpdump -i cilium_wg0 -nn "tcp port 80" -c 8

# 6. terminal B — send traffic
kubectl exec -n test-a netshoot-a -- \
  curl -s http://$(kubectl get pod netshoot-b -n test-b -o jsonpath='{.status.podIP}'):80
```

Expected result: the curl prints `wireguard works`; the capture shows the TCP conversation including `HTTP: GET / HTTP/1.1` and `HTTP/1.1 200 OK` — the inner, decrypted view on `cilium_wg0`. The physical interface carries only WireGuard UDP.

### 3.6 Incident history (for reference)

1. Agents crash-looping (`Read-only file system`) → `cni.binPath` fix.
2. Agents up but tcpdump silent (unencrypted traffic) → `ipv4NativeRoutingCIDR` `/8`, then Cilium 1.16.0 → 1.16.19; verified via table `2004` + the capture test.
3. hubble-relay CrashLoopBackOff (peer-sync timeout from the outage) → `kubectl rollout restart deployment/hubble-relay -n kube-system`.

---

## 4. Phase 1.3 — Envoy Gateway + Coraza WAF

Files: `kubernetes/gateway/` (`gatewayclass.yaml`, `envoyproxy.yaml`, `gateway.yaml`, `httproute.yaml`, `waf-extensionpolicy.yaml`), `scripts/install-envoy-gateway.sh`, `kubernetes/legacy/` (superseded ingress-nginx config).

### 4.1 Why Envoy Gateway

The community ingress-nginx controller was **retired in March 2026** — no releases, no security fixes afterward. The project migrated to Envoy Gateway (v1.8.3): Gateway API-native, actively maintained, dynamic config via xDS (no reloads).

### 4.2 Gateway API objects

- **`GatewayClass`**: names the controller (`gateway.envoyproxy.io/gatewayclass-controller`) and references the `EnvoyProxy` via `parametersRef`.
- **`EnvoyProxy`**: customizes the data-plane pods. Declares the Coraza **dynamic module** (`spec.dynamicModules`: name `composer`, source `/etc/envoy/dynamic-modules/libcomposer.so`, `doNotClose: true`) and mounts it via a Kubernetes **image volume** (`ghcr.io/tetratelabs/built-on-envoy/composer:0.6.0`, pinned stable tag) with `GODEBUG=cgocheck=0` (required by the CGO module).
  - The initContainer alternative is rejected by the v1.8.3 API (`unknown field "initContainers"`); image volumes require **Kubernetes 1.35+** — the reason for the cluster upgrade (§2.5). Before the upgrade, the WAF ran as a proxy-wasm filter (`EnvoyExtensionPolicy.wasm`, coraza-proxy-wasm) — a working fallback on 1.34.
- **`Gateway`**: `boutique-gateway`, one HTTP listener on port 80, cross-namespace routes allowed. Produces the LoadBalancer with the external IP (covered by the Phase 1.1 health-check firewall rule). HTTPS is terminated by Cloudflare; origin is plain HTTP.
- **`HTTPRoute`**: `parentRefs: [boutique-gateway]`, hostname placeholder `boutique.example.dev` (sed-replaced at apply time), path `/` → `frontend:80`. Replaces the old `Ingress`.
- **`EnvoyExtensionPolicy`**: targets the Gateway; `dynamicModule` `composer` / `filterName: coraza-waf` with CRS directives (`Include @coraza.conf`, `SecRuleEngine On`, `SecResponseBodyAccess Off`, `Include @crs-setup.conf`, `Include @owasp_crs/*.conf`). Deleting this file disables the WAF.

### 4.3 Controller vs. data plane (the debugging mental model)

- **Controller** (`envoy-gateway` deployment): reconciles Gateway API objects into Envoy config, pushed via xDS.
- **Data plane** (`envoy-…-boutique-gateway-…` pods): serve traffic behind the LoadBalancer.

**A 404 from the gateway almost always means the controller is down and the proxy is serving stale config.** Occurred here: the controller crash-looped on `no route to host` during the Cilium outage; the data plane answered 404s until the controller was restarted after Cilium recovered.

### 4.4 Installation commands

The script does **not** use `helm install`. Helm 4's OpenAPI validation downloads the API server's OpenAPI schema before installing, and large responses from the GKE master stalled on this network (`failed to download openapi: unexpected error when reading response body`) while small kubectl requests worked. The chart is rendered locally and applied with kubectl:

```bash
./scripts/install-envoy-gateway.sh
```

which performs (in order):

```bash
# render locally (no cluster contact; --output-dir avoids Helm v4's stdout pull-status JSON)
helm template eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.3 --namespace envoy-gateway-system --create-namespace --skip-crds \
  --timeout 10m --output-dir /tmp/eg-manifests > /dev/null 2>&1

kubectl create namespace envoy-gateway-system --dry-run=client -o yaml | kubectl apply -f -
find /tmp/eg-manifests -type f -name '*.yaml' | sort | xargs -n1 kubectl apply --validate=false -f

# the Gateway API resources
kubectl apply -f kubernetes/gateway/gatewayclass.yaml
kubectl apply -f kubernetes/gateway/envoyproxy.yaml
kubectl apply -f kubernetes/gateway/gateway.yaml
kubectl apply -f kubernetes/gateway/waf-extensionpolicy.yaml

# wait for acceptance + external IP
kubectl wait --for=condition=Accepted gateway/boutique-gateway -n envoy-gateway-system --timeout=120s
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway -w
```

`--skip-crds`: the Gateway API CRDs were already installed and `Established` by earlier attempts (verify: `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.status.conditions[*].type}'` → includes `Established`). `kubectl apply --validate=false`: skips the OpenAPI download.

Inspection commands:

```bash
kubectl get gatewayclass,gateway -A
kubectl get httproute -n boutique -o yaml | grep -A4 conditions        # Accepted=True
kubectl get envoyextensionpolicy waf-extension -n envoy-gateway-system -o yaml
kubectl get pods -n envoy-gateway-system
```

If the gateway 404s everything:

```bash
kubectl rollout restart deployment/envoy-gateway -n envoy-gateway-system
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system
```

### 4.5 The WAF in the request path

Requests arriving at the Envoy data plane hit the `coraza-waf` filter (Coraza engine with OWASP CRS) before routing: benign requests pass, attack payloads are rejected with **403** (empty body). Same behavior the old ingress-nginx + ModSecurity provided, but in-process, no per-route annotations.

---

## 5. Phase 1.4 — The application (Boutique)

Files: `scripts/deploy-boutique.sh`, `kubernetes/boutique/namespace.yaml`, `kubernetes/gateway/httproute.yaml`.

Commands:

```bash
BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh
```

which: creates the `boutique` namespace; applies Google's Online Boutique manifests from the upstream URL; waits for the frontend rollout; applies `httproute.yaml` with the placeholder host sed-replaced to `boutique.invincibledevops.tech`.

Result: 12 microservice deployments Running (frontend, cartservice, checkoutservice, adservice, …), HTTPRoute in place. Verify:

```bash
kubectl get pods -n boutique
kubectl get httproute -n boutique
```

---

## 6. Phase 1.5 — Making it reachable + verification

### 6.1 Cloudflare

- A record: `boutique` → Gateway external IP (`35.226.118.222`), proxied (console: dash.cloudflare.com → DNS → Add record).
- SSL/TLS mode: **Flexible** (Cloudflare → origin over plain HTTP; origin has no certificate).

### 6.2 Direct verification (before/without DNS)

```bash
curl -i -H "Host: boutique.invincibledevops.tech" http://35.226.118.222/      # expect 200
curl -I https://boutique.invincibledevops.tech                                # expect 200 (via Cloudflare)
```

### 6.3 WAF verification

```bash
# SQLi must be blocked:
curl -i -H "Host: boutique.invincibledevops.tech" "http://35.226.118.222/?id=1'+OR+'1'='1"   # expect 403

# full suite — five payloads, all must return 403:
./scripts/waf-test.sh https://boutique.invincibledevops.tech

# optional ZAP baseline scan (requires Docker):
./scripts/zap-scan.sh https://boutique.invincibledevops.tech

# deny decisions in the proxy logs:
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway | grep -i coraza
```

### 6.4 How the website comes up (end-to-end path)

```
Browser → https://boutique.invincibledevops.tech
  → Cloudflare: DNS resolution (A record), TLS termination, Flexible SSL → plain HTTP to origin
  → GCP LoadBalancer (external IP 35.226.118.222; health checks pass via the Phase 1.1 firewall rule)
  → Envoy data-plane pod (gateway listener on :80)
      → Coraza WAF filter (OWASP CRS) — blocks attacks with 403, passes benign traffic
      → route match: HTTPRoute hostname "boutique.invincibledevops.tech" → backendRef frontend:80
  → frontend Service (ClusterIP, programmed by Cilium eBPF kube-proxy replacement)
  → frontend pod (serves the storefront UI)
  → downstream microservices (productcatalogservice, cartservice, …) via their Services
```

Underlying substrate: pods have IPs from the `pods` secondary range (10.1.0.0/16); inter-node pod traffic is encrypted by Cilium WireGuard (inner TCP visible only on `cilium_wg0`); node egress goes through Cloud NAT; the control plane is reachable via its public endpoint; everything was provisioned by Terraform with state in GCS.

---

## 7. Current state of the deployment (Phase 1 complete)

- Cluster `devops-portfolio`, us-central1, regional, GKE **1.35.5** (STABLE, `min_master_version` pinned), RUNNING
- 6 nodes: 3 system + 3 application (e2-custom-1-4096, spot, pd-standard 30 GB, private, 1 per AZ)
- Cilium 1.16.19: agents Running, WireGuard encryption verified (packets on `cilium_wg0`, HTTP invisible on the wire)
- Envoy Gateway v1.8.3: controller + data plane Running, Gateway `Accepted=True`, LoadBalancer with external IP
- Coraza WAF dynamic module attached via EnvoyExtensionPolicy; attack payloads return 403
- Online Boutique: 12 services Running; HTTPRoute Accepted; reachable via Cloudflare (Flexible SSL)
- Quota usage: 6/12 vCPU, 6/8 instances, 2/4 addresses, 0/250 GB SSD

---

## 8. Cheat-sheet — every error encountered and its fix

| Error | Cause | Fix |
|---|---|---|
| `Quota 'SSD_TOTAL_GB' exceeded` (300 GB requested) | GKE default pool: 3×100 GB pd-balanced | cluster-level `node_config { disk_size_gb = 30, disk_type = "pd-standard" }` |
| `Quota 'IN_USE_ADDRESSES' exceeded` | Node pools silently public (provider default on `network_config` blocks) | `enable_private_nodes = true` in each pool's `network_config` |
| `Quota 'CPUS_ALL_REGIONS': request requires 18/24` | Regional `node_count`/max × 3 zones | `node_count = 1` per pool; 1-vCPU machines; app max 3 |
| `failed to upload state … i/o timeout` | Transient network to GCS | Retry; verify with `gcloud storage cat` |
| `Error acquiring the state lock (412)` | Crashed apply's orphaned lock | `terraform force-unlock -force <LOCK_ID>` |
| `invalid_rapt` / "Reauthentication required" | gcloud personal token flagged for reauth | `gcloud auth login`, or re-run the impersonation login (§1.3) — refresh-token ADC is not affected by rapt |
| `cp … /hostbin/cilium-mount: Read-only file system` | `/opt/cni/bin` read-only on COS | `cni.binPath: /home/kubernetes/bin` |
| tcpdump on `cilium_wg0` silent while traffic works | WireGuard routes never programmed | `ipv4NativeRoutingCIDR` must cover pod CIDR (`/8`); Cilium ≥ 1.16.19 |
| `helm … failed to download openapi` | Large API responses stall on this network | `helm template` + `kubectl apply --validate=false` |
| `another operation (install/upgrade/rollback) is in progress` | `--wait` timeout left release pending | `helm rollback <release> <revision>`; drop `--wait` |
| Gateway 404 for all requests | Controller down (often after a CNI outage) | `kubectl rollout restart deployment/envoy-gateway` |
| `unknown field "initContainers"` (EnvoyProxy) | v1.8.3 EnvoyProxy API has no initContainers | image volumes — requires cluster 1.35+ |
| Cloudflare 521/502 over HTTPS | SSL mode Full (strict) against HTTP origin | SSL mode: Flexible |
| release-channel error on manual upgrade | `--cluster-version` from another channel | use a version from the cluster's own channel (check `get-server-config`) |
| `pod "netshoot-host" not found` | Test namespace deleted by reset | recreate the host-network capture pod (§3.5) |



Phase 1.2 — Cilium (deploy + verify the platform itself):

Deploy Cilium — install-cilium.sh (helm, values with WireGuard + kube-proxy replacement + Hubble enabled)
Install the cilium CLI — the workstation tool used for status, health, and the connectivity suite (cilium-dbg inside the agent pods covers the rest)
Health check — cilium status / cilium-dbg status: agents Running, encryption line, datapath healthy
WireGuard encryption proof — encrypt status (pubkey + peers), then the tcpdump capture on cilium_wg0 showing HTTP only inside the tunnel
The node mesh — cilium-dbg node list: 6 nodes, one pod /24 each
The security model — cilium-dbg endpoint list: pods + identities, policy Disabled-by-default noted
The kernel maps — bpf lb list (every Service in eBPF — kube-proxy replacement proven) and bpf ipcache list (IP → identity)
The functional suite — cilium connectivity test (CLI-only): the wall of ✅ checks (pod-to-pod, ClusterIP, DNS, host, health)
Hubble basics — port-forward the UI, hubble observe on test-pod traffic, and the policy deny demo (apply a CiliumNetworkPolicy, watch DROPPED verdicts) — proving observability + enforcement with synthetic traffic
Phase 1.4 — Boutique (deploy the app, watch the real traffic):

Deploy the boutique — deploy-boutique.sh, HTTPRoute applied
Watch real application traffic in Hubble — hubble observe --from-pod boutique/frontend --to-pod boutique/ shows the live frontend ↔ microservices conversations (productcatalog, cart, shipping…), plus the loadgenerator hammering the store — the same Cilium features from 1.2, now on the actual application
The division of labor is now explicit: the CLI owns steps 2–3 and 8 (status, connectivity test), the agent's cilium-dbg owns 4–7 (in-pod access, no install needed), and Hubble owns 9–11.

---

## 9. The Cilium connectivity test — the working procedure

This section records the exact, verified way to run Cilium's full functional suite (`cilium connectivity test`) on this cluster — and every obstacle that tried to stop it, because the obstacles are the lesson.

### 9.1 The three tools, and when to use which

| Tool | Runs | Used for |
|---|---|---|
| `cilium` CLI (local, `brew install cilium`) | on your workstation | `cilium status`, `cilium connectivity test` |
| `cilium-dbg` (in the agent image) | inside `kube-system/cilium-*` pods | status, encryption, node mesh, endpoint list, BPF maps — no install needed |
| `cilium-cli` image (`quay.io/cilium/cilium-cli`) | as an in-cluster Job | the full connectivity suite, immune to workstation network issues |

**Critical: run the full suite in-cluster, not from your workstation.** On this network, long-lived connections from the Mac to the GKE master consistently stall (the same failure family as Helm's OpenAPI downloads and watch bookmarks). The CLI's test probes use `kubectl exec` streams — they time out from the workstation. Running the CLI as a Job inside the cluster makes every probe pod-to-pod over the cluster's own network.

### 9.2 The in-cluster procedure (verified working)

```bash
# 1. admin identity for the test job
kubectl create serviceaccount cilium-test -n kube-system
kubectl create clusterrolebinding cilium-test-admin \
  --clusterrole=cluster-admin --serviceaccount=kube-system:cilium-test

# 2. run the suite as a Job (kubectl create job has no --serviceaccount in newer kubectl — use the manifest)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: cilium-ct
  namespace: kube-system
spec:
  backoffLimit: 1
  template:
    spec:
      serviceAccountName: cilium-test
      restartPolicy: Never
      containers:
        - name: cilium-ct
          image: quay.io/cilium/cilium-cli:latest
          command: ["cilium", "connectivity", "test", "--timeout", "30m", "--test", "!check-log-errors"]
EOF

# 3. watch, then read the report
kubectl logs -n kube-system job/cilium-ct -f
kubectl logs -n kube-system job/cilium-ct | tail -40
```

Expected result: `📋 Test Report` with **all 65 tests passing (677 actions)**. The `--test "!check-log-errors"` skips the one log-scan check (see 9.4).

### 9.3 The four gotchas that cost the most time

1. **Stale test namespaces poison re-runs (the big one).** The suite deploys its test pods into `cilium-test-1` / `cilium-test-ccnp1` / `cilium-test-ccnp2` and reuses them on later runs. If a run is cancelled mid-suite, its cleanup may not run — leaving **deny policies behind** (`kubectl get ciliumnetworkpolicy -n cilium-test-1` showed `client-egress-only-dns` and `client-egress-tls-sni` — 12 hours old — which blocked the client pods' traffic and made every subsequent run fail at setup with misleading "context deadline exceeded" errors). **Fix: delete the namespaces before re-running:**
   ```bash
   kubectl delete ns cilium-test-1 cilium-test-ccnp1 cilium-test-ccnp2 --wait=false
   ```
   **The one-line habit that would have saved hours: `kubectl get ciliumnetworkpolicy -A` before any re-run.**

2. **Workstation network stalls.** Every local `cilium connectivity test` died on exec-stream timeouts (`command failed (pod=..., container=client): context deadline exceeded`) or TLS handshake timeouts to the master — while the same probes succeeded in-cluster. Symptom, not disease: don't debug the cluster when the client can't keep a connection open.

3. **Load generator CPU starvation.** The boutique's `loadgenerator` hammers the store 24/7 on the same 1-vCPU nodes the test runs on. Pause it during the suite:
   ```bash
   kubectl scale deployment loadgenerator -n boutique --replicas=0   # and back to 1 after
   ```

4. **The `check-log-errors` failure is benign on GKE.** The only flagged item in an otherwise fully-passing run was a log-scan finding this error in agent logs:
   ```
   ListenAndServe failed for service health server ... listen tcp :30259: bind: address already in use
   serviceName=envoy-envoy-gateway-system-boutique-gateway-bf4de012 svcHealthCheckNodePort=30259
   ```
   Root cause: **30259 is the Envoy Gateway LoadBalancer's `healthCheckNodePort`**, which GKE's own kube-proxy binds to answer the GCP health checks — Cilium's built-in service-health server tries to bind the same port at startup, fails once, and moves on. Health checks still work (the site stays up); it's coexistence noise. Either accept and document it, or exclude that single check with `--test "!check-log-errors"` for a clean report — both defensible; the exclusion is verified and honest about why.

### 9.4 What the suite proves (the report to screenshot)

- 65 tests / 677 actions: pod-to-pod (same-node and cross-node), ClusterIP services (kube-proxy replacement), NodePort, DNS, network policies (allow/deny/expression/CIDR), host networking, health checks
- `check-log-errors` is the only test that can "fail" on this setup, and only for the port-30259 log line above
- The full verification stack that worked end-to-end: `cilium status` (Encryption: Wireguard, Peers: 5) → `cilium-dbg encrypt status` → `cilium-dbg node list` → `cilium-dbg endpoint list` → `cilium-dbg bpf lb list` → WireGuard tcpdump proof → in-cluster connectivity suite → Hubble flows