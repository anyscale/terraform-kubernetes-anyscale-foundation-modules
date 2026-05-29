output "memorydb_cluster_name" {
  description = "Name of the MemoryDB cluster."
  value       = aws_memorydb_cluster.this.name
}

output "memorydb_cluster_endpoint_address" {
  description = "Cluster configuration endpoint hostname of the MemoryDB cluster."
  value       = aws_memorydb_cluster.this.cluster_endpoint[0].address
}

output "memorydb_cluster_endpoint_port" {
  description = "Port of the MemoryDB cluster."
  value       = aws_memorydb_cluster.this.cluster_endpoint[0].port
}

output "redis_endpoint" {
  description = "TLS Redis endpoint to set as redis_endpoint in the Anyscale cloud resource (kubernetes_config)."
  value       = "rediss://${aws_memorydb_cluster.this.cluster_endpoint[0].address}:${aws_memorydb_cluster.this.cluster_endpoint[0].port}"
}

output "memorydb_security_group_id" {
  description = "ID of the security group fronting the MemoryDB cluster."
  value       = aws_security_group.memorydb.id
}
