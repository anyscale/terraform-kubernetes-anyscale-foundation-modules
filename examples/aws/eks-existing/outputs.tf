locals {
  kubernetes_zones = join(",", module.anyscale_vpc.availability_zones)
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
      --region ${var.aws_region} \
      --s3-bucket-id ${module.anyscale_s3.s3_bucket_id} \
      --efs-id ${module.anyscale_efs.efs_id} \
      --kubernetes-zones ${local.kubernetes_zones} \
      --anyscale-operator-iam-identity <node_IAM_role_arn>
  EOT
}
