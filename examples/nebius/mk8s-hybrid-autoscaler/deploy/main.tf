# ============================================================================
# ANYSCALE ON NEBIUS - MAIN DEPLOYMENT
# ============================================================================
# Purpose-built Kubernetes cluster with autoscaling node groups for Anyscale
# No module dependencies - full control over all resources
# ============================================================================

# ============================================================================
# KUBERNETES CLUSTER
# ============================================================================

resource "nebius_mk8s_v1_cluster" "anyscale" {
  parent_id = local.nebius_project_id
  name      = local.nebius_cluster_name

  control_plane = {
    endpoints = {
      public_endpoint = {}
    }
    etcd_cluster_size = 3
    subnet_id         = local.nebius_vpc_subnet_id
    version           = "1.31"
  }
}

# ============================================================================
# SERVICE ACCOUNT FOR NODE GROUPS
# ============================================================================

data "nebius_iam_v1_group" "editors" {
  name      = "editors"
  parent_id = local.nebius_tenant_id
}

resource "nebius_iam_v1_service_account" "node_sa" {
  parent_id = local.nebius_project_id
  name      = "anyscale-node-sa"
}

resource "nebius_iam_v1_group_membership" "node_sa_admin" {
  parent_id = data.nebius_iam_v1_group.editors.id
  member_id = nebius_iam_v1_service_account.node_sa.id
}

# ============================================================================
# NODE GROUPS - ONE PER INSTANCE TYPE
# ============================================================================

# Define the 6 instance types we support
locals {
  instance_types = {
    # CPU types - Intel Ice Lake E2
    "cpu-e2-8vcpu-32gb" = {
      platform = "cpu-e2"
      preset   = "8vcpu-32gb"
      disk_gb  = 128
      gpu      = false
    }
    "cpu-e2-16vcpu-64gb" = {
      platform = "cpu-e2"
      preset   = "16vcpu-64gb"
      disk_gb  = 128
      gpu      = false
    }
    "cpu-e2-32vcpu-128gb" = {
      platform = "cpu-e2"
      preset   = "32vcpu-128gb"
      disk_gb  = 256
      gpu      = false
    }

    # GPU types - NVIDIA accelerators
    "gpu-h100-sxm-1gpu-16vcpu-200gb" = {
      platform = "gpu-h100-sxm"
      preset   = "1gpu-16vcpu-200gb"
      disk_gb  = 1023
      gpu      = true
    }
    "gpu-h200-sxm-1gpu-16vcpu-200gb" = {
      platform = "gpu-h200-sxm"
      preset   = "1gpu-16vcpu-200gb"
      disk_gb  = 1023
      gpu      = true
    }
    "gpu-l40s-a-1gpu-16vcpu-64gb" = {
      platform = "gpu-l40s-a"
      preset   = "1gpu-16vcpu-64gb"
      disk_gb  = 512
      gpu      = true
    }
  }
}

# Create one autoscaling node group per instance type
resource "nebius_mk8s_v1_node_group" "instance_type" {
  for_each = local.instance_types

  parent_id = nebius_mk8s_v1_cluster.anyscale.id
  name      = "ng-${each.key}"

  # AUTOSCALING - scale to zero when idle
  autoscaling = {
    min_node_count = local.autoscaling_min
    max_node_count = local.autoscaling_max
  }

  template = {
    # CRITICAL: Custom label for Anyscale node selectors
    # Nebius auto-labels with node.kubernetes.io/instance-type=<platform> only
    # We need <platform>-<preset> so use custom namespace
    metadata = {
      labels = {
        "anyscale.com/instance-type" = each.key
      }
    }

    # Taint workload nodes to prevent system pods from landing here
    # System pods should only run on the dedicated system node
    taints = [{
      key    = "workload"
      value  = "true"
      effect = "NO_SCHEDULE"
    }]

    boot_disk = {
      type           = "NETWORK_SSD"
      size_gibibytes = each.value.disk_gb
    }

    network_interfaces = [{
      subnet_id         = local.nebius_vpc_subnet_id
      public_ip_address = null  # No public IP - private networking only
    }]

    resources = {
      platform = each.value.platform
      preset   = each.value.preset
    }

    service_account_id = nebius_iam_v1_service_account.node_sa.id

    # GPU settings for GPU nodes only
    gpu_settings = each.value.gpu ? {
      drivers_preset = "cuda12"
    } : null

    cloud_init_user_data = templatefile("${path.module}/cloud-init.tftpl", {
      ssh_user_name  = local.ssh_user_name
      ssh_public_key = local.ssh_public_key
    })
  }
}

# ============================================================================
# SYSTEM NODE GROUP - ALWAYS ON FOR K8S + ANYSCALE OPERATOR
# ============================================================================
# Dedicated node with public IP that provides:
# - kube-system pods (Cilium, CoreDNS, metrics-server, etc.)
# - Anyscale operator + ingress-nginx
# - Egress gateway for private workload nodes (via Cilium)

resource "nebius_mk8s_v1_node_group" "system" {
  parent_id = nebius_mk8s_v1_cluster.anyscale.id
  name      = "ng-system"

  # ALWAYS ON - 2 small nodes for HA (cilium-operator needs 2 nodes)
  fixed_node_count = 2

  template = {
    metadata = {
      labels = {
        "anyscale.com/node-role"     = "system"
        "anyscale.com/instance-type" = "cpu-e2-2vcpu-8gb"
      }
    }

    boot_disk = {
      type           = "NETWORK_SSD"
      size_gibibytes = 128
    }

    network_interfaces = [{
      subnet_id         = local.nebius_vpc_subnet_id
      public_ip_address = {}  # Has public IP for egress
    }]

    resources = {
      platform = "cpu-e2"
      preset   = "2vcpu-8gb"
    }

    service_account_id = nebius_iam_v1_service_account.node_sa.id

    cloud_init_user_data = templatefile("${path.module}/cloud-init.tftpl", {
      ssh_user_name  = local.ssh_user_name
      ssh_public_key = local.ssh_public_key
    })
  }
}

# ============================================================================
# ANYSCALE OPERATOR - OBJECT STORAGE CREDENTIALS
# ============================================================================

resource "nebius_iam_v1_service_account" "anyscale_bucket_sa" {
  parent_id = local.nebius_project_id
  name      = "anyscale-bucket-sa"
}

resource "nebius_iam_v1_group_membership" "anyscale_bucket_sa_editor" {
  parent_id = data.nebius_iam_v1_group.editors.id
  member_id = nebius_iam_v1_service_account.anyscale_bucket_sa.id
}

resource "nebius_iam_v2_access_key" "anyscale_bucket_key" {
  parent_id   = local.nebius_project_id
  name        = "anyscale-s3-bucket-key-v2"
  description = "Access key for Anyscale S3 bucket"
  account = {
    service_account = {
      id = nebius_iam_v1_service_account.anyscale_bucket_sa.id
    }
  }
}

# ============================================================================
# ANYSCALE OPERATOR - HELM DEPLOYMENT VIA NEBIUS APPLICATIONS
# ============================================================================

resource "nebius_applications_v1alpha1_k8s_release" "anyscale_operator" {
  cluster_id = nebius_mk8s_v1_cluster.anyscale.id
  parent_id  = local.nebius_project_id

  application_name = "anyscale-operator"
  namespace        = "anyscale-system"
  product_slug     = "nebius/anyscale-operator"

  values = file("${path.module}/../values/anyscale-operator.yaml")

  set = {
    "cloudDeploymentId"                    = local.anyscale_deployment_id
    "anyscaleCliToken"                     = local.anyscale_cli_token
    "aws.objectStorage.endpoint_url"       = "https://storage.${local.nebius_region}.nebius.cloud:443"
    "aws.credentialSecret.accessKeyId"     = nebius_iam_v2_access_key.anyscale_bucket_key.status.aws_access_key_id
    "aws.credentialSecret.secretAccessKey" = nebius_iam_v2_access_key.anyscale_bucket_key.status.secret
  }

  depends_on = [
    nebius_mk8s_v1_node_group.system,
    nebius_mk8s_v1_node_group.instance_type
  ]
}
