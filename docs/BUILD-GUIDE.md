# 🏗️ Cloud-Native DevOps Portfolio

> A production-grade, enterprise infrastructure engineering portfolio built on Kubernetes — progressing from secure foundations through stateful workloads, zero-trust networking, chaos engineering, and AI model serving.

---

traditional networking into modern cloud native networking.

## Table of Contents

1. [Why This Project Matters](#why-this-project-matters)
2. [What You Will Learn](#what-you-will-learn)
3. [Architecture Overview](#architecture-overview)
4. [Prerequisites & Cost Strategy](#prerequisites--cost-strategy)
5. [Phase 0: Cost-Saving Foundation (Days 1–2)](#phase-0-cost-saving-foundation-days-12)
6. [Phase 1: Core Infrastructure & Security (Week 1)](#phase-1-core-infrastructure--security-week-1)
7. [Phase 2: Stateful Workloads & Observability (Week 2)](#phase-2-stateful-workloads--observability-week-2)
8. [Phase 3: AI Model Serving & Event-Driven Autoscaling (Week 3)](#phase-3-ai-model-serving--event-driven-autoscaling-week-3)
9. [Phase 4: Chaos Engineering & Resilience Validation (Week 4)](#phase-4-chaos-engineering--resilience-validation-week-4)
10. [Advanced Extensions](#advanced-extensions)
11. [GitHub Student Pack Benefits Mapping](#github-student-pack-benefits-mapping)
12. [Cleanup & Cost Controls](#cleanup--cost-controls)
13. [Repository Structure](#repository-structure)

---

## Why This Project Matters

Most DevOps portfolios stop at "I deployed an app to Kubernetes." This project goes far deeper — it simulates the **Day 2 Operations** that senior infrastructure engineers handle daily in enterprises:

| Surface-Level Skill | What This Project Proves Instead |
|---|---|
| Deploy a database pod | Run a self-healing, replicated database cluster with automated leader election and zero-downtime failover |
| Enable TLS on an ingress | Encrypt *all* pod-to-pod traffic inside the cluster using eBPF-based transparent encryption — no application changes needed |
| Add a firewall rule | Deploy a Web Application Firewall that blocks OWASP Top 10 attacks and prove it with automated penetration tests |
| Set CPU limits | Autoscale AI model servers based on GPU VRAM saturation and inference queue depth, then scale to zero when idle |
| Monitor with `kubectl top` | Stream real-time metrics to enterprise-grade dashboards (Datadog) and correlate chaos experiments with service health |

Each phase builds on the previous one, culminating in a single, cohesive architecture that demonstrates **security, reliability, observability, and cost-awareness** — the four pillars of production infrastructure.

---

## What You Will Learn

By completing this project end-to-end, you will have hands-on experience with:

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

---

## Architecture Overview

```
                    ┌──────────────────────────────────────────────────┐
                    │            Cloudflare (Free) — HTTPS,            │
                    │        DNS, DDoS shield (SSL mode: Flexible)    │
                    └──────────────────────┬──────────────────────────┘
                                           │
                    ┌──────────────────────▼──────────────────────────┐
                    │      GCP Load Balancer (external IP 35.226.x.x) │
                    └──────────┬──────────────────┬───────────────────┘
                               │                  │
        ┌──────────────────────▼───────┐  ┌───────▼──────────────────────┐
        │  Envoy Gateway — replica 1   │  │  Envoy Gateway — replica 2   │
        │  (us-central1-b)             │  │  (us-central1-c)             │
        │  + Coraza WAF (OWASP CRS)    │  │  + Coraza WAF (OWASP CRS)    │
        │  (load balances traffic      │  │  (load balances traffic      │
        │   across the 3 AZs)          │  │   across the 3 AZs)          │
        └─────────────┬────────────────┘  └──────────────┬───────────────┘
        ┌─────────────▼────────────────┐  ┌──────────────▼───────────────┐
        │  Envoy Gateway — replica 3   │  │                              │
        │  (us-central1-f)             │  │                              │
        │  + Coraza WAF (OWASP CRS)    │  │                              │
        └─────────────┬────────────────┘  └──────────────────────────────┘
                      │
        ┌─────────────▼─────────────────────────────────────────────────┐
        │                 GKE Cluster — REGIONAL (3 AZs)                │
        │                                                               │
        │  ┌─ Zone us-central1-b ──┐  ┌─ Zone us-central1-c ──┐  ┌─ Zone│
        │  │ system node (1 vCPU)  │  │ system node (1 vCPU)  │  │ us-c │
        │  │ app node    (2 vCPU)  │  │ app node    (2 vCPU)  │  │ ...  │
        │  └───────────────────────┘  └───────────────────────┘  └──────│
        │                                                               │
        │  ┌─────────────────────────────────────────────────────────┐ │
        │  │        Cilium CNI (eBPF) — across all zones            │ │
        │  │  • WireGuard encryption (pod-to-pod, node-to-node)     │ │
        │  │  • eBPF service load balancing (kube-proxy replaced)   │ │
        │  │  • NetworkPolicy enforcement                           │ │
        │  │  • Hubble observability                                │ │
        │  └─────────────────────────────────────────────────────────┘ │
        │                                                               │
        │  Namespace: db         Namespace: app       Namespace: ai     │
        │  ┌────────────────┐    ┌───────────────┐    ┌──────────────┐  │
        │  │ ha-postgres-1  │    │ frontend      │    │ ollama       │  │
        │  │ (LEADER)       │    │ + 11 microsrv │    │ (CPU, 3B Q4) │  │
        │  │ ha-postgres-2  │    │ redis-cart    │    │ queue-worker │  │
        │  │ ha-postgres-3  │    │               │    │ inference-api│  │
        │  │ (replicas,     │    │               │    │ KEDA scaler  │  │
        │  │  spread across │    │               │    │ (scale-to-0) │  │
        │  │  3 AZs)        │    │               │    │              │  │
        │  └────────────────┘    └───────────────┘    └──────────────┘  │
        │                                                               │
        │  Node pools (spot, private, HDD):                             │
        │  • system: 3 × e2-custom-1-4096 (1 vCPU / 4 GB) — 1 per AZ    │
        │  • app:    3 × e2-custom-2-8192 (2 vCPU / 8 GB) — 1 per AZ    │
        │    (NO GPU pool — AI inference runs on CPU on the trial)      │
        │                                                               │
        │  Observability: Prometheus + Grafana (DB/WAF dashboards),     │
        │  Datadog (agent + cluster agent, APM/logs), Cilium Hubble     │
        └───────────────────────────────────────────────────────────────┘
```

Key facts baked into the diagram (for the Excalidraw AI pass):

- **3 AZs**: `us-central1-b`, `us-central1-c`, `us-central1-f` — one system + one app node each
- **Edge**: Cloudflare (Flexible SSL) → GCP Load Balancer → **3 Envoy Gateway replicas** (one per AZ), each with the in-process **Coraza WAF (OWASP CRS)**, balancing traffic across zones
- **Networking**: Cilium CNI (eBPF) replaces kube-proxy; **WireGuard encrypts pod-to-pod traffic**; Hubble observes flows
- **Namespaces**: `db` (CloudNativePG: leader + 2 replicas spread across AZs), `app` (Online Boutique: frontend + 11 microservices + redis-cart), `ai` (Ollama **on CPU** with a quantized 3B model, queue-worker, inference-api, KEDA queue-driven scaler with scale-to-zero)
- **Node pools**: system 3×1 vCPU/4 GB, app 3×2 vCPU/8 GB, all spot/private/HDD — **no GPU pool** (trial constraint; AI is CPU-based)
- **Observability**: Prometheus + Grafana (PostgreSQL + WAF dashboards), Datadog (agent DaemonSet + cluster agent), Hubble

---

## Prerequisites & Cost Strategy

### The Senior Engineer's Billing Hack

This is the single most important step before writing any Terraform or Kubernetes YAML. The Senior Engineers shared a method that unlocks **$300 in free GCP credits** while giving you enterprise-level organizational controls.

#### Step 1: Acquire a Domain (Free with GitHub Student Pack)

Using your **GitHub Student Developer Pack**:

1. Go to [GitHub Education → Student Developer Pack](https://education.github.com/pack)
2. Claim a free `.me` domain from **Namecheap** OR a free `.dev`/`.app` domain from **Name.com** OR a free `.tech` domain from **.TECH Domains**
3. Pick something professional — e.g., `yourname.dev` or `yourproject.tech`

**Why this matters:** A custom domain unlocks Cloudflare's full feature set and is required to create a Google Cloud Identity organization.

#### Step 2: Transfer Nameservers to Cloudflare

1. Sign up for a free Cloudflare account
2. Add your domain to Cloudflare
3. Cloudflare will scan existing DNS records — you can clear them all
4. Copy the two nameservers Cloudflare assigns you
5. Go to your domain registrar (Namecheap/Name.com) and replace their nameservers with Cloudflare's
6. Wait for propagation (can take up to 24 hours, usually 15–30 minutes)

**Key settings to enable on Cloudflare:**
- **SSL/TLS → Full (strict):** Encrypts traffic between Cloudflare and your origin
- **Always Use HTTPS:** Redirects all HTTP to HTTPS
- **Automatic HTTPS Rewrites:** Fixes mixed content
- **Brotli compression:** Smaller payloads

#### Step 3: Create Google Cloud Identity (Free)

This is the enterprise unlock. Instead of creating a personal GCP account with `@gmail.com`, you create an organizational identity:

1. Go to [Cloud Identity Free](https://cloud.google.com/identity/docs/set-up-cloud-identity)
2. Sign up using an email like `admin@yourdomain.dev`
3. Verify domain ownership (Cloudflare makes this easy — add the TXT verification record in the DNS dashboard)
4. You now have a **Google Cloud Organization** with your domain as the root

**What this unlocks:**
- Organizational hierarchy: Folders → Projects (like a real enterprise)
- IAM architecture practice: Service accounts, custom roles, workload identity federation
- Billing account management with budget alerts
- Project isolation: Create/destroy entire environments without affecting others

#### Step 4: Activate $300 Free Credits

1. In Google Cloud Console, go to **Billing**
2. Set up a billing account (requires credit card — no charges until credits exhaust)
3. Go to the [GCP Free Program](https://cloud.google.com/free) page
4. The $300 credits are automatically applied to new accounts and expire after 90 days

#### Step 5: Configure Budget Alerts

```
Billing → Budgets & Alerts → Create Budget
  - Scope: All projects linked to billing account
  - Amount: $250 (you want alerts BEFORE $300 runs out)
  - Thresholds: 50% ($125), 75% ($187.50), 90% ($225), 100% ($250)
  - Notifications: Email + Pub/Sub
```

These alerts are critical. The moment you hit 90%, stop all non-essential resources.

### Cost Optimization Strategy

| Technique | Estimated Savings | Applied To |
|---|---|---|
| Spot VMs for node pools | 60–80% | App servers, AI inference, batch jobs |
| Scale-to-zero with KEDA | ~100% when idle | AI inference workloads |
| Preemptible/spot for GPU nodes | 50–70% | GPU node pools (L4/T4) |
| Regional cluster (not zonal) | +15% over zonal, but HA | GKE control plane |
| `e2` machine family (shared core) | 30–50% vs `n2` | System workloads, monitoring |

### Tools You Need Installed

```bash
# Core CLI tools
brew install google-cloud-sdk    # gcloud CLI
brew install terraform            # Infrastructure as Code
brew install kubectl              # Kubernetes CLI
brew install helm                 # Kubernetes package manager
brew install kubectx              # Context switching
brew install k9s                  # Terminal UI for K8s (optional but highly recommended)
brew install jq yq                # JSON/YAML processing
brew install wrk                  # HTTP benchmarking
brew install k6                   # Load testing (Grafana k6)

# Verify installations
gcloud version
terraform version
kubectl version --client
helm version
```

---

## Phase 0: Cost-Saving Foundation (Days 1–2)

### 0.1 Domain & Cloudflare

- [x] Claim free domain via GitHub Student Pack
- [x] Transfer nameservers to Cloudflare
- [x] Enable Full (strict) SSL, Always HTTPS

### 0.2 Google Cloud Organization

```bash
# Install gcloud and authenticate
gcloud auth login

# Verify your organization exists
gcloud organizations list

- Add permission to create folder in orgamization-level

# Create a folder for this project
gcloud resource-manager folders create \
  --display-name="Infrastructure Engineering" \
  --organization=$(gcloud organizations list --format='value(ID)')

# Create the project
gcloud projects create devops-portfolio-prod \
  --folder=$(gcloud resource-manager folders list --organization=$(gcloud organizations list --format='value(ID)') --format='value(ID)')

# Set as default
gcloud config set project devops-portfolio-prod

# Link billing account
gcloud beta billing projects link devops-portfolio-prod \
  --billing-account=$(gcloud beta billing accounts list --format='value(ACCOUNT_ID)')
```

### 0.3 Enable Required GCP APIs

```bash
gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com
```

### 0.4 Create Service Account for Terraform

```bash
# Create service account
gcloud iam service-accounts create terraform-sa \
  --display-name="Terraform Service Account"

# Grant necessary roles
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/container.admin"

gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/compute.admin"

gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountUser"

# ADDITIONAL — not in the original plan, but REQUIRED: the SA must read/write
# the state bucket in Phase 1.1. Without storage.admin, Terraform fails with
# a 403 that looks like an auth problem but is a permissions problem.
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/storage.admin"

# NO JSON KEY — the org guardrail (constraints/iam.managed.disableServiceAccountKeyCreation)
# blocks downloadable keys by default, and we don't need one anyway. Instead,
# grant your user identity the right to impersonate the SA, then authenticate
# with impersonation: Terraform mints short-lived SA tokens on the fly, and
# nothing long-lived ever touches disk.
gcloud iam service-accounts add-iam-policy-binding \
  terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com \
  --member="user:<YOUR_EMAIL>" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud auth application-default login \
  --impersonate-service-account=terraform-sa@devops-portfolio-prod.iam.gserviceaccount.com

# ⚠️ GOOGLE_APPLICATION_CREDENTIALS must NOT be set (unset it in any shell
#    where you exported it) — it overrides ADC impersonation.
```

to view your project

go to console.cloud.google.com/cloud-resource-manager
---

## Phase 1: Core Infrastructure & Security (Week 1)

### 1.1 Provision GKE Cluster with Terraform

Create the Terraform configuration for a regional GKE cluster with Cilium as the CNI.

```hcl
# infra/terraform/main.tf
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }
}

# No credentials block — the provider authenticates via ADC impersonation
# (gcloud auth application-default login --impersonate-service-account=...,
# see §0.4). A credentials line here would override ADC and force a key.
provider "google" {
  project = var.project_id
  region  = var.region
}

# VPC
resource "google_compute_network" "vpc" {
  name                    = "devops-portfolio-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "gke-subnet"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = "10.0.0.0/16"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# Cloud Router + NAT (for private nodes to reach internet)
resource "google_compute_router" "router" {
  name    = "nat-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat-config"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# GKE Cluster with Cilium CNI (dataplane v2 disabled to install Cilium manually)
resource "google_container_cluster" "primary" {
  name     = "devops-portfolio-cluster"
  location = var.region # Regional cluster for HA

  # Disable default CNI to install Cilium
  networking_mode = "VPC_NATIVE"

  # We install Cilium separately — all node pools are separate resources
  remove_default_node_pool = true
  initial_node_count       = 1 # minimal default pool, deleted on creation

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Enable Workload Identity for IAM-based service account auth
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Enable all logging/metrics
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # Security
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }
}

# System node pool
resource "google_container_node_pool" "system" {
  name    = "system-pool"
  cluster = google_container_cluster.primary.name
  location = var.region

  node_count = 3  # 3 nodes across zones for HA

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    # Use spot VMs for cost savings
    spot         = true

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      role = "system"
    }

    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Application node pool
resource "google_container_node_pool" "application" {
  name    = "application-pool"
  cluster = google_container_cluster.primary.name
  location = var.region

  initial_node_count = 2

  autoscaling {
    min_node_count  = 2
    max_node_count  = 8
  }

  node_config {
    machine_type = "e2-standard-8"
    disk_size_gb = 200
    disk_type    = "pd-ssd"
    spot         = true

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      role = "application"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# GPU node pool for AI workloads
resource "google_container_node_pool" "gpu" {
  name    = "gpu-pool"
  cluster = google_container_cluster.primary.name
  location = var.region

  initial_node_count = 1

  autoscaling {
    min_node_count  = 0
    max_node_count  = 4
  }

  node_config {
    machine_type = "g2-standard-8"   # 1x L4 GPU, 8 vCPU, 32GB
    disk_size_gb = 200
    disk_type    = "pd-ssd"
    spot         = true

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      role = "gpu"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
```

```bash
# Apply Terraform
cd infra/terraform
gcloud auth application-default login

Earlier we used gcloud auth login, but that cant work for terraform else you run into this error

╷

```bash
│ Error: storage.NewClient() failed: dialing: credentials: could not find default credentials. See https://cloud.google.com/docs/authentication/external/set-up-adc for more information
```

Use gcloud auth login when you (the human) are running gcloud commands in the terminal.

Use gcloud auth application-default login (ADC) when your code or local tools (like Terraform, Python scripts, or SDKs) are running commands on your machine.

terraform init
terraform plan
terraform apply -auto-approve
```

By default, GCP Free Trial / new accounts come with strict default quota limits:

Your regional quota for SSD storage in us-central1 is 250 GB. so you want to use standard persistent disks (pd-standard) and reduce the disk size between 30–100 GB per node. Unless you have heavy database read/write performance requirements, you don't need SSDs

### 1.2 Install Cilium CNI with Transparent Encryption

Instead of using GKE's default kube-proxy-based networking, we install Cilium as the CNI for eBPF-powered networking and transparent pod-to-pod encryption.


 Transparent Pod-to-Pod Encryptionkube-proxy: Does not provide native encryption. To secure internal traffic, you must layer a heavy Service Mesh (like Istio using mTLS sidecars) on top, which injects proxy containers into every pod, dramatically increasing memory consumption and latency.Cilium: Achieves encryption cleanly inside the Linux kernel. It intercepts packets before they leave the pod network interface and wraps them using either WireGuard (highly optimized, low configuration) or IPsec (hardware-accelerated, enterprise standard). This happens transparently, meaning application code remains completely untouched and no sidecar proxies are needed.

  Observability and Debuggingkube-proxy: When network traffic drops mysteriously in a standard cluster, engineers have to resort to painful tcpdump commands across multiple nodes to trace the failure.Cilium: Includes Hubble, an observability platform embedded directly into the eBPF data path. It provides real-time, rich contextual graphs of your network. Instead of looking at raw hexadecimal packet data, you instantly see deep telemetry, connection dependencies, and precise network drop reasons (e.g., policy denials or connection timeouts).

  *WireGuard encryption protocol*

  
```bash
# Get cluster credentials
gcloud container clusters get-credentials devops-portfolio-cluster --region us-central1

# Install Cilium CLI
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
if [ "$(uname -m)" = "arm64" ]; then CLI_ARCH=arm64; fi
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}
shasum -a 256 -c cilium-darwin-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-darwin-${CLI_ARCH}.tar.gz /usr/local/bin
rm cilium-darwin-${CLI_ARCH}.tar.gz{,.sha256sum}

# Install Cilium with WireGuard encryption enabled
cilium install \
  --version 1.16.0 \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set kubeProxyReplacement=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# Verify Cilium is healthy
cilium status --wait
cilium connectivity test

# Verify WireGuard encryption is active
cilium status | grep Encryption
# Expected: Encryption: Wireguard   [OK]
```

or

# Option A: make it executable, then run as before
chmod +x scripts/install-envoy-gateway.sh
./scripts/install-envoy-gateway.sh


# 1. Point kubectl at the GKE cluster (if your gcloud login is working again)
gcloud container clusters get-credentials devops-portfolio \
  --region us-central1 --project devops-portfolio-prod

  If you get an error like this:

  ```bash
  CRITICAL: ACTION REQUIRED: gke-gcloud-auth-plugin, which is needed for continued use of kubectl, was not found or is not executable. Install gke-gcloud-auth-plugin for use with kubectl by following https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin
```
it is because `kubectl and other Kubernetes clients require an authentication plugin, gke-gcloud-auth-plugin, which uses the Client-go Credential Plugins framework to provide authentication tokens to communicate with GKE clusters.` as per the documentation.

install the plugin using:

gcloud components install gke-gcloud-auth-plugin

then re-run:
gcloud container clusters get-credentials devops-portfolio \
  --region us-central1 --project devops-portfolio-prod
Fetching cluster endpoint and auth data.

Then confirm you're on the right cluster:


kubectl config current-context      # should contain "gke_devops-portfolio-prod_..."
kubectl get nodes                   # should show 6 nodes (3 system + 3 app)

now rerun the script:

 devops-portfolio % chmod +x scripts/install-envoy-gateway.sh                   
./scripts/install-envoy-gateway.sh 

Confirm gateway is installed.

kubectl get crd | grep -c gateway                                  # expect 20+
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.status.conditions[0].type}'                       # expect "Established"

If you get `NamesAccepted`, it means "the API server accepted the name" — but the missing Established means the API server never finished activating the resource type.

**Why Cilium over default kube-proxy:**
- eBPF replaces iptables — dramatically faster packet processing at kernel level
- WireGuard encryption is transparent — your applications don't need TLS certificates
- Hubble provides real-time network observability (which pod talked to which, when, how much data)
- NetworkPolicy enforcement is kernel-native — no iptables complexity


eBPF (Extended Berkeley Packet Filter) is a programmable, modern Linux kernel technology that executes sandboxed code at O(1) constant time complexity, whereas iptables is a legacy, rule-based packet-filtering framework that evaluates traffic sequentially using O(n) linear time complexity. While iptables is simple and built-in, eBPF radically outperforms it in throughput, scaling, observability, and flexibility—making eBPF the default standard for modern cloud-native and Kubernetes


\(O(1)\) (Constant Time) means an operation takes the exact same amount of time to finish, whether you are managing 5 server rules or 50,000 server rules. \(O(n)\) (Linear Time) means the processing time grows directly and predictably with the number of rules (\(n\)); if your rule count triples, your processing time triples.


Cloudflare A record
Go to dash.cloudflare.com → select the invincibledevops.tech zone
DNS → Records → Add record:
Type: A
Name: boutique
IPv4 address: 35.226.118.222
Proxy status: Proxied (orange cloud)
Save
Important — check your SSL/TLS mode (SSL/TLS → Overview): it must be Flexible (Cloudflare → your origin over plain HTTP). Your README Phase 0.1 says Full (strict), which was tuned for a TLS-terminating origin — our Envoy Gateway serves HTTP on :80, so strict mode will give you 521/502 errors. Flexible is the right setting for this architecture (Cloudflare owns HTTPS, the cluster stays simple).



BOUTIQUE_HOST=boutique.invincibledevops.tech ./scripts/deploy-boutique.sh
That creates the boutique namespace, deploys Online Boutique, and applies the HTTPRoute with your real hostname. Then verify:


kubectl get pods -n boutique            # frontend + microservices Running
kubectl get httproute -n boutique       # Accepted=True
Then test (in order)

# 1. Direct to the gateway (no DNS needed):
curl -H "Host: boutique.invincibledevops.tech" http://35.226.118.222/      # expect 200

# 2. WAF proof — SQLi must be blocked:
curl -H "Host: boutique.invincibledevops.tech" "http://35.226.118.222/?id=1'+OR+'1'='1"   # expect 403

# 3. Through Cloudflare once DNS propagates (1-2 min):
curl -I https://boutique.invincibledevops.tech

# 4. Full WAF suite:
./scripts/waf-test.sh https://boutique.invincibledevops.tech
Expect all 5 attack payloads in step 4 to return 403 — that's the Coraza dynamic module doing its job. Paste results and we'll finish the Phase 1 verification pass.



Hubble gives you real-time, per-request visibility into everything moving through your cluster's network — which pod talked to which pod, on what port, how much data, and whether it was allowed or blocked by policy — so you can answer "what just happened on my network?" without guessing, whether you're debugging an outage, validating that your NetworkPolicies/WireGuard encryption actually work (like our Phase 1.2 proof), or demonstrating east-west traffic patterns in a portfolio.


**How to prove encryption is working:**
```bash
# Deploy two test pods in different namespaces
kubectl create ns test-a
kubectl create ns test-b
kubectl run netshoot-a -n test-a --image=nicolaka/netshoot -- sleep 3600
kubectl run netshoot-b -n test-b --image=nicolaka/netshoot -- sleep 3600

# Capture traffic on the wire from the host
# If you SSH into a node, run:
sudo tcpdump -i cilium_wg0 -nn port 80

# Send unencrypted HTTP traffic from pod A to pod B
# The tcpdump on cilium_wg0 will show encrypted WireGuard packets, not plaintext HTTP
```

### 1.3 Deploy Envoy Gateway with Coraza WAF

> **Why not ingress-nginx anymore?** The community Ingress NGINX controller was
> **retired in March 2026** — no releases, no security fixes. Envoy Gateway is
> the actively maintained replacement: Gateway API-native, dynamic config
> pushed via xDS (no reloads), and the Coraza WAF (OWASP CRS) runs *inside* the
> Envoy process as a native dynamic module. See
> `kubernetes/legacy/` for the original ingress-nginx config.

```bash
# Install Envoy Gateway (installs the Gateway API CRDs too)
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.3 \
  --namespace envoy-gateway-system \
  --create-namespace

# Apply the Gateway API resources:
#   gatewayclass.yaml            -> points the class at Envoy Gateway + EnvoyProxy
#   envoyproxy.yaml              -> loads the Coraza dynamic module (image volume, needs K8s 1.35+)
#   gateway.yaml                 -> the front door (LoadBalancer)
#   waf-extensionpolicy.yaml     -> attaches Coraza + OWASP CRS to the Gateway
kubectl apply -f kubernetes/gateway/gatewayclass.yaml
kubectl apply -f kubernetes/gateway/envoyproxy.yaml
kubectl apply -f kubernetes/gateway/gateway.yaml
kubectl apply -f kubernetes/gateway/waf-extensionpolicy.yaml

# Wait for the Gateway to be accepted and get an external IP
kubectl wait --for=condition=Accepted gateway/boutique-gateway -n envoy-gateway-system
kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway -w
```

**What the WAF protects against (OWASP Core Rule Set):**
- SQL Injection (SQLi)
- Cross-Site Scripting (XSS)
- Local/Remote File Inclusion
- Command Injection
- Malicious bots and scrapers
- And 50+ other attack categories

### 1.4 Deploy Sample Microservices Application

Deploy the included e-commerce application or a microservices demo app:

```bash
# Deploy the Online Boutique microservices demo (Google's sample app)
kubectl create ns boutique
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/main/release/kubernetes-manifests.yaml -n boutique

# Create the HTTPRoute (the Gateway itself was created in 1.3)
# WAF protection comes from the EnvoyExtensionPolicy attached in 1.3 —
# no per-route annotations needed.
sed 's/boutique.example.dev/boutique.yourdomain.dev/' \
  kubernetes/gateway/httproute.yaml | kubectl apply -f -

# Verify the route is accepted
kubectl get httproute boutique-route -n boutique -o yaml | grep -A2 "conditions:" | head -5

# Configure Cloudflare DNS to point boutique.yourdomain.dev → Load Balancer IP
# Wait for DNS propagation, then verify WAF is active
curl -I https://boutique.yourdomain.dev
```

### 1.5 Security Validation: OWASP ZAP Scan

```bash
# Install OWASP ZAP (use Docker)
docker pull zaproxy/zap-stable

# Run baseline scan against your WAF-protected endpoint
docker run --rm zaproxy/zap-stable zap-baseline.py \
  -t https://boutique.yourdomain.dev \
  -r zap_report.html

# Run full active scan (more aggressive)
docker run --rm zaproxy/zap-stable zap-full-scan.py \
  -t https://boutique.yourdomain.dev \
  -r zap_full_report.html

# Verify WAF blocked malicious requests — check Envoy Gateway logs
kubectl logs -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=boutique-gateway | grep -i coraza

# Expected: coraza deny entries and 403 responses for blocked attacks
# Check the WAF policy is attached to the Gateway
kubectl get envoyextensionpolicy waf-extension -n envoy-gateway-system -o yaml
```

---

## Phase 2: Stateful Workloads & Observability (Week 2)

### 2.1 Deploy Highly Available PostgreSQL with CloudNativePG Operator

The CloudNativePG Operator manages PostgreSQL clusters natively on Kubernetes — handling leader election, synchronous replication, automated failover, and backups.

```bash
# Install CloudNativePG Operator
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml

# Wait for operator
kubectl wait --for=condition=available deploy/cnpg-controller-manager -n cnpg-system --timeout=300s

# Deploy HA PostgreSQL cluster
kubectl create ns database
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ha-postgres
  namespace: database
spec:
  instances: 3                    # 1 leader + 2 replicas
  imageName: ghcr.io/cloudnative-pg/postgresql:16

  # Synchronous replication — no data loss on failover
  postgresql:
    parameters:
      synchronous_commit: "on"
      synchronous_standby_names: "ANY 1 (ha-postgres-2,ha-postgres-3)"

  # Storage
  storage:
    size: 50Gi
    storageClass: premium-rwo     # SSD-backed

  # High Availability
  primaryUpdateStrategy: unsupervised
  primaryUpdateMethod: switchover

  # Automated backups to GCS
  backup:
    barmanObjectStore:
      destinationPath: "gs://devops-portfolio-backups/postgres"
      googleCredentials:
        applicationCredentials:
          secretName: gcs-credentials
          key: credentials.json
    retentionPolicy: "30d"

  # Monitoring
  monitoring:
    enablePodMonitor: true

  # Resource management
  resources:
    requests:
      memory: "1Gi"
      cpu: "1000m"
    limits:
      memory: "2Gi"
      cpu: "2000m"

  # Anti-affinity — spread across nodes/zones
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: cnpg.io/cluster
                operator: In
                values:
                  - ha-postgres
          topologyKey: "topology.kubernetes.io/zone"
EOF
```

**Key HA Configuration Explained:**
- `instances: 3` — One leader accepting writes, two replicas for read scaling and failover
- `synchronous_commit: on` — Leader waits for at least one replica to confirm writes before acknowledging to client. Prevents data loss.
- `podAntiAffinity` with `topologyKey: zone` — Each PostgreSQL instance runs in a different availability zone. A zone failure only takes down one instance.
- `primaryUpdateStrategy: unsupervised` — Automated failover; operator promotes healthiest replica to leader

### 2.1b Verified working procedure (trial cluster, 2026-08)

> ⚠️ The manifest above is the aspirational spec. The schema-correct, trial-fitted
> version that was actually verified on the free-trial cluster lives in
> `kubernetes/cnpg/postgres-cluster.yaml` — use that one. Differences: smaller
> resources (250m CPU requests — 1-vCPU nodes), 1 Gi storage on the default
> class instead of 50 Gi `premium-rwo`, corrected field names (see header of
> the file), and the backup secret referenced as `{name, key}`.

```bash
# 1. Install the operator — server-side apply with force-conflicts, because:
#    - client-side apply rejects the poolers CRD (annotation > 256 KB limit)
#    - server-side apply conflicts with earlier client-side ownership
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
# re-run if the connection drops mid-apply — idempotent. Verify ALL 6 CRDs
# landed (a drop can silently skip one, e.g. poolers):
kubectl get crd | grep cnpg

# 2. Verify the controller comes up (it crash-loops until every CRD exists):
kubectl get pods -n cnpg-system -w

# 3. Backup credentials — no JSON key. The cluster has Workload Identity
#    enabled (main.tf workload_identity_config), so barman (CNPG's backup
#    tool) uses the pod's default credentials: a dedicated GCS SA bound to
#    the namespace's `default` K8s SA:
gcloud iam service-accounts create pg-backup-sa \
  --display-name="CNPG GCS backups"
gcloud projects add-iam-policy-binding devops-portfolio-prod \
  --member="serviceAccount:pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"
gcloud storage buckets create gs://devops-portfolio-backups \
  --project=devops-portfolio-prod        # skip if it already exists

kubectl create ns database
kubectl annotate namespace database iam.gke.io/gke-metadata-server-enabled="true"
kubectl annotate serviceaccount default -n database \
  iam.gke.io/gcp-service-account=pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com
gcloud iam service-accounts add-iam-policy-binding \
  pg-backup-sa@devops-portfolio-prod.iam.gserviceaccount.com \
  --member="serviceAccount:devops-portfolio-prod.svc.id.goog[database/default]" \
  --role="roles/iam.workloadIdentityUser"

# 4. Deploy the cluster (schema-correct manifest in the repo — it must have
#    NO googleCredentials block, so barman falls back to the pod's
#    Workload Identity credentials above):
kubectl apply -f kubernetes/cnpg/postgres-cluster.yaml

# 5. Verify:
kubectl get pods -n database -o wide     # db-1 leader + db-2/db-3 replicas
kubectl get cluster -n database          # Phase: Ready
kubectl get pvc -n database              # 3x Bound
```

Gotchas that cost real time:
- **A flaky connection mid-apply can silently skip a CRD** — the controller then
  crash-loops with `no matches for kind "Pooler"`. Always verify the CRD count.
- **`kubectl get ... -o jsonpath='{.items[0].metadata.name}'` fails with "array
  index out of bounds" when the pods don't exist yet** — that's a race, not an
  error; re-run once the cluster is Ready.

### 2.2 Load Test the Database

#### Install pgbench

```bash
# Get leader pod
LEADER_POD=$(kubectl get pods -n database -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')

# Initialize pgbench (creates 100x scale test database)
kubectl exec -n database $LEADER_POD -- \
  pgbench -i -s 100 -U postgres app

# Run read/write load test for 5 minutes
kubectl exec -n database $LEADER_POD -- \
  pgbench -c 50 -j 4 -T 300 -P 10 -U postgres app
```

**Expected output interpretation:**
```
progress: 10.0 s, 1234.5 tps, lat 40.123 ms stddev 12.345
progress: 20.0 s, 1256.7 tps, lat 39.876 ms stddev 11.987
...
```

#### Automated Chaos + Load Test Script

Create a script that runs continuous load while killing the leader:

```bash
#!/bin/bash
# scripts/db-chaos-test.sh

NAMESPACE="database"
CLUSTER="ha-postgres"

echo "=== Starting continuous load test ==="
# Start pgbench in background
kubectl exec -n $NAMESPACE $(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}') -- \
  pgbench -c 20 -j 2 -T 600 -P 10 -U postgres app &
LOAD_PID=$!

sleep 30

echo "=== Killing leader pod ==="
LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod -n $NAMESPACE $LEADER --grace-period=0 --force

echo "=== Monitoring failover ==="
for i in $(seq 1 30); do
  NEW_LEADER=$(kubectl get pods -n $NAMESPACE -l cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
  STATUS=$(kubectl get cluster -n $NAMESPACE $CLUSTER -o jsonpath='{.status.phase}')
  echo "[$i] New leader: $NEW_LEADER | Cluster phase: $STATUS"
  sleep 2
done

echo "=== Failover complete ==="
wait $LOAD_PID
echo "=== Load test finished ==="
```

**Success criteria:** Zero failed transactions during the leader switchover. The operator handles the failover transparently, and synchronous replication ensures no committed data is lost.

### 2.2b Verified working procedure (trial cluster, 2026-08)

```bash
# 0. Prerequisite — the 1 Gi volumes in postgres-cluster.yaml are too small for
#    scale-100 data (~1.4 GB). Expand them in place first (CNPG auto-resizes
#    only when resizeInUseVolumes is set):
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"storage":{"size":"8Gi","resizeInUseVolumes":true}}}'
kubectl get pvc -n database -w          # volumes grow to 8Gi with no downtime

# 1. Initialize the benchmark data (scale 100 = 10M rows):
kubectl exec -n database ha-postgres-1 -- pgbench -i -s 100 -U postgres app
#    (re-running drops the old tables automatically — partial failed inits are safe)

# 2. Run the load test — note the database name "app" at the end:
kubectl exec -n database ha-postgres-1 -- \
  pgbench -c 50 -j 4 -T 300 -P 10 -U postgres app
```

**Verified result (1-vCPU leader):** 396.6 tps, 119,079 transactions, **0.000% failed**, avg latency 124.7 ms. TPS decays over the run as the single vCPU saturates — honest numbers for the hardware.

Gotchas that cost real time:
- **The benchmark database must be named** (`app` at the end) — omitting it runs pgbench against the `postgres` database, which has no tables (`relation "pgbench_branches" does not exist`).
- `pgbench -s 100` needs ~1.4 GB — the original 1 Gi volumes fail mid-init with `No space left on device`.

### 2.3 Deploy Observability Stack

#### Prometheus + Grafana with kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword="admin" \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false

# Port-forward Grafana
kubectl port-forward -n monitoring svc/monitoring-grafana 8080:80
# Access at http://localhost:8080 (admin/admin)
```

**Critical Grafana dashboards to configure:**
1. **PostgreSQL Overview** (CloudNativePG exports metrics automatically via PodMonitor)
   - Replication lag per replica
   - Transactions per second
   - Connection count
   - Cache hit ratio
   - WAL generation rate

2. **Kubernetes Cluster Health**
   - Node CPU/Memory/Disk
   - Pod restart counts
   - Network I/O per namespace

3. **WAF/Ingress Dashboard**
   - Request rate by status code
   - 403 responses (blocked attacks)
   - Latency percentiles (p50, p95, p99)

#### Datadog Integration (GitHub Student Pack)

```bash
# Get your Datadog API key from Datadog → Integrations → APIs
helm repo add datadog https://helm.datadoghq.com
helm repo update

helm upgrade --install datadog datadog/datadog \
  --namespace datadog \
  --create-namespace \
  --set datadog.apiKey="$DD_API_KEY" \
  --set datadog.site="datadoghq.com" \
  --set datadog.apm.enabled=true \
  --set datadog.logs.enabled=true \
  --set datadog.logs.containerCollectAll=true \
  --set datadog.processAgent.enabled=true \
  --set datadog.clusterAgent.enabled=true \
  --set datadog.clusterAgent.metricsProvider.enabled=true
```

**Why Datadog matters for your portfolio:** It's the monitoring platform used by thousands of enterprises. Having dashboards that show real-time database failover metrics and chaos experiment impact is far more impressive than just having Grafana running.

### 2.3c Datadog — verified procedure (trial cluster, 2026-08)

```bash
# 1. Account + API key (the only manual step):
#    sign up at app.datadoghq.com (GitHub Student Pack for free credits) →
#    Organization Settings → API Keys → New Key
export DD_API_KEY="<your-key>"

# 2. Install:
helm repo add datadog https://helm.datadoghq.com
helm repo update
helm upgrade --install datadog datadog/datadog \
  --namespace datadog --create-namespace \
  --set datadog.apiKey="$DD_API_KEY" \
  --set datadog.site="us5.datadoghq.com" \   # use YOUR account's site: datadoghq.com (US1),
                                              # us3/us5.datadoghq.com, datadoghq.eu (EU), ...
  --set datadog.apm.enabled=true \
  --set datadog.logs.enabled=true \
  --set datadog.logs.containerCollectAll=true \
  --set datadog.processAgent.enabled=true \
  --set datadog.clusterAgent.enabled=true \
  --set datadog.clusterAgent.metricsProvider.enabled=true \
  --set providers.gke.cos=true   # REQUIRED on GKE COS — the chart's official COS flag
                                 # (DataDog/helm-charts PR #872): stops the system-probe
                                 # from mounting /usr/src, which fails on COS's read-only
                                 # /usr with "CreateContainerError: mkdir /usr/src:
                                 # read-only file system". Neither systemProbe.enabled
                                 # nor discovery.enabled=false removes the container —
                                 # this flag fixes the mount itself.

# 3. Verify:
kubectl get pods -n datadog    # datadog-agent-* (DaemonSet, one per node) + cluster agent
# then in the UI: Infrastructure → Host Map — the 6 nodes appear within minutes
```

Trial notes:
- **Resource footprint:** the agent is the heaviest component on this cluster (DaemonSet per node + cluster agent, on 1-vCPU/4 GB nodes already running boutique + Postgres + observability). If pods start going Pending, the first trim is `--set datadog.processAgent.enabled=false` (CPU-hungriest, least essential for the demo).
- **Private nodes:** agent egress goes through the Cloud NAT — nothing to configure.
- **The payoff:** re-run the §2.4 failover demo while watching Datadog's host/database views — live failover metrics on an enterprise platform.

Three bugs hit on install (all fixed in the command above):
- **Empty API key secret** — if `$DD_API_KEY` is unset at install time, the chart writes an empty key and every agent runs unauthenticated. This is SILENT: pods look healthy, Datadog just never receives anything. Verify with `kubectl exec <agent-pod> -- agent status | grep -i "API key"` — and/or write the key straight into the secret: `kubectl create secret generic datadog-api-key -n datadog --from-literal=api-key=<KEY> --dry-run=client -o yaml | kubectl apply -f -`.
- **Site mismatch** — Datadog accounts are region-specific. If your key is rejected (`API key ending with ...: API Key invalid`), the account is on a different site than `datadoghq.com` — check the URL after login (us3/us5/datadoghq.eu) and set `datadog.site` to match (e.g. `us5.datadoghq.com`).
- **system-probe fails on GKE COS** — `failed to mkdir "/usr/src": read-only file system`. GKE's Container-Optimized OS keeps kernel paths read-only, so `datadog.systemProbe.enabled=false` is required on GKE (loses eBPF network/security monitoring only — metrics, APM, logs, host map all work).

### 2.3b Verified observability workflow (trial cluster, 2026-08)

The complete, verified sequence from fresh install to live WAF dashboard. Every bug found along the way is baked out of these commands — copy, paste, done.

```bash
# ── 1. Install the stack (the two selector flags matter: they make
#      Prometheus pick up ALL PodMonitors/ServiceMonitors, incl. CNPG's) ──
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword="admin" \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
kubectl get pods -n monitoring      # prometheus + operator + grafana Running

# ── 2. Enable CNPG's built-in PodMonitor (off by default in our cluster spec) ──
kubectl patch cluster -n database ha-postgres --type=merge \
  -p '{"spec":{"monitoring":{"enablePodMonitor":true}}}'
kubectl get podmonitor -A | grep -i cnpg

# ── 3. PostgreSQL dashboard: Grafana → Dashboards → Import → ID 20417 → Prometheus ──

# ── 4. Envoy proxy metrics pipeline ──
#    Port 19001 is Envoy Gateway's METRICS listener (the classic 19000 admin
#    port is not exposed). The Service MUST carry the selector labels, or the
#    ServiceMonitor matches the wrong Service (the controller's) and every
#    target goes down.
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: envoy-admin-metrics
  namespace: envoy-gateway-system
  labels:                                # required — SM selector matches on these
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
EOF

kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: envoy-metrics
  namespace: envoy-gateway-system
  labels:                                # required — Prometheus selects SMs by release label
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
EOF

# ── 5. Verify the pipeline before touching Grafana ──
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# open http://localhost:9090/targets → search "envoy" → target must be UP
# (address 10.1.x.x:19001). Generate traffic so the panels have data:
curl -s https://boutique.invincibledevops.tech/ > /dev/null
./scripts/waf-test.sh https://boutique.invincibledevops.tech/

# ── 6. WAF/Ingress dashboard: Grafana → New → Import → paste JSON ──
#    Use datasource UID "prometheus" (not the ${DS_PROMETHEUS} placeholder —
#    the import dialog can silently leave it unbound). Three panels:
```

**Panel queries (the verified set — metric names that actually exist in EG v1.8):**

| Panel | PromQL |
|---|---|
| Request rate by status code | `sum(rate(envoy_http_downstream_rq_xx[5m])) by (envoy_response_code_class)` |
| 403s blocked (WAF) | `sum(rate(envoy_http_downstream_rq_xx{envoy_response_code_class="4",envoy_http_conn_manager_prefix="http-10080"}[5m]))` |
| Latency p50 / p95 / p99 | `histogram_quantile(0.50, sum(rate(envoy_http_downstream_rq_time_bucket[5m])) by (le))` (swap `0.50` → `0.95` → `0.99`) |

**Gotchas that cost real time (each one is a real bug in this chain):**
1. **Port 19001, not 19000** — EG v1.8 exposes the metrics listener on 19001; the classic admin port isn't a container port. A Service pointing at 19000 registers a target that's never up.
2. **The Service needs the selector labels** — without `app.kubernetes.io/name=envoy`, the ServiceMonitor latches onto the controller's Service instead (its ports don't serve `/stats/prometheus` → all targets down, "No data").
3. **The ServiceMonitor needs `release: monitoring`** — kube-prometheus-stack's Prometheus selects SMs by that label; an unlabeled SM never gets a scrape job (check: `prometheus.yml` in the config has no `envoy-metrics` job).
4. **Tighten the SM selector to `component: proxy`** — otherwise the controller's Service (which also carries `app.kubernetes.io/name=envoy`) joins the pool with dead targets.
5. **Datasource UID** — import with the literal UID `prometheus`, not `${DS_PROMETHEUS}` (provisioned datasource: `monitoring-kube-prometheus-grafana-datasource` ConfigMap).
6. **`envoy_http_downstream_rq_403` does not exist** — EG disables per-code counters; the 4xx class on the data-plane listener (`http-10080`) is the WAF's 403 proxy.
7. **Expected noise:** the `coredns` target is always `down` on GKE (kube-dns doesn't expose 9153) — ignore it.

### 2.4 Database Failover Validation

```bash
# 1. Start a continuous write workload
# In one terminal:
kubectl exec -n database $LEADER_POD -- \
  bash -c "while true; do psql -U postgres -d app -c \"INSERT INTO pgbench_history VALUES (generate_series(1,1000));\" 2>&1; sleep 1; done" > write_log.txt &

# 2. In another terminal, delete the leader
kubectl delete pod -n database $LEADER_POD

# 3. Watch the failover in real-time in Datadog/Grafana
# 4. Check write_log.txt for any errors:
grep -c "ERROR\|FATAL" write_log.txt
# Expected: 0 or very few (transient, auto-retried)
```

**Portfolio documentation:** Capture screenshots or a short video showing:
- Grafana dashboard during failover (TPS drops to ~0 briefly, then recovers)
- Datadog traces showing the failover event
- Log output showing zero permanent errors
- New leader pod logs showing promotion

### 2.4b Verified working procedure (trial cluster, 2026-08)

```bash
# Terminal A — watch the primary flip in real time:
kubectl get cluster -n database -w          # watch the PRIMARY column

# Terminal B — kill the current primary (graceful delete, no --force):
PRIMARY=$(kubectl get cluster -n database -o jsonpath='{.status.primary}')
kubectl delete pod -n database $PRIMARY

# Terminal C (optional) — keep writes flowing through the failover:
kubectl exec -n database ha-postgres-1 -- \
  pgbench -c 10 -j 2 -T 120 -P 5 -U postgres app

# Verify after:
kubectl get cluster -n database -o wide     # PRIMARY flipped, Phase: healthy
kubectl describe cluster -n database        # Current/Target Primary, Timeline ID bumped
```

**What happens:** the operator elects a new primary within seconds (`Target Primary` timestamp), runs a `join` job for the replacement instance, and the cluster returns to healthy with all 3 instances. Verified: PRIMARY `ha-postgres-3` → deleted → PRIMARY `ha-postgres-1`, timeline 3, `Cluster in healthy state`.

**Bonus — the auto-failover story:** CNPG also fails over *by itself* when the leader gets unhealthy. During the 50-client load test, the 1-vCPU leader failed its readiness probes and the operator fired an automatic failover mid-run — with **0 failed transactions** in the final pgbench report. That's the zero-downtime claim, proven under load without touching anything.

Gotchas:
- **zsh does not treat `#` as a comment** — inline comments in pasted commands break them (`pods "#" not found`). Put comments on their own line or drop them.
- The operator recreates deleted instances automatically — `--force` deletion is not needed (and skips the graceful shutdown/switchover dance).

---

## Phase 3: AI Model Serving & Event-Driven Autoscaling (Week 3)

> **⚠️ Trial-account constraint:** the free trial cannot attach GPUs (GPU
> creation requires a quota increase, which trials are denied). This project
> therefore runs AI inference **on CPU**: small quantized models (e.g.
> llama-3.2-3b, phi-3-mini, qwen2.5-3b) served by Ollama on the application
> pool (e2-custom-1-4096 nodes — 1 vCPU / 4 GB each; a 3B Q4 model needs
> ~2–3 GB, so it runs on one dedicated node at a time). The KEDA
> scaling concepts (queue depth → replicas → scale-to-zero) are identical;
> only the GPU telemetry section changes — skip 3.1's DCGM parts or monitor
> CPU/utilization metrics instead. The GPU node pool remains available in
> `main.tf` (enable_gpu_pool = true) for a post-trial upgrade.

### 3.1 Deploy NVIDIA GPU Operator & DCGM Exporter

The NVIDIA GPU Operator manages GPU drivers and the DCGM Exporter on your GPU nodes, exposing GPU metrics that KEDA can use for scaling decisions.

```bash
# Add NVIDIA Helm repo
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Install GPU Operator
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set driver.enabled=false \          # GKE provides GPU drivers
  --set toolkit.enabled=true \
  --set dcgm.enabled=true \
  --set dcgmExporter.enabled=true \
  --set dcgmExporter.serviceMonitor.enabled=true

# Verify GPU nodes are recognized
kubectl describe nodes -l cloud.google.com/gke-accelerator | grep nvidia
# Expected: nvidia.com/gpu: 1
```

### 3.2 Deploy Ollama for LLM Inference

```bash
kubectl create ns ai-inference

# Deploy Ollama with GPU support
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ai-inference
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      nodeSelector:
        cloud.google.com/gke-accelerator: "nvidia-l4"
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: ollama
        image: ollama/ollama:latest
        ports:
        - containerPort: 11434
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "24Gi"
            cpu: "6"
          requests:
            nvidia.com/gpu: 1
            memory: "16Gi"
            cpu: "4"
        volumeMounts:
        - name: models
          mountPath: /root/.ollama
        env:
        - name: OLLAMA_KEEP_ALIVE
          value: "24h"    # Keep model in VRAM to avoid cold starts
        - name: OLLAMA_NUM_PARALLEL
          value: "4"
        readinessProbe:
          httpGet:
            path: /
            port: 11434
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: models
        emptyDir:
          sizeLimit: 50Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ai-inference
spec:
  selector:
    app: ollama
  ports:
  - port: 11434
    targetPort: 11434
  type: ClusterIP
EOF

# Pull a model (e.g., Llama 3.2 3B — lightweight for L4 GPU)
kubectl exec -n ai-inference deploy/ollama -- ollama pull llama3.2:3b

# Test inference
kubectl exec -n ai-inference deploy/ollama -- \
  curl -s http://localhost:11434/api/generate -d '{
    "model": "llama3.2:3b",
    "prompt": "Explain Kubernetes operators in one paragraph.",
    "stream": false
  }' | jq .response
```

### 3.3 Set Up Inference Queue with Redis

For advanced scaling, we need a queue to buffer incoming inference requests:

```bash
# Deploy Redis with Sentinel for HA
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ai-inference
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ai-inference
spec:
  selector:
    app: redis
  ports:
  - port: 6379
---
# Deploy API gateway that enqueues requests
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inference-api
  namespace: ai-inference
spec:
  replicas: 2
  selector:
    matchLabels:
      app: inference-api
  template:
    metadata:
      labels:
        app: inference-api
    spec:
      containers:
      - name: api
        image: python:3.12-slim
        command: ["/bin/bash", "-c"]
        args:
          - |
            pip install flask redis &&
            cat > /app.py << 'PYEOF'
            from flask import Flask, request, jsonify
            import redis, json, uuid
            app = Flask(__name__)
            r = redis.Redis(host='redis.ai-inference.svc.cluster.local', port=6379)

            @app.route('/infer', methods=['POST'])
            def infer():
                data = request.json
                task_id = str(uuid.uuid4())
                task = json.dumps({'id': task_id, 'prompt': data['prompt']})
                r.lpush('inference_queue', task)
                return jsonify({'task_id': task_id, 'status': 'queued'})

            @app.route('/result/<task_id>')
            def result(task_id):
                res = r.get(f'result:{task_id}')
                if res:
                    return jsonify(json.loads(res))
                return jsonify({'status': 'processing'}), 202

            @app.route('/health')
            def health():
                return jsonify({
                    'status': 'ok',
                    'queue_length': r.llen('inference_queue')
                })

            app.run(host='0.0.0.0', port=8080)
            PYEOF
            python /app.py
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: inference-api
  namespace: ai-inference
spec:
  selector:
    app: inference-api
  ports:
  - port: 8080
```

### 3.4 Install KEDA for Event-Driven Autoscaling

KEDA (Kubernetes Event-driven Autoscaling) is the CNCF project that enables scaling based on external metrics — perfect for queue depth and GPU utilization.

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace
```

### 3.5 Configure KEDA Scaler for GPU Utilization

```yaml
# keda/gpu-scaler.yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: ollama-gpu-scaler
  namespace: ai-inference
spec:
  scaleTargetRef:
    name: ollama
  pollingInterval: 15
  cooldownPeriod: 300    # 5 minutes before scaling down (avoids thrashing)
  minReplicaCount: 1
  maxReplicaCount: 4
  triggers:
  # Scale based on GPU utilization (DCGM metric via Prometheus)
  - type: prometheus
    metadata:
      serverAddress: http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
      metricName: dcgm_gpu_utilization
      threshold: "70"           # Scale up when GPU > 70%
      query: |
        avg(DCGM_FI_DEV_GPU_UTIL{exported_pod=~"ollama.*"})
  # Scale based on inference queue depth
  - type: redis
    metadata:
      address: redis.ai-inference.svc.cluster.local:6379
      listName: inference_queue
      listLength: "10"          # Scale up when queue has 10+ pending requests
```

### 3.6 GPU Load Test & Autoscaling Validation

```bash
# Script to saturate the inference queue
# scripts/gpu-load-test.sh

#!/bin/bash
echo "=== Submitting 100 inference requests ==="
for i in $(seq 1 100); do
  kubectl run --rm -n ai-inference --restart=Never --image=curlimages/curl -it -- \
    curl -s -X POST http://inference-api:8080/infer \
    -H "Content-Type: application/json" \
    -d "{\"prompt\": \"Write a detailed essay about cloud-native infrastructure. Be thorough, include examples, and make it at least 500 words.\"}" &
done
wait

echo "=== Monitoring KEDA scaler ==="
watch -n 5 "kubectl get hpa -n ai-inference && kubectl get pods -n ai-inference"

# Check GPU metrics in DCGM Exporter
kubectl port-forward -n gpu-operator svc/gpu-operator-dcgm-exporter 9400:9400 &
curl http://localhost:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
```

**Success criteria:**
- When queue depth exceeds 10, KEDA triggers HPA to increase `ollama` replicas
- New pods spin up on GPU nodes (auto-provisioned by cluster autoscaler if needed)
- GPU utilization stays below 90% with multiple replicas sharing the load
- When queue drains, replicas scale down after cooldown period
- **Scale-to-zero:** If queue is empty for cooldown period, pods scale to zero (and GPU nodes scale to zero), saving costs

### 3.7 Advanced: Serve via Gateway with WAF

The same Gateway from Phase 1.3 protects the AI service — WAF rules are
cluster-wide via the `EnvoyExtensionPolicy`, so no per-route annotations.

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ai-route
  namespace: ai-inference
spec:
  parentRefs:
    - name: boutique-gateway
      namespace: envoy-gateway-system
  hostnames:
    - ai.yourdomain.dev
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: inference-api
          port: 8080
EOF
```

### 3.8 Verified AI procedure — CPU variant (trial cluster, 2026-08)

> ⚠️ The sections above assume GPUs (GPU operator, DCGM, GPU scaler). The free
> trial cannot attach GPUs, so everything here runs on **CPU**: a small
> quantized model (llama3.2:3b Q4 ≈ 2 GB) served by Ollama on the app pool.
> **KEDA works identically on CPU** — scaling is metric-driven, not
> GPU-driven; the only change is the scaler source (Redis queue length
> instead of DCGM GPU utilization). KEDA's operator is a normal CPU pod.

**1. Node sizing — the prerequisite (this is where the real fight was):**

1-vCPU app nodes were structurally CPU-starved: GKE daemonsets (cilium,
kube-proxy, fluentbit, netd, …) take ~0.5 vCPU per node, and with boutique +
Postgres + Datadog + monitoring the allocatable hit 98% — **nothing could
schedule, not even a 100m request**. The 4 GB RAM also OOM-killed Ollama on
model load (exit 137). Final sizing in `infra/terraform/terraform.tfvars`:
`application_machine_type = "e2-custom-2-8192"` (2 vCPU / 8 GB), max 3 app
nodes → 3×2 + 3×1 = 9 vCPU ≤ 12 global cap, 6 instances ≤ 8.

**2. Ollama (CPU)** — `kubernetes/ai/ollama-deployment.yaml`:

```bash
kubectl apply -f kubernetes/ai/ollama-deployment.yaml
kubectl exec -n ai-inference deploy/ollama -- ollama pull llama3.2:3b
kubectl exec -n ai-inference deploy/ollama -- ollama run llama3.2:3b "Say hello in five words."
```

Key values: requests 100m/1Gi, limits 1 CPU/4 Gi, `OLLAMA_NUM_PARALLEL=1`
(4 parallel on 1-2 vCPU = thrash), emptyDir for models (per-pod — re-pull
after pod recreation). Expect ~2-5 tok/s on CPU — the demo is the scaling,
not the speed.

**3. Queue + API** — `kubernetes/ai/redis-inference-api.yaml`:

```bash
kubectl apply -f kubernetes/ai/redis-inference-api.yaml
kubectl exec -n ai-inference deploy/inference-api -- python -c \
  "import urllib.request; print(urllib.request.urlopen('http://localhost:8080/health').read().decode())"
kubectl exec -n ai-inference deploy/inference-api -- python -c \
  "import urllib.request, json; req=urllib.request.Request('http://localhost:8080/infer', data=json.dumps({'prompt':'What is Kubernetes?'}).encode(), headers={'Content-Type':'application/json'}); print(urllib.request.urlopen(req).read().decode())"
kubectl exec -n ai-inference deploy/redis -- redis-cli llen inference_queue
```

**4. KEDA — CPU/queue scaler** (installs as a normal pod; scale source is the
Redis list length):

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl get pods -n keda -w                  # keda-operator Running
```

**5. Worker + ScaledObject** (the scaling demo):

```bash
kubectl apply -f kubernetes/ai/queue-worker.yaml     # pops Redis → calls Ollama
kubectl apply -f kubernetes/ai/scaledobject.yaml     # queue length → ollama 0..3

# the load test — push 20 jobs, watch it scale up, drain, scale to zero:
for i in $(seq 1 20); do
  kubectl exec -n ai-inference deploy/inference-api -- python -c \
    "import urllib.request, json; req=urllib.request.Request('http://localhost:8080/infer', data=json.dumps({'prompt':'What is Kubernetes? job $i'}).encode(), headers={'Content-Type':'application/json'}); urllib.request.urlopen(req)"
done
kubectl get deploy ollama -n ai-inference -w     # 0 → 1 → ... → 3 replicas
kubectl get hpa -n ai-inference                  # KEDA's HPA: current/target
# after the queue drains + cooldown (60s): back to 0 — scale-to-zero proven
```

Behavior: queue length > 0 wakes Ollama (scale from 0); length ≥ 5 = full
target (3 replicas); empty for 60s cooldown → scales back to 0.

**Gotchas from the trenches:**
- **Slim images have no curl** (ollama, python:3.12-slim) — use `ollama run`
  in the pod or Python's `urllib`; port-forwards can silently hit a *local*
  Ollama on your laptop (`lsof -i :11434` before debugging).
- **Strategic-merge `kubectl patch` can fail** with `image: Required value`
  when the OpenAPI schema fetch stalls (this network) — it falls back to
  list-replacement; use `--type=json` patches or just `kubectl apply -f`
  the edited manifest instead.
- **Node pool updates at the instance-quota cap are slow** — no surge
  possible, so GKE drains/replaces nodes sequentially; PDBs add hours
  (`NODE_PDB_DELAY_SECONDS`). A 30-min terraform timeout ≠ failure: check
  `gcloud container operations list --filter="status=RUNNING"` and
  `gcloud container operations wait <OP_ID> --region us-central1`.
- **CPU requests are the scheduler's currency on small nodes** — a 500m
  request is half a node; "Insufficient cpu" means ask for less or add vCPU.

---

## Phase 4: Chaos Engineering & Resilience Validation (Week 4)

### 4.1 Install Chaos Mesh

Chaos Mesh is a CNCF project that provides a web UI and CRD-based chaos experiment definitions.

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update

helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.create=true

# Access Chaos Mesh dashboard
kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333
# Open http://localhost:2333
```

### 4.2 Define Steady-State Hypothesis

Before running chaos, define what "normal" looks like:

```yaml
# chaos/steady-state-check.yaml
# This is a manual/semi-automated validation — you check these metrics
# before, during, and after each chaos experiment.

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
    gpu_utilization: "< 85% (with autoscaling)"
    cold_start_time: "< 60s"
```

### 4.3 Chaos Experiment 1: Pod Kill

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
  scheduler:
    cron: "@every 30m"       # Run every 30 minutes
```

**Observation during experiment:**
```bash
# Monitor app health
watch -n 2 "kubectl get pods -n boutique && echo '---' && curl -s -o /dev/null -w '%{http_code}' https://boutique.yourdomain.dev"

# Monitor HPA
kubectl get hpa -n boutique -w

# View in Datadog: APM traces showing retries + recovery
```

### 4.4 Chaos Experiment 2: Network Latency Injection

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
  direction: both
```

**What to observe:**
- PostgreSQL sync replication handles the latency gracefully
- Application connection pools automatically retry
- Read replicas maintain consistent lag (monitor in Grafana)
- After experiment ends, replication catches up fully within seconds

### 4.5 Chaos Experiment 3: CPU Stress on AI Node

```yaml
# chaos/cpu-stress-gpu.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: gpu-node-cpu-stress
  namespace: chaos-mesh
spec:
  mode: one
  selector:
    labelSelectors:
      role: gpu
  stressors:
    cpu:
      workers: 6
      load: 90              # 90% CPU stress
  duration: "180s"
```

**What to observe:**
- GPU utilization metrics from DCGM Exporter remain unaffected (CPU stress ≠ GPU stress)
- CPU throttling may slow down the API gateway but not inference
- KEDA may scale API pods to other nodes if CPU becomes bottleneck
- After experiment: all metrics return to baseline

### 4.6 Chaos Experiment 4: Node Failure Simulation

```yaml
# chaos/node-drain.yaml
# This simulates a zone failure by draining a node

# Manual approach (more realistic):
# 1. Identify a node with database/application pods
NODE_TO_DRAIN=$(kubectl get nodes -l role=application -o jsonpath='{.items[0].metadata.name}')

# 2. Cordon and drain
kubectl cordon $NODE_TO_DRAIN
kubectl drain $NODE_TO_DRAIN --ignore-daemonsets --delete-emptydir-data

# 3. Observe:
#    - Pods reschedule to other nodes
#    - Database replica (if affected) catches up from WAL
#    - Application traffic shifts to remaining replicas

# 4. Restore:
kubectl uncordon $NODE_TO_DRAIN
```

### 4.7 Chaos Experiment: Malicious Traffic / WAF Test

```bash
# Run OWASP ZAP full scan while chaos is active
# This validates that WAF protection holds even under degraded infrastructure

docker run --rm -v $(pwd):/zap/wrk zaproxy/zap-stable zap-full-scan.py \
  -t https://boutique.yourdomain.dev \
  -r chaos_zap_report.html

# Or use custom attack script
# scripts/waf-chaos-test.sh
#!/bin/bash

ATTACKS=(
  "1' OR '1'='1"                           # SQLi
  "<script>alert('xss')</script>"          # XSS
  "../../../etc/passwd"                     # Path traversal
  "; cat /etc/passwd"                       # Command injection
  "' UNION SELECT * FROM users--"          # SQL UNION injection
)

for attack in "${ATTACKS[@]}"; do
  echo "Testing: $attack"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -G --data-urlencode "q=$attack" \
    "https://boutique.yourdomain.dev/search")
  if [ "$HTTP_CODE" = "403" ]; then
    echo "  ✓ Blocked by WAF"
  else
    echo "  ✗ WARNING: Got $HTTP_CODE — WAF may not be configured correctly"
  fi
done
```

### 4.8 Final Portfolio Documentation

For each chaos experiment, document:

1. **Steady-state metrics before experiment**
2. **Experiment definition** (YAML + description)
3. **Observed behavior during experiment**
   - Screenshots of Grafana/Datadog dashboards
   - Log excerpts showing failover/recovery
   - HTTP status code timeline
4. **Recovery time and data integrity verification**
5. **Lessons learned and architectural improvements**

### 4.9 Verified chaos procedure (trial cluster, 2026-08)

The manifests in `chaos/` are the verified, apply-able versions. Every
"aspirational" version in the sections above failed for a concrete reason —
the fixes are baked into the files:

```bash
kubectl apply -f chaos/steady-state-check.yaml     # §4.2 hypothesis as a ConfigMap (was plain YAML, not a manifest)
kubectl apply -f chaos/pod-kill-app.yaml           # PodChaos — kill 50% of boutique frontends for 60s
kubectl apply -f chaos/network-delay-db.yaml       # NetworkChaos — 500ms latency on Postgres for 120s
kubectl apply -f chaos/cpu-stress-ai.yaml          # StressChaos — 90% CPU on Ollama for 180s
chmod +x chaos/node-drain.sh                       # zone-failure simulation (cordon + drain), NOT a manifest
# node drain is an operational script, run it directly:
./chaos/node-drain.sh                              # (restore: kubectl uncordon <node>)

# experiment state:
kubectl get podchaos,networkchaos,stresschaos -n chaos-mesh
kubectl get <kind> <name> -n chaos-mesh -o jsonpath='{.status.experiment.phase}'   # Injecting → Running → Finished
```

**Why each file looks the way it does (the gotchas):**
- **No `scheduler` field in PodChaos** — the installed Chaos Mesh CRD version
  rejects `spec.scheduler` (admission webhook: unknown field). The accepted
  fields are `action, containerNames, duration, gracePeriod, mode,
  remoteCluster, selector, value`. `duration` still makes the kill ongoing.
- **Netem `direction: both` requires `targets`** — the NetworkChaos webhook
  rejects `both`/`from` with an empty `targets` list. Use `direction: to`
  (delay traffic arriving at the selected pods — the desired semantics).
- **StressChaos targeting `role: gpu` matches nothing** — the trial has no
  GPU nodes, so the stress injects into no pods. The verified variant
  stresses the **Ollama** pod (`app: ollama` in ai-inference), which doubles
  as an autoscaling validation: CPU stress → inference degrades → queue
  grows → KEDA compensates.
- **Non-manifests in a `.yaml` costume** — `node-drain.sh` (cordon+drain is
  an operational script) and `steady-state-check.yaml` (a hypothesis, now a
  ConfigMap so it applies cleanly).

**Validation methodology (the §4.2 loop that works):** baseline → inject →
measure during → measure after → compare against the hypothesis.

```bash
# availability sampling during pod-kill (expect 200s with a few 503s in the window):
for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" https://boutique.invincibledevops.tech/; sleep 2; done | sort | uniq -c

# network-delay proof — pgbench latency delta ≈ the injected 500ms:
kubectl exec -n database ha-postgres-1 -- pgbench -c 5 -T 20 -U postgres app | grep -E "latency average|tps"
# (run once BEFORE the experiment as the baseline, once DURING)

# cpu-stress proof — ollama CPU pinned + KEDA compensating:
kubectl top pods -n ai-inference
kubectl get hpa -n ai-inference

# node-drain proof — live failover:
kubectl get cluster -n database -w        # PRIMARY flips when its node drains
```

The Grafana dashboards from §2.3 are the "during" evidence layer (latency
spikes, failover curves); `steady-state-check.yaml` is the yardstick for the
before/after comparison.

---

## Advanced Extensions

Once you've completed the core 4-week project, these extensions will deepen your expertise:

### Extension A: Multi-Cloud Database Replication
- Deploy PostgreSQL leader in GCP, read replica in DigitalOcean ($200 student credit)
- Configure cross-cloud replication with TLS
- Run chaos tests that sever the inter-cloud link, then restore it
- **Learning:** Multi-cloud architectures, WAN replication latency, split-brain prevention

### Extension B: GitOps with ArgoCD
- Replace `helm install` / `kubectl apply` with GitOps
- Store all manifests in a Git repository
- ArgoCD automatically syncs cluster state to match Git
- Implement promotion pipelines (staging → production via Git branches)
- **Learning:** GitOps patterns, declarative cluster management, drift detection

### Extension C: Advanced mTLS with SPIFFE/SPIRE
- Go beyond WireGuard encryption
- Issue cryptographic identities to each workload via SPIFFE/SPIRE
- Configure Istio Ambient Mesh or Cilium's native mTLS
- Prove with packet captures that every pod-to-pod call is encrypted with workload-specific certificates
- **Learning:** Zero-trust networking, identity-based security, service mesh architecture

### Extension D: Multi-Model AI Serving with Model Routing
- Serve multiple models (Llama, Mistral, Stable Diffusion)
- Implement model-aware routing in the API gateway
- Different scaling policies per model based on popularity
- Model pre-warming strategy for frequently used models
- **Learning:** Advanced KEDA configurations, traffic routing, GPU resource optimization

### Extension E: FinOps Dashboard
- Build a real-time cost dashboard using GCP Billing Export to BigQuery
- Visualize cost per namespace, per workload, per environment
- Track spot VM interruptions and correlate with application errors
- Set up anomaly detection for cost spikes
- **Learning:** Cloud financial operations, BigQuery, cost attribution

### Extension F: Full Disaster Recovery Drill
- Simulate entire region/zone failure
- Restore PostgreSQL from backup to a fresh cluster
- Validate RPO (Recovery Point Objective) and RTO (Recovery Time Objective)
- Automate the entire DR process with a runbook
- **Learning:** Backup/restore pipelines, DR planning, automation

---

## GitHub Student Pack Benefits Mapping

| Pack Benefit | Used In | Phase | Value |
|---|---|---|---|
| **Namecheap .me domain** | Cloudflare DNS + GCP Organization | Phase 0 | ~$12/yr |
| **Name.com .dev/.app domain** | Alternative domain option | Phase 0 | ~$15/yr |
| **DigitalOcean $200 credit** | Secondary K8s cluster for multi-cloud replication | Extension A | $200 |
| **Microsoft Azure $100 credit** | AKS cluster or Azure OpenAI for AI models | Extension A/Phase 3 | $100 |
| **Datadog Pro (10 servers)** | Enterprise monitoring & APM | Phase 2 | ~$150/mo value |
| **GitHub Copilot Pro** | Accelerated IaC/manifest writing | All phases | ~$10/mo |
| **Termius Pro** | SSH client for node debugging | All phases | ~$10/mo |
| **.TECH Domains** | Alternative professional domain | Phase 0 | ~$35/yr |
| **GitHub Pages** | Portfolio documentation site | Documentation | Free hosting |

**Total student benefits leveraged: ~$600+ in value**

---

## Reproduction Order (from scratch)

The single ordered checklist for rebuilding this environment end-to-end. Each
step points at the verified procedure (the "Xb" sections and files that were
actually proven on the trial cluster).

1. **Phase 0 — Foundation** → README §0 + `docs/tutorial-phase0-phase1.md` §1:
   domain/Cloudflare (SSL **Flexible**), GCP org/project, APIs, service account
   (**including `roles/storage.admin`**), state bucket, and the impersonation
   login (`gcloud auth application-default login --impersonate-service-account=...`)
   for every terraform command — no JSON key anywhere.
2. **Cluster** → `infra/terraform/` (`backend.hcl` init, `plan/apply` with
   `-var-file=terraform.tfvars`). Fresh clusters get GKE ≥ 1.35.5
   automatically via `min_master_version`. Verify: 3 system + 3 app nodes,
   one per AZ, ~6/12 vCPU, 6/8 instances.
3. **Cilium** → `./scripts/install-cilium.sh` (values carry all three fixes:
   `cni.binPath`, `ipv4NativeRoutingCIDR /8`, version 1.16.19). Verify:
   `cilium status` (Encryption: Wireguard), `cilium-dbg encrypt status`,
   and the WireGuard proof (`kubernetes/cilium/encryption-test.yaml`).
4. **Envoy Gateway** → `./scripts/install-envoy-gateway.sh` + the four
   manifests in `kubernetes/gateway/`. Verify: LB external IP →
   Cloudflare A record (proxied) + SSL mode **Flexible**.
5. **Application** → `BOUTIQUE_HOST=boutique.yourdomain.dev ./scripts/deploy-boutique.sh`,
   then `./scripts/waf-test.sh` (5/5 → 403) and `./scripts/zap-scan.sh`.
   *Steps 2–5 alternative: `./scripts/phase1-deploy.sh all`.*
6. **Phase 2** → §2.1b (CNPG operator + cluster), §2.2 (pgbench load test),
   §2.3b (observability stack + dashboards), §2.3c (Datadog), §2.4 (failover).
7. **Phase 3** → §3.8 (CPU AI: ollama deployment, queue + API, KEDA, worker,
   ScaledObject — all files in `kubernetes/ai/`).
8. **Phase 4** → §4.9 (chaos: apply the five artifacts in `chaos/`, run
   `./chaos/node-drain.sh` for the drain demo, validate with the §4.2 loop).
9. **Verify end-state** → quotas (6/12 vCPU, 6/8 instances, 2/4 addresses),
   Grafana dashboards populated, Datadog hosts visible, site up behind
   Cloudflare.

## Cleanup & Cost Controls

### Project Isolation Strategy

Since you're using a Google Cloud Organization (not a personal account), you can create separate projects for each phase and destroy them when done:

```bash
# Phase 1 project
gcloud projects create devops-phase1-infra
# When done:
gcloud projects delete devops-phase1-infra

# Phase 2 project
gcloud projects create devops-phase2-stateful
# When done:
gcloud projects delete devops-phase2-stateful
```

This prevents orphaned resources from silently consuming your credits.

### Shutdown Script

```bash
#!/bin/bash
# scripts/emergency-cleanup.sh

echo "=== EMERGENCY CLEANUP ==="
echo "This will delete ALL GKE clusters and node pools"

# Scale all node pools to 0
for cluster in $(gcloud container clusters list --format='value(name)'); do
  for pool in $(gcloud container node-pools list --cluster=$cluster --region=us-central1 --format='value(name)'); do
    gcloud container clusters resize $cluster --node-pool=$pool --num-nodes=0 --region=us-central1 --quiet
  done
done

# List remaining resources
echo "=== Remaining resources to check ==="
gcloud compute instances list
gcloud compute disks list
gcloud compute addresses list

echo "=== Budget status ==="
# Check billing for current month
```

### Full Teardown (tear down and rebuild)

The complete, ordered teardown — for a clean rebuild or closing the project.

```bash
# 1. Destroy the infrastructure (node pools + cluster + networking, ~10 min).
#    Runs as terraform-sa via the impersonation login from Phase 0 — no key:
cd infra/terraform
terraform destroy -var-file=terraform.tfvars

# 2. Verify nothing is left running (all three should be empty):
gcloud compute instances list
gcloud compute addresses list
gcloud compute disks list

# 3. Delete the state bucket (holds terraform state + any backups):
gcloud storage rm -r gs://devops-portfolio-tfstate

# 4. Local cleanup — caches (irreversible, do once):
rm -rf .terraform                        # provider cache
kubectl config delete-context gke_devops-portfolio-prod_us-central1_devops-portfolio
kubectl config delete-cluster gke_devops-portfolio-prod_us-central1_devops-portfolio

# 5. Delete the project — only if you're closing it for good. Both the
#    project and the folder have a 30-day recovery window
#    (gcloud projects undelete / restore in the console), so this isn't
#    instantly irreversible:
gcloud projects delete devops-portfolio-prod

# 6. Delete the folder (must be empty — the project from step 5 must be
#    gone first; pending-deletion projects don't block it):
FOLDER_ID=$(gcloud resource-manager folders list \
  --organization=$(gcloud organizations list --format='value(ID)') \
  --filter='displayName="Infrastructure Engineering"' \
  --format='value(ID)')
gcloud resource-manager folders delete "$FOLDER_ID"
```

**Cloudflare (console):** DNS → remove the `boutique` A record (and any
`*.invincibledevops.tech` records created for this project); optionally reset
SSL mode from Flexible back to Full (strict) if the domain is reused
elsewhere.

**How far to go:** steps 1–4 leave the folder, org, and Cloud Identity intact
(your identity layer) — a fresh rebuild only needs a new project + service
account + bucket (the Reproduction Order checklist above). Steps 5–6 are for
closing things for good, and both have a **30-day recovery window**, so it's
not instantly irreversible. The **org itself can't be deleted with gcloud** —
it lives on your Cloud Identity account; to close it completely, cancel the
account from the admin console (admin.google.com → Account → Close account).

### Automated Kill Switch

Set up a Cloud Function that triggers when budget hits 95%:

```python
# functions/budget-kill-switch/main.py
import base64
import json
import os
from googleapiclient import discovery

def kill_switch(event, context):
    """Triggered by Pub/Sub budget alert at 95% threshold."""
    pubsub_message = base64.b64decode(event['data']).decode('utf-8')
    budget_data = json.loads(pubsub_message)

    cost_amount = budget_data.get('costAmount', 0)
    budget_amount = budget_data.get('budgetAmount', 0)

    if cost_amount / budget_amount >= 0.95:
        print(f"🚨 Budget at {cost_amount/budget_amount*100}% - initiating shutdown")

        compute = discovery.build('compute', 'v1')

        # Stop all instances
        project = os.environ['GCP_PROJECT']
        zones = ['us-central1-a', 'us-central1-b', 'us-central1-c']

        for zone in zones:
            instances = compute.instances().list(project=project, zone=zone).execute()
            for instance in instances.get('items', []):
                if instance['status'] == 'RUNNING':
                    compute.instances().stop(
                        project=project, zone=zone, instance=instance['name']
                    ).execute()
                    print(f"Stopped: {instance['name']}")

        print("✅ Emergency shutdown complete")
```

**Deploy it:**
```bash
gcloud functions deploy budget-kill-switch \
  --runtime python312 \
  --trigger-topic budget-alerts \
  --set-env-vars GCP_PROJECT=devops-portfolio-prod
```

### 12.1 Verified deployment (trial cluster, 2026-08)

```bash
# 1. The Pub/Sub topic must exist BEFORE deploy (gen2 validates the trigger):
gcloud pubsub topics create budget-alerts

# 2. Deploy — note --source (defaults to your cwd — a real trap), --region,
#    --gen2, and --entry-point (must match the function name in main.py):
gcloud functions deploy budget-kill-switch \
  --runtime python312 \
  --trigger-topic budget-alerts \
  --set-env-vars GCP_PROJECT=devops-portfolio-prod \
  --source functions/budget-kill-switch \
  --region us-central1 \
  --gen2 \
  --entry-point kill_switch

# 3. Verify:
gcloud functions describe budget-kill-switch --region us-central1 \
  --format="value(state,eventTrigger.eventType)"
# expect: ACTIVE  google.cloud.pubsub.topic.v1.messagePublished
```

**The piece that makes it actually fire** (function deploys ACTIVE but never
runs without this): the budget alert itself must publish to the topic — in
the console, **Billing → Budgets & Alerts → your budget → Manage
notifications → check "Notify on Pub/Sub topic" → select `budget-alerts`**.
Without that, the function is deployed but never triggered.

**Gotchas that cost time:**
- **`--source` defaults to your current directory** — run from the repo root
  and point at `functions/budget-kill-switch`, or the deploy fails with
  "does not have file [main.py]".
- **gen2 Python requires `requirements.txt`** (`google-api-python-client`),
  or the deploy fails at source validation.
- **`--entry-point` must match the function in main.py** (`kill_switch`) —
  a mismatch builds fine but the container fails its health check at
  startup ("failed to start and listen on PORT=8080").
- **The interactive region prompt wants a NUMBER** — pass `--region
  us-central1` or you may silently deploy to the wrong continent.
- **The function stops *instances*, not the cluster** — a true budget kill
  would also scale node pools to 0 (extend it if you need the full stop).
- **Zones fix:** the original sample listed `us-central1-a/b/c`; this
  cluster runs in `-b/-c/-f` — already corrected in `main.py`.

---

## Repository Structure

```
devops-portfolio/
├── README.md                          # ← This file
├── docs/
│   ├── architecture.md                # Detailed architecture decisions
│   ├── cost-analysis.md               # Cost breakdown per phase
│   ├── security-review.md             # Security findings & mitigations
│   └── screenshots/                   # Dashboard screenshots
├── infra/
│   └── terraform/
│       ├── main.tf                    # GKE cluster + node pools
│       ├── variables.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
├── kubernetes/
│   ├── cilium/
│   │   └── values.yaml               # Cilium configuration
│   ├── cnpg/
│   │   └── postgres-cluster.yaml     # HA PostgreSQL definition
│   ├── gateway/
│   │   ├── gatewayclass.yaml         # Envoy Gateway class + EnvoyProxy
│   │   ├── envoyproxy.yaml           # Coraza WAF dynamic module
│   │   ├── gateway.yaml              # Front door (LoadBalancer)
│   │   ├── httproute.yaml            # Boutique routing
│   │   └── waf-extensionpolicy.yaml  # WAF (OWASP CRS) policy
│   ├── legacy/                       # Retired ingress-nginx config (course)
│   │   ├── ingress-nginx-values.yaml
│   │   └── boutique-ingress.yaml
│   ├── keda/
│   │   ├── gpu-scaler.yaml           # GPU-based autoscaling
│   │   └── queue-scaler.yaml         # Redis queue-based autoscaling
│   ├── ai/
│   │   ├── ollama-deployment.yaml     # CPU variant (no GPU on trial)
│   │   ├── redis-inference-api.yaml   # queue backend + enqueue API
│   │   ├── queue-worker.yaml          # pops queue → calls Ollama
│   │   └── scaledobject.yaml          # KEDA: queue length → 0..3 replicas
│   └── observability/
│       ├── prometheus-values.yaml
│       └── datadog-values.yaml
├── chaos/
│   ├── pod-kill-app.yaml          # PodChaos: kill 50% of boutique frontends
│   ├── network-delay-db.yaml      # NetworkChaos: 500ms latency on Postgres
│   ├── cpu-stress-ai.yaml         # StressChaos: CPU stress on Ollama (CPU trial variant)
│   ├── node-drain.sh              # zone-failure simulation (cordon + drain)
│   └── steady-state-check.yaml    # §4.2 hypothesis as a ConfigMap
├── scripts/
│   ├── db-chaos-test.sh
│   ├── gpu-load-test.sh
│   ├── waf-chaos-test.sh
│   ├── emergency-cleanup.sh
│   └── setup-tools.sh
├── functions/
│   └── budget-kill-switch/
│       ├── main.py
│       └── requirements.txt
└── .github/
    └── workflows/
        ├── terraform-plan.yaml
        └── chaos-scheduled.yaml
```

---

## Quick Start Command Reference

```bash
# Phase 0: Foundation
gcloud auth login
gcloud organizations list
gcloud projects create devops-portfolio-prod
gcloud config set project devops-portfolio-prod
gcloud services enable container.googleapis.com compute.googleapis.com

# Phase 1: Cluster + Security
cd infra/terraform && terraform init && terraform apply
cilium install --set encryption.enabled=true --set encryption.type=wireguard
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.3 --namespace envoy-gateway-system --create-namespace
kubectl apply -f kubernetes/gateway/

# Phase 2: Database + Observability
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
kubectl apply -f kubernetes/cnpg/postgres-cluster.yaml
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace

# Phase 3: AI Inference
helm upgrade --install gpu-operator nvidia/gpu-operator --namespace gpu-operator --create-namespace
kubectl apply -f kubernetes/ai/ollama-deployment.yaml
helm upgrade --install keda kedacore/keda --namespace keda --create-namespace
kubectl apply -f kubernetes/keda/gpu-scaler.yaml

# Phase 4: Chaos
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh --namespace chaos-mesh --create-namespace
kubectl apply -f chaos/pod-kill.yaml
bash scripts/db-chaos-test.sh
```

---

## Success Metrics Summary

| Phase | Key Metric | Target |
|---|---|---|
| 1 | WAF block rate (OWASP ZAP) | 100% of Top 10 attacks blocked |
| 2 | DB failover time | < 30 seconds, 0 committed writes lost |
| 2 | TPS during load test | > 1000 sustained |
| 3 | AI autoscaling responsiveness | New pod within 60s of queue threshold breach |
| 3 | GPU utilization efficiency | > 60% average during load, scale to 0 when idle |
| 4 | Application uptime during chaos | > 99.5% |
| 4 | P99 latency during chaos | < 2x baseline |

---

> **"The master has failed more times than the beginner has even tried."**
> Don't expect everything to work perfectly the first time. Each failure is a learning opportunity and a story to tell in your portfolio. Document your debugging process — employers value problem-solving skills more than perfect configurations.

---

*Built with guidance from Senior DevOps Engineers and powered by the GitHub Student Developer Pack.*




