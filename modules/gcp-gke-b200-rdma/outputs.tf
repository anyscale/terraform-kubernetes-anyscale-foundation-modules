output "cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.this.name
}

output "cluster_id" {
  description = "ID of the GKE cluster."
  value       = google_container_cluster.this.id
}

output "cluster_location" {
  description = "Regional location of the GKE control plane."
  value       = google_container_cluster.this.location
}

output "cluster_endpoint" {
  description = "Endpoint of the GKE cluster."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "selected_gke_version" {
  description = "GKE version selected for the cluster and node pools."
  value       = local.selected_gke_version
}

output "cpu_head_pool_name" {
  description = "Name of the CPU head node pool."
  value       = var.create_cpu_head_pool ? google_container_node_pool.cpu_head[0].name : null
}

output "worker_pool_name" {
  description = "Name of the A4/B200 worker node pool."
  value       = google_container_node_pool.a4_b200.name
}

output "worker_pool_instance_group_urls" {
  description = "Managed instance group URLs backing the A4/B200 worker node pool."
  value       = google_container_node_pool.a4_b200.managed_instance_group_urls
}

output "gvnic_network_name" {
  description = "Name of the dedicated gVNIC VPC."
  value       = google_compute_network.gvnic.name
}

output "gvnic_subnetwork_name" {
  description = "Name of the dedicated gVNIC subnetwork."
  value       = google_compute_subnetwork.gvnic.name
}

output "rdma_network_name" {
  description = "Name of the dedicated RDMA VPC."
  value       = google_compute_network.rdma.name
}

output "rdma_network_profile" {
  description = "Network profile used by the dedicated RDMA VPC."
  value       = local.rdma_network_profile
}

output "rdma_subnetwork_names" {
  description = "Names of the RDMA subnetworks attached to the A4/B200 worker pool."
  value       = [for subnet in google_compute_subnetwork.rdma : subnet.name]
}

output "additional_node_networks" {
  description = "Additional node network layout rendered into the A4/B200 node pool."
  value       = local.additional_node_networks
}

output "get_credentials_command" {
  description = "gcloud command for fetching kubeconfig credentials for this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location=${google_container_cluster.this.location} --project=${var.project_id}"
}
