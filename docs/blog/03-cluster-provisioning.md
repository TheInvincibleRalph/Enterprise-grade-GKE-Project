# Provisioning a Private, Multi-Zone GKE Cluster with Terraform

Part 3 of the series. In Part 2 we stopped right after the environment was set up: the folder and project existed, the APIs were enabled, Terraform had its identity (service account impersonation), the state bucket was waiting, budget alerts were wired, and the CLI tools were installed. Everything was *ready* — nothing existed yet. In this part, we stop clicking consoles and start typing: we turn a blank project into a private, multi-zone GKE cluster, and we build it inside the walls of a free-trial account.

---

The following resources were provisioned

1. VPC with custom subnet and secondary ranges for pods/services
2. Cloud NAT for private node egress
3. Regional GKE cluster with Workload Identity
4. Multiple node pools: system, application.

To understand what the Tereaform config achieves, I will highlight important decisions or 'settings' that shaped our infrastructure.

1. Regional routing mode.

By default, GCP networks use GLOBAL routing. But you can explicitly configure routing_mode = "REGIONAL" inside your google_compute_network Terraform resource block for several reasons. In our case, that is what best demonstrate HA and also because GLOBAL routing can be expensive. private_ip_google_access = true helps us reach GCP APIs from the terminal without NAT.

[image]

2. Cloud NAT.

Because our nodes will be private, we need this for egress internet access for our nodes.


3. Remove default node pools.

When you spin up a managed Kubernetes cluster like GKE, a default node pool is automatically crreated to bootstrap the system. Default pool boots with a small HDD disk (GKE defaults to 100GB pd-balanced, which blows the 250GB SSD_TOTAL_GB quota in us-central1 with 3 zones), hence so as to assign our pools with custom disk size we need to remove the default node pools.

[image]

4. Disabling GKE Dataplane V2 to install full Cilium with Wireguard.

Even though GKE Dataplane V2 is built on Cilium, it is fully abstracted. This means you do not get access to advanced self-managed features like the Hubble UI/CLI framework for deep observability, and because we need Hubble for the observability part of this project and WireGuard for encryption, we would install a full Cilium instead.

5. Private Nodes.

I had to set enable_private_nodes = true for each node pools because without it the provider sends enable_private_nodes=false and the pool gets public IPs even in a private cluster, which would blow the tiny IN_USE_ADDRESSES quota for the project.

6. System pool right sizing and taint/toleration.

I used `e2-custom-1-4096` (1 vCPU / 4 GB) because 3 zones × 1 vCPU = 3 of the 12 vCPU, and 4 GB is the floor for GKE's system pods plus Cilium. The `CriticalAddonsOnly` taint keeps application workloads off these nodes — Cilium, CoreDNS, and the operators get the machine to themselves, and nothing from your app can crowd them out.

7. Application pool right sizing and taint/toleration.

I used  `e2-custom-2-8192` (2 vCPU / 8 GB), autoscaling min 1/max 3, because it fits within the quota — 3 app × 2 vCPU (6) + 3 system × 1 vCPU (3) = 9 vCPU ≤ 12, and 6 instances ≤ 8.

8. Spot Nodes.

Spot VMs are on by default (`use_spot_vms = true`) — that's the 60–80% cost cut that makes this whole project affordable on a trial. 

```

```bash
cd infra/terraform

# Remote state — the bucket from Part 2
terraform init -backend-config=backend.hcl

# Read the whole architecture before you commit to it
terraform plan

# Build it
terraform apply -auto-approve
```

A regional cluster takes 10–15 minutes to come up. When it's done, the outputs hand you the kubectl command — no copy-pasting from the console:


Or skip the manual dance entirely — the project's orchestrator script does the whole thing, with each phase as a step:

```bash
./scripts/phase1-deploy.sh terraform    # just the cluster
./scripts/phase1-deploy.sh              # everything: terraform → cilium → gateway → boutique
```

```

## What's next

The cluster is up, but right now its networking is vanilla GKE. In the next part, we replace the default dataplane with **Cilium** — eBPF-based networking, NetworkPolicy enforcement, and transparent WireGuard encryption between every pod.