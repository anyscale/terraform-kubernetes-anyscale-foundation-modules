output "node_group_name" {
  description = "EKS managed node group name."
  value       = module.h100_efa_nodegroup.node_group_name
}

output "launch_template_id" {
  description = "EFA launch template ID."
  value       = module.h100_efa_nodegroup.launch_template_id
}

output "placement_group_name" {
  description = "Cluster placement group name."
  value       = module.h100_efa_nodegroup.placement_group_name
}

output "efa_security_group_id" {
  description = "EFA security group ID."
  value       = module.h100_efa_nodegroup.efa_security_group_id
}
