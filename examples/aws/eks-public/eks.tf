#################################################################
# Terraform configuration to create a new Amazon EKS cluster
#
# This example uses the official EKS module:
# https://registry.terraform.io/modules/terraform-aws-modules/eks/aws/latest
#
# It demonstrated creation of different kinds of managed node groups:
# - on-demand CPU
# - on-demand GPU
# - spot CPU
# - spot GPU
# - custom AMI with launch template
#
# For capacity reservations, refer to:
# https://aws-ia.github.io/terraform-aws-eks-blueprints/patterns/machine-learning/targeted-odcr/
#
#################################################################

locals {
  anyscale_iam = {
    anyscale_s3_policy = module.anyscale_iam_roles.anyscale_iam_s3_policy_arn,
    efs_client_policy  = "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess",
  }

  # Map of GPU types to their product names and instance types
  gpu_types = {
    "T4" = {
      product_name   = "Tesla-T4"
      instance_types = ["g4dn.4xlarge"]
    }
    "A10G" = {
      product_name   = "NVIDIA-A10G"
      instance_types = ["g5.4xlarge"]
    }
  }

  # Base configuration for GPU node groups
  gpu_node_group_base = {
    ami_type                     = "AL2_x86_64_GPU"
    min_size                     = 0
    max_size                     = 10
    desired_size                 = 0
    iam_role_additional_policies = local.anyscale_iam
  }

  gpu_node_taints_base = [
    {
      key    = "nvidia.com/gpu",
      value  = "present",
      effect = "NO_SCHEDULE",
    },
    {
      key    = "node.anyscale.com/accelerator-type",
      value  = "GPU",
      effect = "NO_SCHEDULE",
    }
  ]

  gpu_node_taints_ondemand = concat(local.gpu_node_taints_base, [
    {
      key    = "node.anyscale.com/capacity-type",
      value  = "ON_DEMAND",
      effect = "NO_SCHEDULE",
    }
  ])

  gpu_node_taints_spot = concat(local.gpu_node_taints_base, [
    {
      key    = "node.anyscale.com/capacity-type",
      value  = "SPOT",
      effect = "NO_SCHEDULE",
    }
  ])

  # Create a map of GPU node groups based on node_group_gpu_types
  gpu_node_groups = {
    for gpu_type in var.node_group_gpu_types : gpu_type => {
      ondemand = merge(
        local.gpu_node_group_base,
        {
          instance_types = local.gpu_types[gpu_type].instance_types
          capacity_type  = "ON_DEMAND"
          labels = {
            "nvidia.com/gpu.product" = local.gpu_types[gpu_type].product_name
            "nvidia.com/gpu.count"   = "1"
          }
          taints = local.gpu_node_taints_ondemand
        }
      )
      spot = merge(
        local.gpu_node_group_base,
        {
          instance_types = local.gpu_types[gpu_type].instance_types
          capacity_type  = "SPOT"
          labels = {
            "nvidia.com/gpu.product" = local.gpu_types[gpu_type].product_name
            "nvidia.com/gpu.count"   = "1"
          }
          taints = local.gpu_node_taints_spot
        }
      )
    }
  }
}

#trivy:ignore:avd-aws-0038
#trivy:ignore:avd-aws-0040
#trivy:ignore:avd-aws-0041
#trivy:ignore:avd-aws-0104
module "eks" {
  #checkov:skip=CKV_TF_1: Use the given version of the module
  source  = "terraform-aws-modules/eks/aws"
  version = "20.33.1"

  # Cluster basic configuration
  cluster_name    = var.eks_cluster_name
  cluster_version = var.eks_cluster_version

  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy             = {}
  }

  # API endpoint access configuration
  cluster_endpoint_public_access = true

  # The authentication mode for the cluster. Valid values are `CONFIG_MAP`, `API` or `API_AND_CONFIG_MAP`
  authentication_mode = "API_AND_CONFIG_MAP"

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.anyscale_vpc.vpc_id
  control_plane_subnet_ids = module.anyscale_vpc.public_subnet_ids
  subnet_ids               = module.anyscale_vpc.private_subnet_ids

  node_security_group_additional_rules = {
    anyscale_ingress_nodes = {
      description = "Node to node ingress - Anyscale ports"
      protocol    = "tcp"
      from_port   = 80
      to_port     = 65535
      type        = "ingress"
      self        = true
    }
  }

  #############################################################
  # Managed Node Groups configuration example
  #############################################################

  eks_managed_node_groups = merge(
    {
      # This node group is for management components such as CoreDNS, Cluster Autoscaler, AWS-LB controller, ingress-nginx, Anyscale Operator, etc.
      # Note that small instance types of Anyscale workloads can still be scheduled onto this node group.
      default = {
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = ["t3.medium"]

        min_size     = 1
        max_size     = 10
        desired_size = 2

        iam_role_additional_policies = merge(local.anyscale_iam, {
          cluster_autoscaler_policy = aws_iam_policy.autoscaler_policy.arn
          elb_policy                = aws_iam_policy.elb_policy.arn
        })
      }

      ondemand_cpu = {
        ami_type = "AL2023_x86_64_STANDARD"
        instance_types = [
          "m6a.4xlarge",
          "m5a.4xlarge",
          "m6i.4xlarge",
          "m5.4xlarge",
        ]

        capacity_type = "ON_DEMAND"
        min_size      = 0
        max_size      = 10
        desired_size  = 0

        taints = [
          {
            key    = "node.anyscale.com/capacity-type",
            value  = "ON_DEMAND",
            effect = "NO_SCHEDULE",
          }
        ]

        iam_role_additional_policies = local.anyscale_iam
      }

      spot_cpu = {
        ami_type = "AL2023_x86_64_STANDARD"
        instance_types = [
          "m6a.4xlarge",
          "m5a.4xlarge",
          "m6i.4xlarge",
          "m5.4xlarge",
        ]

        capacity_type = "SPOT"
        min_size      = 0
        max_size      = 10
        desired_size  = 0

        taints = [
          {
            key    = "node.anyscale.com/capacity-type",
            value  = "SPOT",
            effect = "NO_SCHEDULE",
          }
        ]

        iam_role_additional_policies = local.anyscale_iam
      }
    },
    # Merge in GPU node groups based on node_group_gpu_types
    {
      for gpu_type in var.node_group_gpu_types : "ondemand_gpu_${lower(gpu_type)}" => local.gpu_node_groups[gpu_type].ondemand
    },
    {
      for gpu_type in var.node_group_gpu_types : "spot_gpu_${lower(gpu_type)}" => local.gpu_node_groups[gpu_type].spot
    }
  )

  tags = var.tags
}

#trivy:ignore:avd-aws-0057
resource "aws_iam_policy" "autoscaler_policy" {
  #checkov:skip=CKV_AWS_290: Ensure IAM policies does not allow write access without constraints
  #checkov:skip=CKV_AWS_355: Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions
  name        = "anyscale-eks-public-autoscaler-policy"
  description = "Policy that allows autoscaling and EC2 describe actions for EKS nodegroups."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = ["*"]
      },
      {
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = ["*"]
      }
    ]
  })

  tags = var.tags
}

# For AWS LBC:
#   https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
#trivy:ignore:avd-aws-0057
resource "aws_iam_policy" "elb_policy" {
  #checkov:skip=CKV_AWS_290: Ensure IAM policies does not allow write access without constraints
  #checkov:skip=CKV_AWS_355: Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions
  name        = "anyscale-eks-public-elb-policy"
  description = "IAM policy for AWS Load Balancer Controller in Kubernetes"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetCoipPoolUsage",
          "ec2:DescribeCoipPools",
          "ec2:GetSecurityGroupsForVpc",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTrustStores",
          "elasticloadbalancing:DescribeListenerAttributes",
          "elasticloadbalancing:DescribeCapacityReservation"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPoolClient",
          "acm:ListCertificates",
          "acm:DescribeCertificate",
          "iam:ListServerCertificates",
          "iam:GetServerCertificate",
          "waf-regional:GetWebACL",
          "waf-regional:GetWebACLForResource",
          "waf-regional:AssociateWebACL",
          "waf-regional:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "shield:GetSubscriptionState",
          "shield:DescribeProtection",
          "shield:CreateProtection",
          "shield:DeleteProtection"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = "CreateSecurityGroup"
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:DeleteRule"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags"
        ]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
          "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyListenerAttributes",
          "elasticloadbalancing:ModifyCapacityReservation"
        ]
        Resource = "*"
        Condition = {
          Null = {
            "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = ["elasticloadbalancing:AddTags"]
        Resource = [
          "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
          "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*"
        ]
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateLoadBalancer"]
          }
          Null = {
            "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets"
        ]
        Resource = "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"
      }
    ]
  })

  tags = var.tags
}
