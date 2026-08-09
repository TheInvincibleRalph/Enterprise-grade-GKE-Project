variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region for the GKE cluster"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "Name of the GKE cluster and prefix for network resources"
  type        = string
  default     = "devops-portfolio"
}

variable "subnet_cidr" {
  description = "Primary subnet CIDR for GKE nodes"
  type        = string
  default     = "10.0.0.0/16"
}

variable "pods_cidr" {
  description = "Secondary range CIDR for pod IPs"
  type        = string
  default     = "10.1.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range CIDR for Kubernetes services"
  type        = string
  default     = "10.2.0.0/20"
}

variable "master_cidr" {
  description = "CIDR block for the GKE control plane"
  type        = string
  default     = "172.16.0.0/28"
}

variable "node_network_tag" {
  description = "Network tag applied to GKE nodes for firewall rules"
  type        = string
  default     = "devops-portfolio-node"
}

variable "use_spot_vms" {
  description = "Use spot VMs for node pools (60-80% cost savings)"
  type        = bool
  default     = true
}

variable "system_node_count" {
  description = "Number of nodes in the system pool (spread across zones)"
  type        = number
  default     = 2
}

variable "system_machine_type" {
  description = "Machine type for the system node pool"
  type        = string
  default     = "e2-custom-1-4096"
}

variable "application_min_nodes" {
  description = "Minimum nodes in the application pool"
  type        = number
  default     = 2
}

variable "application_max_nodes" {
  description = "Maximum nodes in the application pool"
  type        = number
  default     = 8
}

variable "application_machine_type" {
  description = "Machine type for the application node pool"
  type        = string
  default     = "e2-custom-1-4096"
}

variable "enable_binary_authorization" {
  description = "Enforce Binary Authorization (requires attestation policy; leave false for initial deploy)"
  type        = bool
  default     = false
}
