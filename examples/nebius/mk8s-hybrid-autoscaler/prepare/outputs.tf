# ============================================================================
# OUTPUTS
# ============================================================================

output "bucket_name" {
  description = "Anyscale object storage bucket name"
  value       = nebius_storage_v1_bucket.anyscale.name
}

output "bucket_id" {
  description = "Anyscale object storage bucket ID"
  value       = nebius_storage_v1_bucket.anyscale.id
}

output "nfs_server_ip" {
  description = "NFS server internal IP address"
  value       = local.nfs_enabled ? try(module.nfs-server[0].nfs_server_internal_ip, "") : "NFS disabled"
}

output "nfs_enabled" {
  description = "Whether NFS is enabled"
  value       = local.nfs_enabled
}
