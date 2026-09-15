output "node_group_arn" {
  description = "ARN of the EKS managed node group."
  value       = aws_eks_node_group.efa.arn
}

output "node_group_name" {
  description = "Name of the EKS managed node group."
  value       = aws_eks_node_group.efa.node_group_name
}

output "node_group_status" {
  description = "Status of the EKS managed node group."
  value       = aws_eks_node_group.efa.status
}

output "launch_template_id" {
  description = "ID of the EFA launch template."
  value       = aws_launch_template.efa.id
}

output "launch_template_latest_version" {
  description = "Latest version of the EFA launch template."
  value       = aws_launch_template.efa.latest_version
}

output "launch_template_default_version" {
  description = "Default version of the EFA launch template."
  value       = aws_launch_template.efa.default_version
}

output "placement_group_name" {
  description = "Name of the cluster placement group."
  value       = aws_placement_group.efa.name
}

output "efa_security_group_id" {
  description = "Security group ID used by EFA network interfaces."
  value       = local.efa_security_group_id
}

output "security_group_ids" {
  description = "Full set of security group IDs attached to launch-template network interfaces."
  value       = local.security_group_ids
}

output "subnet_availability_zone" {
  description = "Availability Zone of subnet_id."
  value       = data.aws_subnet.selected.availability_zone
}

output "network_interfaces" {
  description = "Network interface layout rendered into the launch template."
  value       = local.network_interfaces
}
