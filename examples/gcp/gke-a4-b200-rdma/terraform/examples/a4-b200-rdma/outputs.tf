output "get_credentials_command" {
  description = "gcloud command for fetching kubeconfig credentials for this cluster."
  value       = module.b200_rdma_gke.get_credentials_command
}

output "worker_pool_name" {
  description = "Name of the A4/B200 worker node pool."
  value       = module.b200_rdma_gke.worker_pool_name
}

output "rdma_subnetwork_names" {
  description = "Names of the RDMA subnetworks attached to the A4/B200 worker pool."
  value       = module.b200_rdma_gke.rdma_subnetwork_names
}
