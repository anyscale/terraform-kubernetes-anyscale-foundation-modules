# ---------------------------------------------------------------------------------------------------------------------
# GCP GKE A4/B200 GPUDirect RDMA Cluster
#
# This module creates the infrastructure layer required before Kubernetes can expose GCP RDMA devices to Pods:
# dedicated gVNIC and RoCE VPCs, a multi-networking GKE cluster, a CPU head node pool, and an A4/B200 Spot node pool
# with one gVNIC and eight RDMA additional node networks.
# ---------------------------------------------------------------------------------------------------------------------

data "google_container_engine_versions" "available" {
  project  = var.project_id
  location = var.region

  depends_on = [google_project_service.required]
}

locals {
  project_services = [
    "compute.googleapis.com",
    "container.googleapis.com",
  ]

  selected_gke_version = var.cluster_version != null && var.cluster_version != "" ? var.cluster_version : lookup(
    data.google_container_engine_versions.available.release_channel_default_version,
    var.release_channel,
    data.google_container_engine_versions.available.default_cluster_version
  )

  rdma_network_profile = coalesce(
    var.rdma_network_profile,
    "projects/${var.project_id}/global/networkProfiles/${var.zone}-vpc-roce"
  )

  rdma_subnet_names = [
    for index in range(var.rdma_interface_count) : "${var.rdma_subnetwork_name_prefix}-${index}"
  ]

  rdma_subnet_cidrs = [
    for index in range(var.rdma_interface_count) : "${var.rdma_subnetwork_cidr_prefix}.${index}.0/24"
  ]

  additional_node_networks = concat(
    [
      {
        network    = google_compute_network.gvnic.name
        subnetwork = google_compute_subnetwork.gvnic.name
      }
    ],
    [
      for subnet in google_compute_subnetwork.rdma : {
        network    = google_compute_network.rdma.name
        subnetwork = subnet.name
      }
    ]
  )

  module_resource_labels = {
    tf_sub_module = "gcp-gke-b200-rdma"
  }

  resource_labels = merge(local.module_resource_labels, var.resource_labels)

  default_cpu_labels = {
    workload = "${var.workload_name}-head"
  }

  cpu_labels = merge(local.default_cpu_labels, var.cpu_labels)

  default_worker_labels = {
    (var.workload_label_key)             = var.workload_name
    "accelerator"                        = "b200"
    "rdma"                               = "true"
    "nvidia.com/gpu.present"             = "true"
    "nvidia.com/gpu.product"             = "NVIDIA-B200"
    "nvidia.com/gpu.count"               = tostring(var.gpu_count)
    "node.anyscale.com/accelerator-type" = "GPU"
    "node.anyscale.com/gpu-accelerator"  = "B200"
    "node.anyscale.com/gpudirect-rdma"   = "true"
  }

  worker_labels = merge(local.default_worker_labels, var.worker_labels)
}

resource "google_project_service" "required" {
  for_each = var.enable_project_services ? toset(local.project_services) : []

  project = var.project_id
  service = each.value

  disable_on_destroy = var.disable_services_on_destroy
}

resource "google_compute_network" "gvnic" {
  project = var.project_id

  name                    = var.gvnic_network_name
  auto_create_subnetworks = false
  mtu                     = var.network_mtu
}

resource "google_compute_subnetwork" "gvnic" {
  project = var.project_id

  name          = var.gvnic_subnetwork_name
  region        = var.region
  network       = google_compute_network.gvnic.id
  ip_cidr_range = var.gvnic_subnetwork_cidr
}

resource "google_compute_firewall" "gvnic_internal" {
  project = var.project_id

  name    = "${var.gvnic_network_name}-allow-internal"
  network = google_compute_network.gvnic.name

  direction     = "INGRESS"
  source_ranges = [var.gvnic_subnetwork_cidr]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

resource "google_compute_network" "rdma" {
  project = var.project_id

  name                    = var.rdma_network_name
  auto_create_subnetworks = false
  mtu                     = var.network_mtu
  network_profile         = local.rdma_network_profile
}

resource "google_compute_subnetwork" "rdma" {
  for_each = {
    for index, name in local.rdma_subnet_names : name => local.rdma_subnet_cidrs[index]
  }

  project = var.project_id

  name          = each.key
  region        = var.region
  network       = google_compute_network.rdma.id
  ip_cidr_range = each.value
}

resource "google_compute_firewall" "rdma_internal" {
  project = var.project_id

  name    = "${var.rdma_network_name}-allow-internal"
  network = google_compute_network.rdma.name

  direction     = "INGRESS"
  source_ranges = ["${var.rdma_subnetwork_cidr_prefix}.0.0/16"]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }
}

resource "google_container_cluster" "this" {
  project = var.project_id

  name               = var.cluster_name
  location           = var.region
  node_locations     = [var.zone]
  min_master_version = local.selected_gke_version

  network    = var.host_network
  subnetwork = var.host_subnetwork

  datapath_provider        = "ADVANCED_DATAPATH"
  enable_multi_networking  = true
  networking_mode          = "VPC_NATIVE"
  initial_node_count       = 1
  remove_default_node_pool = true
  deletion_protection      = var.deletion_protection
  resource_labels          = local.resource_labels

  release_channel {
    channel = var.release_channel
  }

  ip_allocation_policy {}

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "cpu_head" {
  count = var.create_cpu_head_pool ? 1 : 0

  project = var.project_id

  name           = var.cpu_head_pool_name
  cluster        = google_container_cluster.this.name
  location       = var.region
  node_locations = [var.zone]
  node_count     = var.cpu_node_count
  version        = local.selected_gke_version

  management {
    auto_repair  = var.enable_node_auto_repair
    auto_upgrade = var.enable_node_auto_upgrade
  }

  node_config {
    machine_type    = var.cpu_machine_type
    disk_size_gb    = var.cpu_disk_size_gb
    disk_type       = var.cpu_disk_type
    image_type      = var.node_image_type
    labels          = local.cpu_labels
    oauth_scopes    = var.node_oauth_scopes
    resource_labels = local.resource_labels
    service_account = var.node_service_account_email
  }
}

resource "google_container_node_pool" "a4_b200" {
  project = var.project_id

  name           = var.worker_pool_name
  cluster        = google_container_cluster.this.name
  location       = var.region
  node_locations = [var.zone]
  node_count     = var.worker_node_count
  version        = local.selected_gke_version

  management {
    auto_repair  = var.enable_node_auto_repair
    auto_upgrade = var.enable_node_auto_upgrade
  }

  node_config {
    machine_type    = var.worker_machine_type
    disk_size_gb    = var.worker_disk_size_gb
    disk_type       = var.worker_disk_type
    image_type      = var.node_image_type
    labels          = local.worker_labels
    oauth_scopes    = var.node_oauth_scopes
    resource_labels = local.resource_labels
    service_account = var.node_service_account_email
    spot            = var.worker_spot

    guest_accelerator {
      type  = var.gpu_type
      count = var.gpu_count

      gpu_driver_installation_config {
        gpu_driver_version = var.gpu_driver_version
      }
    }

    dynamic "taint" {
      for_each = var.worker_taints

      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }
  }

  network_config {
    dynamic "additional_node_network_configs" {
      for_each = local.additional_node_networks

      content {
        network    = additional_node_network_configs.value.network
        subnetwork = additional_node_network_configs.value.subnetwork
      }
    }
  }

  depends_on = [
    google_compute_subnetwork.gvnic,
    google_compute_subnetwork.rdma,
  ]
}
