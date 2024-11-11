locals {
  kubernetes_zones = join(",", module.anyscale_vpc.availability_zones)
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster."
  value       = module.anyscale_eks_cluster.eks_cluster_name
}

output "anyscale_register_command" {
  description = <<-EOF
    Anyscale register command.
    This output can be used with the Anyscale CLI to register a new Anyscale Cloud.
    You will need to replace `<CUSTOMER_DEFINED_NAME>` with a name of your choosing before running the Anyscale CLI command.
  EOF
  value       = <<-EOT
    anyscale cloud register --provider aws \
    --name <CUSTOMER_DEFINED_NAME> \
    --compute-stack k8s \
    --anyscale-iam-role-id ${module.anyscale_iam_roles.iam_anyscale_access_role_arn} \
    --region ${var.aws_region} \
    --s3-bucket-id ${module.anyscale_s3.s3_bucket_id} \
    --efs-id ${module.anyscale_efs.efs_id} \
    --kubernetes-zones ${local.kubernetes_zones} \
    --anyscale-operator-iam-identity ${module.anyscale_iam_roles.iam_anyscale_eks_node_role_arn}
  EOT
}
