# ---------------------------------------------------------------------------------------------------------------------# Example Anyscale K8s Resources - Public Networking
#   This template cretes resources for a GKE Cluster.
#
#   It creates:
#     - VPC, Subnet, Firewall
#     - GKE Cluster
#     - GKE Node Pool
# ---------------------------------------------------------------------------------------------------------------------

# google_client_config and kubernetes provider must be explicitly specified like the following.
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

locals {
  # Base configuration shared by all node pools
  base_node_pool = {
    min_count              = 0
    max_count              = 10
    initial_node_count     = 0
    local_ssd_count        = 0
    disk_size_gb           = 500
    spot                   = false
    preemptible            = false
    enable_gcfs            = false
    enable_gvnic           = false
    auto_repair            = true
    auto_upgrade           = true
    image_type             = "COS_CONTAINERD"
    logging_variant        = "DEFAULT"
    monitoring_variant     = "DEFAULT"
    create_service_account = false
    service_account        = local.gke_nodes_service_account_email
  }

  # CPU-specific configuration
  cpu_config = {
    disk_type = "pd-ssd"
  }

  # GPU configurations mapping
  gpu_configs = {
    "V100" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-tesla-v100"
        machine_type       = "n1-standard-16"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-tesla-v100"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "P100" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-tesla-p100"
        machine_type       = "n1-standard-16"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-tesla-p100"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "T4" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-tesla-t4"
        machine_type       = "n1-standard-16"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-tesla-t4"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "L4" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-l4"
        machine_type       = "g2-standard-16"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-l4"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "A100-40G" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-tesla-a100"
        machine_type       = "a2-highgpu-1g"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-tesla-a100"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "A100-80G" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-a100-80gb"
        machine_type       = "a2-ultragpu-1g"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-a100-80gb"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "H100" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-h100-80gb"
        machine_type       = "a3-highgpu-1g"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-h100-80gb"
        "nvidia.com/gpu.count"   = "1"
      }
    }

    "H100-MEGA" = {
      instance = {
        disk_type          = "pd-ssd"
        gpu_driver_version = "LATEST"
        accelerator_count  = 1
        accelerator_type   = "nvidia-h100-mega-80gb"
        machine_type       = "a3-megagpu-8g"
      }
      node_labels = {
        "nvidia.com/gpu.product" = "nvidia-h100-mega-80gb"
        "nvidia.com/gpu.count"   = "8"
      }
    }
  }

  # Common taint configurations
  capacity_type_taint = {
    on_demand = {
      key    = "node.anyscale.com/capacity-type"
      value  = "ON_DEMAND"
      effect = "NO_SCHEDULE"
    }
    spot = {
      key    = "node.anyscale.com/capacity-type"
      value  = "SPOT"
      effect = "NO_SCHEDULE"
    }
  }

  gpu_taints = [
    {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    },
    {
      key    = "node.anyscale.com/accelerator-type"
      value  = "GPU"
      effect = "NO_SCHEDULE"
    }
  ]

  gpu_taints_ondemand = concat(
    [local.capacity_type_taint.on_demand],
    local.gpu_taints
  )

  gpu_taints_spot = concat(
    [local.capacity_type_taint.spot],
    local.gpu_taints
  )

  # Generate GPU node pools based on node_group_gpu_types
  gpu_node_pools = flatten([
    for gpu_type in var.node_group_gpu_types : [
      merge(local.base_node_pool,
        merge(local.gpu_configs[gpu_type].instance, {
          name = "ondemand-gpu-${lower(gpu_type)}"
        })
      ),

      merge(local.base_node_pool,
        merge(local.gpu_configs[gpu_type].instance, {
          name = "spot-gpu-${lower(gpu_type)}"
          spot = true
        })
      )
    ]
  ])

  # Define all node pools
  node_pools = concat(
    [
      merge(local.base_node_pool, {
        name               = "default-node-pool"
        machine_type       = "e2-standard-4"
        initial_node_count = 2
      }, local.cpu_config),

      merge(local.base_node_pool, {
        name         = "ondemand-cpu"
        machine_type = "n2-standard-16"
      }, local.cpu_config),

      merge(local.base_node_pool, {
        name         = "spot-cpu"
        machine_type = "n2-standard-16"
        spot         = true
      }, local.cpu_config)
    ],
    local.gpu_node_pools
  )

  # Generate node pool labels dynamically
  node_pools_labels = merge(
    { all = {} },
    {
      for gpu_type in var.node_group_gpu_types : "ondemand-gpu-${lower(gpu_type)}" => local.gpu_configs[gpu_type].node_labels
    },
    {
      for gpu_type in var.node_group_gpu_types : "spot-gpu-${lower(gpu_type)}" => local.gpu_configs[gpu_type].node_labels
    }
  )

  # Generate node pool taints dynamically
  node_pools_taints = merge(
    { all = [] },
    {
      "ondemand-cpu" = [local.capacity_type_taint.on_demand],
      "spot-cpu"     = [local.capacity_type_taint.spot]
    },
    {
      for gpu_type in var.node_group_gpu_types : "ondemand-gpu-${lower(gpu_type)}" => local.gpu_taints_ondemand
    },
    {
      for gpu_type in var.node_group_gpu_types : "spot-gpu-${lower(gpu_type)}" => local.gpu_taints_spot
    }
  )
}

# Create GKE cluster
#trivy:ignore:avd-gcp-0061
#trivy:ignore:avd-gcp-0059
#trivy:ignore:avd-gcp-0056
#trivy:ignore:avd-gcp-0051
#trivy:ignore:avd-gcp-0057
#trivy:ignore:avd-ksv-0106
#trivy:ignore:AVD-KSV-0118
#trivy:ignore:AVD-KSV-0110
module "gke" {
  #checkov:skip=CKV_TF_1: "Ensure Terraform module sources use a commit hash"

  source = "terraform-google-modules/kubernetes-engine/google"

  # NOTE: 35.0+ requires hashicorp/google 6.0+
  version = "~>34.0"

  project_id = var.google_project_id
  name       = var.gke_cluster_name
  region     = var.google_region
  zones      = [data.google_compute_zones.available.names[0], data.google_compute_zones.available.names[1]]

  network           = google_compute_network.anyscale.name
  subnetwork        = google_compute_subnetwork.anyscale.name
  ip_range_pods     = google_compute_subnetwork.anyscale.secondary_ip_range[0].range_name
  ip_range_services = google_compute_subnetwork.anyscale.secondary_ip_range[1].range_name

  http_load_balancing        = false
  network_policy             = false
  horizontal_pod_autoscaling = false
  filestore_csi_driver       = false
  dns_cache                  = false
  remove_default_node_pool   = true
  deletion_protection        = false

  cluster_resource_labels = local.full_labels

  node_pools = local.node_pools

  node_pools_oauth_scopes = {
    all = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  node_pools_labels = local.node_pools_labels

  node_pools_taints = local.node_pools_taints
}

# Create VPC Network
resource "google_compute_network" "anyscale" {
  name                    = "${var.gke_cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Create Subnet
#trivy:ignore:avd-gcp-0029
resource "google_compute_subnetwork" "anyscale" {
  #checkov:skip=CKV_GCP_26: "Ensure that VPC Flow Logs is enabled for every subnet in a VPC Network"
  #checkov:skip=CKV_GCP_74: "Ensure that private_ip_google_access is enabled for Subnet"

  name          = "${var.gke_cluster_name}-subnet"
  ip_cidr_range = "10.0.0.0/16"
  network       = google_compute_network.anyscale.id
  region        = var.google_region

  secondary_ip_range {
    range_name    = "${var.gke_cluster_name}-subnet-pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "${var.gke_cluster_name}-subnet-services"
    ip_cidr_range = "10.2.0.0/16"
  }
}

# Allow common external ingress traffic (HTTPS, SSH, ICMP)
resource "google_compute_firewall" "allow-common-ingress" {
  #checkov:skip=CKV_GCP_2: "Ensure Google compute firewall ingress does not allow unrestricted ssh access"

  name    = "${var.gke_cluster_name}-allow-common-ingress"
  network = google_compute_network.anyscale.name

  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22", "443"] # SSH, HTTP, HTTPS
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = var.ingress_cidr_ranges
}

# Allow all internal traffic within VPC.
# VPC by default only allows all internal traffic on the same subnet.
resource "google_compute_firewall" "allow-internal" {
  #checkov:skip=CKV2_GCP_12: "GCP compute firewall ingress allow access to all ports"

  name    = "${var.gke_cluster_name}-allow-internal"
  network = google_compute_network.anyscale.name

  direction = "INGRESS"

  allow {
    protocol = "all"
  }

  source_ranges = [
    google_compute_subnetwork.anyscale.ip_cidr_range,
    google_compute_subnetwork.anyscale.secondary_ip_range[0].ip_cidr_range,
    google_compute_subnetwork.anyscale.secondary_ip_range[1].ip_cidr_range
  ]
}
