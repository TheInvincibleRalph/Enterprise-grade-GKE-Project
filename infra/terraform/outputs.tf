output "project_id" {
  description = "GCP project ID"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE cluster API endpoint"
  value       = google_container_cluster.primary.endpoint
}

output "cluster_location" {
  description = "GKE cluster location (region)"
  value       = google_container_cluster.primary.location
}

output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.vpc.name
}

output "subnet_name" {
  description = "GKE subnet name"
  value       = google_compute_subnetwork.subnet.name
}

output "get_credentials_command" {
  description = "Command to configure kubectl for this cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${var.region} --project ${var.project_id}"
}

output "node_pools" {
  description = "Created node pool names"
  value = concat(
    [google_container_node_pool.system.name, google_container_node_pool.application.name],
    var.enable_gpu_pool ? [google_container_node_pool.gpu[0].name] : [],
  )
}
