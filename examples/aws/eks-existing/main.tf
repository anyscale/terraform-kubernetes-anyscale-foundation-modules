# ---------------------------------------------------------------------------------------------------------------------
# Example Anyscale K8s Resources - Public Networking
#   This template creates EKS resources for Anyscale
#   It creates:
#     - VPC
#     - EFS
#     - S3 Bucket
#     - IAM policies
# ---------------------------------------------------------------------------------------------------------------------

locals {
  public_subnets  = ["172.24.101.0/24", "172.24.102.0/24", "172.24.103.0/24"]
  private_subnets = ["172.24.20.0/24", "172.24.21.0/24", "172.24.22.0/24"]
}

module "anyscale_vpc" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-vpc"

  anyscale_vpc_name = "anyscale-eks-public"
  cidr_block        = "172.24.0.0/16"

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

#trivy:ignore:avd-aws-0132
module "anyscale_s3" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3"

  module_enabled = true

  anyscale_bucket_name = "anyscale-eks-public-${var.aws_region}"
  force_destroy        = true
  cors_rule            = var.anyscale_s3_cors_rule

  tags = var.tags
}

#trivy:ignore:avd-aws-0104
resource "aws_security_group" "allow_all_vpc" {
  #checkov:skip=CKV2_AWS_5: "Ensure that Security Groups are attached to another resource"
  name        = "allow-all-vpc"
  description = "Allow all traffic within the VPC"
  vpc_id      = module.anyscale_vpc.vpc_id

  ingress {
    description = "Allow all traffic from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [module.anyscale_vpc.vpc_cidr_block]
  }

  egress {
    description = "Allow all traffic to the internet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

module "anyscale_efs" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs"

  module_enabled = true

  anyscale_efs_name          = "anyscale-eks-public-efs"
  mount_targets_subnet_count = length(local.private_subnets)
  mount_targets_subnets      = module.anyscale_vpc.private_subnet_ids

  associated_security_group_ids = [aws_security_group.allow_all_vpc.id]

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
