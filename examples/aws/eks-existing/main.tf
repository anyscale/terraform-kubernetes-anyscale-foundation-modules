# ---------------------------------------------------------------------------------------------------------------------
# Example Anyscale K8s Resources - Existing EKS Cluster
#   This template creates EKS resources for Anyscale
#   It creates:
#     - VPC
#     - EFS
#     - S3 Bucket
#     - IAM policies
# ---------------------------------------------------------------------------------------------------------------------

#trivy:ignore:avd-aws-0132
module "anyscale_s3" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3"

  module_enabled = true

  anyscale_bucket_name = "anyscale-eks-existing-${var.aws_region}"

  tags = var.tags
}


locals {
  ingress_from_cidr_map = [
    {
      rule        = "https-443-tcp"
      cidr_blocks = var.customer_ingress_cidr_ranges
    },
    {
      rule        = "ssh-tcp"
      cidr_blocks = var.customer_ingress_cidr_ranges
    }
  ]
}

# This creates a security group which will need to be modified to your specific needs for ingress from end users to Anyscale Clusters.
module "aws_anyscale_securitygroup_self" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-securitygroups"
  vpc_id = var.existing_vpc_id

  security_group_name                       = "anyscale-eks-existing"
  ingress_from_cidr_map                     = local.ingress_from_cidr_map
  ingress_with_existing_security_groups_map = []

  tags = var.tags
}

module "anyscale_efs" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs"

  module_enabled = var.enable_efs

  anyscale_efs_name          = "anyscale-eks-public-efs"
  mount_targets_subnet_count = length(var.existing_subnet_ids)
  mount_targets_subnets      = var.existing_subnet_ids

  associated_security_group_ids = [module.aws_anyscale_securitygroup_self.security_group_id]

  tags = var.tags
}

#trivy:ignore:avd-aws-0342
module "anyscale_iam_roles" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam"

  module_enabled = true

  create_anyscale_access_role          = false
  create_cluster_node_instance_profile = false

  create_iam_s3_policy   = true
  anyscale_s3_bucket_arn = module.anyscale_s3.s3_bucket_arn

  tags = var.tags
}
