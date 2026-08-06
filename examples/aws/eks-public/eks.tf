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
  anyscale_iam = merge(
    {
      anyscale_s3_policy = module.anyscale_iam_roles.anyscale_iam_s3_policy_arn,
    },
    var.enable_efs ? {
      efs_client_policy = "arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess",
    } : {}
  )

  node_group_block_device_mappings = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        delete_on_termination = true
        volume_size           = var.node_group_disk_size
        volume_type           = "gp3"
      }
    }
  }

  # v21 of the EKS module sets http_put_response_hop_limit = 1 by default,
  # which prevents pods (AWS Load Balancer Controller, cluster-autoscaler,
  # anything reaching the EC2 metadata service from inside a pod) from
  # assuming the node IAM role via IMDSv2. We restore the v20 default of 2
  # so the canonical helm installs work out of the box. For a tighter
  # security posture, set this back to 1 and switch each AWS-API-consuming
  # workload to IRSA or EKS Pod Identity.
  node_group_metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Base configuration for GPU node groups.
  # use_custom_launch_template = true so the launch template controls disk
  # (via block_device_mappings) AND the IMDS metadata_options are guaranteed
  # to apply — the module's metadata_options input is only authoritative when
  # the module is also managing the launch template.
  gpu_node_group_base = {
    ami_type                     = "AL2023_x86_64_NVIDIA"
    min_size                     = 0
    max_size                     = 10
    desired_size                 = 0
    use_custom_launch_template   = true
    block_device_mappings        = local.node_group_block_device_mappings
    iam_role_additional_policies = local.anyscale_iam
    metadata_options             = local.node_group_metadata_options
  }

  # Node group taints. v21 of the EKS module takes `taints` as a map (keyed by
  # a stable identifier of your choosing) rather than a list.
  gpu_node_taints_base = {
    gpu = {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
    accelerator_type = {
      key    = "node.anyscale.com/accelerator-type"
      value  = "GPU"
      effect = "NO_SCHEDULE"
    }
  }

  gpu_node_taints_ondemand = merge(local.gpu_node_taints_base, {
    capacity_type = {
      key    = "node.anyscale.com/capacity-type"
      value  = "ON_DEMAND"
      effect = "NO_SCHEDULE"
    }
  })

  gpu_node_taints_spot = merge(local.gpu_node_taints_base, {
    capacity_type = {
      key    = "node.anyscale.com/capacity-type"
      value  = "SPOT"
      effect = "NO_SCHEDULE"
    }
  })

  # Create a map of GPU node groups based on gpu_instance_types
  gpu_node_groups = {
    for gpu_type in keys(var.gpu_instance_types) : gpu_type => {
      ondemand = merge(
        local.gpu_node_group_base,
        {
          instance_types = var.gpu_instance_types[gpu_type].instance_types
          capacity_type  = "ON_DEMAND"
          labels = {
            "nvidia.com/gpu.product" = var.gpu_instance_types[gpu_type].product_name
            "nvidia.com/gpu.count"   = "1"
          }
          taints = local.gpu_node_taints_ondemand
        }
      )
      spot = merge(
        local.gpu_node_group_base,
        {
          instance_types = var.gpu_instance_types[gpu_type].instance_types
          capacity_type  = "SPOT"
          labels = {
            "nvidia.com/gpu.product" = var.gpu_instance_types[gpu_type].product_name
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
  version = "21.20.0"

  # Cluster basic configuration (v21 input names: cluster_* prefix dropped,
  # cluster_version -> kubernetes_version).
  name               = var.eks_cluster_name
  kubernetes_version = var.eks_cluster_version

  addons = merge(
    {
      # vpc-cni and kube-proxy must come up before the managed node groups —
      # without the CNI, kubelet can't initialise its network plugin and nodes
      # stay NotReady forever. v21 of the terraform-aws-eks module does not
      # auto-install default addons, so they must be declared explicitly.
      vpc-cni = {
        before_compute = true
      }
      kube-proxy = {
        before_compute = true
      }
      coredns                = {}
      eks-pod-identity-agent = {}
    },
    var.enable_s3_pvc ? {
      aws-mountpoint-s3-csi-driver = {
        # Mountpoint-for-S3 CSI driver installed as an EKS managed addon (vs. helm)
        # so AWS manages upgrades. The bundled pod_identity_association atomically
        # binds the s3-csi-driver-sa service account to the IAM role created in
        # s3_csi.tf, so the controller pods start with bucket access from the
        # first reconcile.
        pod_identity_association = [
          {
            role_arn        = aws_iam_role.s3_csi_driver[0].arn
            service_account = "s3-csi-driver-sa"
          }
        ]
      }
    } : {},
  )

  # Public API endpoint (this is the public-networking example).
  endpoint_public_access = true

  # The authentication mode for the cluster. Valid values are `CONFIG_MAP`, `API` or `API_AND_CONFIG_MAP`
  authentication_mode = "API_AND_CONFIG_MAP"

  # Optional: Adds the current caller identity as an administrator via cluster access entry
  enable_cluster_creator_admin_permissions = true

  vpc_id                   = module.anyscale_vpc.vpc_id
  control_plane_subnet_ids = module.anyscale_vpc.public_subnet_ids
  subnet_ids               = module.anyscale_vpc.private_subnet_ids

  node_security_group_additional_rules = {
    anyscale_ingress_nodes = {
      description = "Node to node ingress - all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    anyscale_egress_nodes = {
      description = "Node to node egress - all traffic"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      self        = true
    }
  }

  #############################################################
  # Managed Node Groups configuration example
  #############################################################

  eks_managed_node_groups = merge(
    {
      # This node group is for management components such as CoreDNS, Cluster Autoscaler, AWS-LB controller, Anyscale Operator, etc.
      # Note that small instance types of Anyscale workloads can still be scheduled onto this node group.
      default = {
        ami_type       = "AL2023_x86_64_STANDARD"
        instance_types = ["t3.medium"]

        min_size     = 1
        max_size     = 10
        desired_size = 2

        metadata_options = local.node_group_metadata_options

        iam_role_additional_policies = merge(local.anyscale_iam, {
          cluster_autoscaler_policy = aws_iam_policy.autoscaler_policy.arn
          elb_policy                = aws_iam_policy.elb_policy.arn
        })
      }

      ondemand_cpu = {
        ami_type = "AL2023_x86_64_STANDARD"
        instance_types = [
          "m5.8xlarge",
          "m5.4xlarge",
        ]

        capacity_type              = "ON_DEMAND"
        min_size                   = 0
        max_size                   = 10
        desired_size               = 0
        block_device_mappings      = local.node_group_block_device_mappings
        use_custom_launch_template = true
        metadata_options           = local.node_group_metadata_options

        taints = {
          capacity_type = {
            key    = "node.anyscale.com/capacity-type"
            value  = "ON_DEMAND"
            effect = "NO_SCHEDULE"
          }
        }

        iam_role_additional_policies = local.anyscale_iam
      }

      spot_cpu = {
        ami_type = "AL2023_x86_64_STANDARD"
        instance_types = [
          "m5.8xlarge",
          "m5.4xlarge",
        ]

        capacity_type              = "SPOT"
        min_size                   = 0
        max_size                   = 10
        desired_size               = 0
        block_device_mappings      = local.node_group_block_device_mappings
        use_custom_launch_template = true
        metadata_options           = local.node_group_metadata_options

        taints = {
          capacity_type = {
            key    = "node.anyscale.com/capacity-type"
            value  = "SPOT"
            effect = "NO_SCHEDULE"
          }
        }

        iam_role_additional_policies = local.anyscale_iam
      }
    },
    # Merge in GPU node groups based on gpu_instance_types
    {
      for gpu_type in keys(var.gpu_instance_types) : "ondemand_gpu_${lower(gpu_type)}" => local.gpu_node_groups[gpu_type].ondemand
    },
    {
      for gpu_type in keys(var.gpu_instance_types) : "spot_gpu_${lower(gpu_type)}" => local.gpu_node_groups[gpu_type].spot
    }
  )

  tags = var.tags
}

#trivy:ignore:avd-aws-0057
resource "aws_iam_policy" "autoscaler_policy" {
  #checkov:skip=CKV_AWS_290: Ensure IAM policies does not allow write access without constraints
  #checkov:skip=CKV_AWS_355: Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions
  name        = "${var.eks_cluster_name}-autoscaler-policy"
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
  name        = "${var.eks_cluster_name}-elb-policy"
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
