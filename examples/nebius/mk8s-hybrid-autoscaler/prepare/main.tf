# ============================================================================
# ANYSCALE ON NEBIUS - INFRASTRUCTURE PREPARATION
# ============================================================================
# Creates NFS server and object storage bucket for Anyscale
# ============================================================================

# ============================================================================
# NFS SERVER (Conditional - based on config.yaml)
# ============================================================================

data "nebius_vpc_v1_subnet" "subnet" {
  id = local.nebius_vpc_subnet_id
}

# We'll use the NFS module for now since it works fine
# Can be replaced with custom resources if needed
module "nfs-server" {
  count  = local.nfs_enabled ? 1 : 0
  source = "../../../shared/nebius-solution-library/nfs-server"

  providers = {
    nebius = nebius
  }

  parent_id = local.nebius_project_id
  subnet_id = local.nebius_vpc_subnet_id
  region    = local.nebius_region

  ssh_user_name   = local.ssh_user_name
  ssh_public_keys = [local.ssh_public_key]

  nfs_ip_range = try(flatten(data.nebius_vpc_v1_subnet.subnet.ipv4_private_pools.pools)[0].cidr, "")

  # Use small CPU node for NFS
  cpu_nodes_platform = "cpu-e2"
  cpu_nodes_preset   = "2vcpu-8gb"
  nfs_size           = local.nfs_size_gb * 1024 * 1024 * 1024
}

# ============================================================================
# OBJECT STORAGE BUCKET
# ============================================================================

resource "nebius_storage_v1_bucket" "anyscale" {
  parent_id         = local.nebius_project_id
  name              = "anyscale-${replace(lower(local.anyscale_cloud_name), "/[^a-z0-9-]/", "-")}"
  versioning_policy = "DISABLED"
}
