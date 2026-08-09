project_id       = "devops-portfolio-prod"
region           = "us-central1"
cluster_name     = "devops-portfolio"

# Networking
subnet_cidr   = "10.0.0.0/16"
pods_cidr     = "10.1.0.0/16"
services_cidr = "10.2.0.0/20"
master_cidr   = "172.16.0.0/28"

# Cost optimization
use_spot_vms = true

application_machine_type = "e2-custom-2-8192"
system_node_count       = 1   # per ZONE
application_min_nodes   = 1
application_max_nodes   = 3

# Security — enable only after configuring Binary Authorization attestors
enable_binary_authorization = false
