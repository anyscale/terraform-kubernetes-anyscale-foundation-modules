# ============================================================================
# CONFIGURATION LOADER
# ============================================================================
# Loads customer configuration from config.yaml
# Customers only edit config.yaml - all other files are pre-configured
# ============================================================================

locals {
  # Load customer configuration
  config = yamldecode(file("${path.module}/../config.yaml"))

  # Nebius configuration
  nebius_tenant_id     = local.config.nebius.tenant_id
  nebius_project_id    = local.config.nebius.project_id
  nebius_region        = local.config.nebius.region
  nebius_vpc_subnet_id = local.config.nebius.vpc_subnet_id
  nebius_cluster_name  = try(local.config.nebius.cluster_name, "anyscale-cluster")

  # SSH configuration
  ssh_user_name  = local.config.ssh.username
  ssh_public_key = local.config.ssh.public_key

  # Anyscale configuration
  anyscale_cloud_name    = local.config.anyscale.cloud_name
  anyscale_deployment_id = local.config.anyscale.cloud_deployment_id
  anyscale_cli_token     = local.config.anyscale.cli_token

  # Autoscaling configuration (with defaults)
  autoscaling_min = try(local.config.autoscaling.min_nodes, 0)
  autoscaling_max = try(local.config.autoscaling.max_nodes, 10)

  # NFS configuration (with defaults)
  nfs_enabled = try(local.config.nebius.nfs.enabled, true)
  nfs_size_gb = try(local.config.nebius.nfs.size_gb, 93)
}

# ============================================================================
# PROVIDER VARIABLES
# ============================================================================
# Note: NEBIUS_IAM_TOKEN is read directly from environment by the provider
