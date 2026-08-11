terraform {
  required_version = ">= 1.5"

  backend "gcs" {}
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

provider "google" {
  project = var.project_id
  region  = var.region
}

# VPC Networking

resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# Cloud NAT for private node internet access

resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Firewall Rules

resource "google_compute_firewall" "allow_ingress_health_checks" {
  name    = "${var.cluster_name}-allow-health-checks"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
    "209.85.152.0/22",
    "209.85.204.0/22",
  ]

  target_tags = [var.node_network_tag]
}

# GKE Cluster

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.region 
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  remove_default_node_pool = true
  initial_node_count       = 1

  node_config {
    disk_size_gb = 30
    disk_type    = "pd-standard"
    spot         = true 

  networking_mode = "VPC_NATIVE"
  

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Disable GKE Dataplane V2 so we can install full Cilium with WireGuard
  datapath_provider = "LEGACY_DATAPATH"

  # Private cluster — nodes have internal IPs only
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_cidr
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "STABLE"
  }

  min_master_version = "1.35.5-gke.1057002"

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  network_policy {
    enabled  = false
    provider = "PROVIDER_UNSPECIFIED"
  }

  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }
  

  enable_shielded_nodes = true

  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T03:00:00Z"
      end_time   = "2024-01-01T11:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  cost_management_config {
    enabled = true
  }

  deletion_protection = false
  }
}

# Allow control plane to communicate with nodes
resource "google_compute_firewall" "allow_master_to_nodes" {
  name    = "${var.cluster_name}-allow-master"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["10250", "443"]
  }

  source_ranges = [var.master_cidr]
  target_tags   = [var.node_network_tag]
}

# Allow pod and node traffic within the cluster
resource "google_compute_firewall" "allow_nodes_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr, var.pods_cidr, var.services_cidr]
  target_tags   = [var.node_network_tag]
}

# Node Pools

# System Pool — critical infrastructure workloads (Cilium, CoreDNS, operators)
resource "google_container_node_pool" "system" {
  name     = "system-pool"
  cluster  = google_container_cluster.primary.name
  location = var.region

  node_count = var.system_node_count

  node_config {
    machine_type = var.system_machine_type
    disk_size_gb = 30
    disk_type    = "pd-standard"
    spot         = var.use_spot_vms

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    tags = [var.node_network_tag]

    labels = {
      role = "system"
    }

    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  network_config {
    pod_range = "pods"
    enable_private_nodes = true
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Application Pool — stateless workloads (Boutique, APIs)
resource "google_container_node_pool" "application" {
  name     = "application-pool"
  cluster  = google_container_cluster.primary.name
  location = var.region

  initial_node_count = var.application_min_nodes

  autoscaling {
    min_node_count = var.application_min_nodes
    max_node_count = var.application_max_nodes
  }

  node_config {
    machine_type = var.application_machine_type
    disk_size_gb = 30
    disk_type    = "pd-standard"
    spot         = var.use_spot_vms

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    tags = [var.node_network_tag]

    labels = {
      role = "application"
    }
  }

  network_config {
    pod_range = "pods"
    enable_private_nodes = true
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}