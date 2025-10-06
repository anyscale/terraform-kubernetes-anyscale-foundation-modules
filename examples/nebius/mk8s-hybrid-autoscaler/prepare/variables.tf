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

  # SSH configuration
  ssh_user_name  = local.config.ssh.username
  ssh_public_key = local.config.ssh.public_key

  # NFS configuration (with defaults)
  nfs_enabled = try(local.config.nebius.nfs.enabled, true)
  nfs_size_gb = try(local.config.nebius.nfs.size_gb, 93)

  # Anyscale cloud name for bucket naming
  anyscale_cloud_name = local.config.anyscale.cloud_name
}

# ============================================================================
# PROVIDER VARIABLES
# ============================================================================
# Note: NEBIUS_IAM_TOKEN is read directly from environment by the provider
