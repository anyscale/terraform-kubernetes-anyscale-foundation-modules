module "b200_rdma_gke" {
  source = "../../../modules/gcp-gke-b200-rdma"

  project_id      = var.project_id
  region          = var.region
  zone            = var.zone
  cluster_name    = var.cluster_name
  host_network    = var.host_network
  host_subnetwork = var.host_subnetwork

  gvnic_network_name          = var.gvnic_network_name
  gvnic_subnetwork_name       = var.gvnic_subnetwork_name
  gvnic_subnetwork_cidr       = var.gvnic_subnetwork_cidr
  rdma_network_name           = var.rdma_network_name
  rdma_subnetwork_name_prefix = var.rdma_subnetwork_name_prefix
  rdma_subnetwork_cidr_prefix = var.rdma_subnetwork_cidr_prefix

  worker_node_count           = var.worker_node_count
  worker_autoscaling          = var.worker_autoscaling
  worker_reservation_affinity = var.worker_reservation_affinity
  workload_name               = var.workload_name
  resource_labels             = var.resource_labels
}
