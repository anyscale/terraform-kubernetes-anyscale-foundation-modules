locals {
  kubernetes_zones = join(",", module.anyscale_vpc.availability_zones)
}

data "aws_iam_role" "default_nodegroup" {
  name = module.eks.eks_managed_node_groups["default"].iam_role_name
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster. This is used for Helm chart values."
  value       = var.eks_cluster_name
}

output "aws_region" {
  description = "The AWS region. This is used for Helm chart values."
  value       = var.aws_region
}

locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--region ${var.aws_region}",
    "--provider aws",
    "--compute-stack k8s",
    "--kubernetes-zones ${local.kubernetes_zones}",
    "--s3-bucket-id ${module.anyscale_s3.s3_bucket_id}",
    var.enable_efs ? "--efs-id ${module.anyscale_efs.efs_id}" : null,
    "--anyscale-operator-iam-identity ${data.aws_iam_role.default_nodegroup.arn}",
  ])

  helm_upgrade_command_parts = compact([
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string cloudDeploymentId=<cloud-deployment-id>",
    "--set-string cloudProvider=aws",
    "--set-string region=${var.aws_region}",
    "--set-string workloadServiceAccountName=anyscale-operator",
    "--namespace anyscale-operator",
    "--create-namespace",
    "-i"
  ])
}

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = join(" \\\n\t", local.registration_command_parts)
}

output "helm_upgrade_command" {
  description = "The helm upgrade command."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}
