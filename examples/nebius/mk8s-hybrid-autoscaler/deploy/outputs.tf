# ============================================================================
# OUTPUTS
# ============================================================================

output "cluster_id" {
  description = "Kubernetes cluster ID"
  value       = nebius_mk8s_v1_cluster.anyscale.id
}

output "cluster_name" {
  description = "Kubernetes cluster name"
  value       = nebius_mk8s_v1_cluster.anyscale.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = "Run: nebius mk8s cluster get-credentials ${nebius_mk8s_v1_cluster.anyscale.id} --parent-id ${local.nebius_project_id}"
}

output "node_group_ids" {
  description = "Map of instance type to node group ID"
  value = {
    for k, ng in nebius_mk8s_v1_node_group.instance_type : k => ng.id
  }
}

output "anyscale_operator_release_id" {
  description = "Anyscale operator Helm release ID"
  value       = nebius_applications_v1alpha1_k8s_release.anyscale_operator.id
}

output "kubeconfig_command" {
  description = "Command to get kubeconfig"
  value       = "nebius mk8s cluster get-credentials ${nebius_mk8s_v1_cluster.anyscale.id} --parent-id ${local.nebius_project_id}"
}

output "instance_types" {
  description = "Available instance types"
  value       = keys(local.instance_types)
}
