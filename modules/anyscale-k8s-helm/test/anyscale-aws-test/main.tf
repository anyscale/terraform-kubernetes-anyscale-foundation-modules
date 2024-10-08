# ---------------------------------------------------------------------------------------------------------------------
# CREATE Anyscale K8s Helm Resources
#   This template creates EKS resources for Anyscale
#   Requires:
#     - VPC
#     - Security Group
#     - IAM Roles
#     - EKS Cluster
#     - EKS Nodegroups
# ---------------------------------------------------------------------------------------------------------------------
locals {
  # azs = slice(data.aws_availability_zones.available.names, 0, 3)

  full_tags = merge(tomap({
    anyscale-cloud-id           = var.anyscale_cloud_id,
    anyscale-deploy-environment = var.anyscale_deploy_env
    }),
    var.tags
  )
}

# ---------------------------------------------------------------------------------------------------------------------
# Create resources for EKS TF Module
#   Creates a VPC
#   Creates a Security Group
#   Creates IAM Roles
# ---------------------------------------------------------------------------------------------------------------------
locals {
  public_subnets  = ["172.24.101.0/24", "172.24.102.0/24", "172.24.103.0/24"]
  private_subnets = ["172.24.20.0/24", "172.24.21.0/24", "172.24.22.0/24"]
}
module "eks_vpc" {
  #checkov:skip=CKV_TF_1: Test code should use the latest version of the module
  source = "../../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-vpc"

  anyscale_vpc_name = "tftest-k8s-helm"
  cidr_block        = "172.24.0.0/16"

  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets
}
locals {
  # Because subnet ID may not be known at plan time, we cannot use it as a key
  anyscale_subnet_count = length(local.private_subnets)
}

module "eks_securitygroup" {
  #checkov:skip=CKV_TF_1: Test code should use the latest version of the module
  source = "../../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-securitygroups"

  vpc_id = module.eks_vpc.vpc_id

  security_group_name_prefix = "tftest-k8s-helm-"

  ingress_with_self = [
    { rule = "all-all" }
  ]
}

module "eks_iam_roles" {
  #checkov:skip=CKV_TF_1: Test code should use the latest version of the module
  source = "../../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-iam"

  module_enabled                       = true
  create_anyscale_access_role          = false
  create_cluster_node_instance_profile = false
  create_iam_s3_policy                 = false

  create_anyscale_eks_cluster_role = true
  anyscale_eks_cluster_role_name   = "tftest-k8s-helm-cluster"
  create_anyscale_eks_node_role    = true
  anyscale_eks_node_role_name      = "tftest-k8s-helm-node-role"

  tags = local.full_tags
}

locals {
  coredns_config = jsonencode({
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [
            {
              matchExpressions = [
                {
                  key      = "node-type"
                  operator = "In"
                  values   = ["management"]
                }
              ]
            }
          ]
        }
      }
    },
    nodeSelector = {
      "node-type" = "management"
    },
    tolerations = [
      {
        key      = "CriticalAddonsOnly"
        operator = "Exists"
      },
      {
        effect = "NoSchedule"
        key    = "node-role.kubernetes.io/control-plane"
      }
    ],
    replicaCount = 2
  })
}

module "eks_cluster" {
  source = "../../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-eks-cluster"

  module_enabled = true

  anyscale_subnet_ids        = module.eks_vpc.public_subnet_ids
  anyscale_subnet_count      = local.anyscale_subnet_count
  anyscale_security_group_id = module.eks_securitygroup.security_group_id
  eks_role_arn               = module.eks_iam_roles.iam_anyscale_eks_cluster_role_arn
  anyscale_eks_name          = "tftest-k8s-helm"

  eks_addons = [
    {
      addon_name           = "coredns"
      addon_version        = "v1.11.1-eksbuild.8"
      configuration_values = local.coredns_config
    }
  ]
  eks_addons_depends_on = module.eks_nodegroups

  tags = local.full_tags

  depends_on = [module.eks_iam_roles, module.eks_vpc, module.eks_securitygroup]
}

module "eks_nodegroups" {
  source = "../../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-eks-nodegroups"

  module_enabled = true

  eks_node_role_arn = module.eks_iam_roles.iam_anyscale_eks_node_role_arn
  eks_cluster_name  = module.eks_cluster.eks_cluster_name
  subnet_ids        = module.eks_vpc.public_subnet_ids

  tags = local.full_tags
}

# ---------------------------------------------------------------------------------------------------------------------
# Create Helm Resources with no optional parameters
# ---------------------------------------------------------------------------------------------------------------------
module "all_defaults" {
  source = "../../"

  module_enabled = true
  cloud_provider = "aws"

  kubernetes_cluster_name = module.eks_cluster.eks_cluster_name

  depends_on = [module.eks_nodegroups]
}

# ---------------------------------------------------------------------------------------------------------------------
# Create Helm Resources with as many optional parameters as possible - not currently working.
# ---------------------------------------------------------------------------------------------------------------------
# module "kitchen_sink" {
#   source = "../../"

#   module_enabled = true
#   cloud_provider = "aws"

#   kubernetes_cluster_name = module.eks_cluster.eks_cluster_name

#   anyscale_cluster_autoscaler_chart = {
#     enabled = false
#   }
#   anyscale_nvidia_device_plugin_chart = {
#     enabled = false
#   }

#   anyscale_metrics_server_chart = {
#     enabled = false
#   }

#   anyscale_ingress_chart = {
#     enabled       = true
#     name          = "kitchensink-ingress"
#     repository    = "https://kubernetes.github.io/ingress-nginx"
#     chart         = "ingress-nginx"
#     chart_version = "4.11.1"
#     namespace     = "kitchensink-ingress-nginx"
#     values = {
#       "controller.service.type"            = "LoadBalancer"
#       "controller.allowSnippetAnnotations" = "true"
#       "controller.autoscaling.enabled"     = "true"
#     }
#   }
#   anyscale_ingress_aws_nlb_internal = true

#   depends_on = [module.eks_nodegroups]
# }

# ---------------------------------------------------------------------------------------------------------------------
# Do not create any resources
# ---------------------------------------------------------------------------------------------------------------------
module "test_no_resources" {
  source = "../.."

  module_enabled = false
  cloud_provider = "aws"
}
