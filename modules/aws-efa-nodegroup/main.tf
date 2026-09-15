# ---------------------------------------------------------------------------------------------------------------------
# AWS EKS EFA Managed Node Group
#
# This module creates the infrastructure layer required before Kubernetes can expose EFA devices to Pods:
# a cluster placement group, an EFA-friendly security group, a launch template with EFA-only network interfaces,
# and an EKS managed node group pinned to one subnet/AZ.
# ---------------------------------------------------------------------------------------------------------------------

data "aws_subnet" "selected" {
  id = var.subnet_id
}

locals {
  name_prefix = coalesce(var.name_prefix, "${var.cluster_name}-${var.workload_name}-")

  module_tags = {
    tf_sub_module = "aws-efa-nodegroup"
  }

  efa_security_group_id = var.create_efa_security_group ? aws_security_group.efa[0].id : var.efa_security_group_id

  security_group_ids = distinct(compact(concat(
    [local.efa_security_group_id],
    var.additional_security_group_ids
  )))

  default_network_interfaces = concat(
    [
      {
        network_card_index = 0
        device_index       = 0
        interface_type     = "interface"
      }
    ],
    var.efa_interface_count > 0 ? [
      {
        network_card_index = 0
        device_index       = 1
        interface_type     = "efa-only"
      }
    ] : [],
    [
      for index in range(1, var.efa_interface_count) : {
        network_card_index = index
        device_index       = 0
        interface_type     = "efa-only"
      }
    ]
  )

  network_interfaces = var.network_interfaces == null ? local.default_network_interfaces : var.network_interfaces

  h100_node_labels = {
    (var.workload_label_key)             = var.workload_name
    "accelerator"                        = "h100"
    "efa"                                = "true"
    "nvidia.com/gpu.present"             = "true"
    "nvidia.com/gpu.product"             = "NVIDIA-H100-80GB-HBM3"
    "nvidia.com/gpu.count"               = "8"
    "vpc.amazonaws.com/efa.present"      = "true"
    "vpc.amazonaws.com/efa.count"        = tostring(var.efa_interface_count)
    "node.anyscale.com/accelerator-type" = "GPU"
    "node.anyscale.com/gpu-accelerator"  = "H100"
    "node.anyscale.com/efa-enabled"      = "true"
  }

  node_labels = merge(local.h100_node_labels, var.labels)

  default_taints = [
    {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    },
    {
      key    = "node.anyscale.com/accelerator-type"
      value  = "GPU"
      effect = "NO_SCHEDULE"
    },
    {
      key    = var.workload_label_key
      value  = var.workload_name
      effect = "NO_SCHEDULE"
    },
  ]

  node_taints = var.taints == null ? local.default_taints : var.taints

  cluster_autoscaler_taint_effects = {
    NO_SCHEDULE        = "NoSchedule"
    NO_EXECUTE         = "NoExecute"
    PREFER_NO_SCHEDULE = "PreferNoSchedule"
  }

  capacity_block_enabled = var.capacity_type == "CAPACITY_BLOCK"

  launch_template_name_prefix = coalesce(var.launch_template_name_prefix, "${local.name_prefix}lt-")
  node_group_name             = coalesce(var.node_group_name, "${local.name_prefix}nodegroup")
  placement_group_name        = coalesce(var.placement_group_name, "${local.name_prefix}pg")

  cluster_autoscaler_tags = var.enable_cluster_autoscaler_tags ? merge(
    {
      "k8s.io/cluster-autoscaler/enabled"                                            = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}"                                = "owned"
      "k8s.io/cluster-autoscaler/node-template/label/eks.amazonaws.com/capacityType" = var.capacity_type
      "k8s.io/cluster-autoscaler/node-template/resources/cpu"                        = "192"
      "k8s.io/cluster-autoscaler/node-template/resources/memory"                     = "1800Gi"
      "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"             = "8"
      "k8s.io/cluster-autoscaler/node-template/resources/vpc.amazonaws.com/efa"      = tostring(var.efa_interface_count)
    },
    {
      for key, value in local.node_labels :
      "k8s.io/cluster-autoscaler/node-template/label/${key}" => value
    },
    {
      for taint in local.node_taints :
      "k8s.io/cluster-autoscaler/node-template/taint/${taint.key}" => "${taint.value}:${local.cluster_autoscaler_taint_effects[taint.effect]}"
    }
  ) : {}

  tags = merge(local.module_tags, local.cluster_autoscaler_tags, var.tags)
}

resource "aws_placement_group" "efa" {
  name     = local.placement_group_name
  strategy = "cluster"

  tags = merge(
    {
      Name = local.placement_group_name
    },
    local.tags
  )
}

resource "aws_security_group" "efa" {
  count = var.create_efa_security_group ? 1 : 0

  name        = var.efa_security_group_name
  name_prefix = var.efa_security_group_name == null ? coalesce(var.efa_security_group_name_prefix, "${local.name_prefix}efa-sg-") : null
  description = "Security group for EKS EFA worker nodes"
  vpc_id      = var.vpc_id

  revoke_rules_on_delete = var.revoke_security_group_rules_on_delete

  tags = merge(
    {
      Name = coalesce(var.efa_security_group_name, "${local.name_prefix}efa-sg")
    },
    local.tags
  )
}

resource "aws_security_group_rule" "efa_self_ingress" {
  count = var.create_efa_security_group ? 1 : 0

  security_group_id = aws_security_group.efa[0].id
  type              = "ingress"
  self              = true
  description       = "Allow all node-to-node EFA traffic inside the EFA node group"
  from_port         = -1
  to_port           = -1
  protocol          = "-1"
}

resource "aws_security_group_rule" "efa_self_egress" {
  count = var.create_efa_security_group ? 1 : 0

  security_group_id = aws_security_group.efa[0].id
  type              = "egress"
  self              = true
  description       = "Allow all node-to-node EFA traffic inside the EFA node group"
  from_port         = -1
  to_port           = -1
  protocol          = "-1"
}

resource "aws_security_group_rule" "efa_all_egress" {
  count = var.create_efa_security_group && var.allow_all_egress ? 1 : 0

  security_group_id = aws_security_group.efa[0].id
  type              = "egress"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Allow outbound control-plane, registry, and package traffic"
  from_port         = -1
  to_port           = -1
  protocol          = "-1"
}

resource "aws_security_group_rule" "cluster_ingress" {
  for_each = var.create_efa_security_group ? {
    for index, security_group_id in var.cluster_security_group_ids : index => security_group_id
  } : {}

  security_group_id        = aws_security_group.efa[0].id
  type                     = "ingress"
  source_security_group_id = each.value
  description              = "Allow EKS control-plane security group traffic to EFA nodes"
  from_port                = -1
  to_port                  = -1
  protocol                 = "-1"
}

resource "aws_launch_template" "efa" {
  name_prefix   = local.launch_template_name_prefix
  instance_type = var.instance_type
  image_id      = var.ami_id

  update_default_version = true

  dynamic "instance_market_options" {
    for_each = local.capacity_block_enabled ? [1] : []

    content {
      market_type = "capacity-block"
    }
  }

  dynamic "capacity_reservation_specification" {
    for_each = var.capacity_reservation_id != null ? [1] : []

    content {
      capacity_reservation_target {
        capacity_reservation_id = var.capacity_reservation_id
      }
    }
  }

  placement {
    group_name = aws_placement_group.efa.name
  }

  block_device_mappings {
    device_name = var.root_block_device_name

    ebs {
      delete_on_termination = true
      encrypted             = var.root_volume_encrypted
      volume_size           = var.root_volume_size_gb
      volume_type           = var.root_volume_type
    }
  }

  dynamic "network_interfaces" {
    for_each = local.network_interfaces

    content {
      associate_public_ip_address = false
      delete_on_termination       = true
      device_index                = network_interfaces.value.device_index
      interface_type              = network_interfaces.value.interface_type
      network_card_index          = network_interfaces.value.network_card_index
      security_groups             = local.security_group_ids
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      {
        Name = local.node_group_name
      },
      local.tags
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(
      {
        Name = local.node_group_name
      },
      local.tags
    )
  }

  tag_specifications {
    resource_type = "network-interface"

    tags = merge(
      {
        Name = local.node_group_name
      },
      local.tags
    )
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.create_efa_security_group || var.efa_security_group_id != null
      error_message = "efa_security_group_id is required when create_efa_security_group is false."
    }

    precondition {
      condition     = !local.capacity_block_enabled || var.capacity_reservation_id != null
      error_message = "capacity_reservation_id is required when capacity_type is CAPACITY_BLOCK."
    }
  }
}

resource "aws_eks_node_group" "efa" {
  cluster_name    = var.cluster_name
  node_group_name = local.node_group_name
  node_role_arn   = var.node_role_arn
  subnet_ids      = [var.subnet_id]

  ami_type      = var.ami_id == null ? var.ami_type : null
  capacity_type = var.capacity_type
  labels        = local.node_labels

  launch_template {
    id      = aws_launch_template.efa.id
    version = aws_launch_template.efa.default_version
  }

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  update_config {
    max_unavailable = var.update_max_unavailable
  }

  dynamic "taint" {
    for_each = local.node_taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = local.tags

  lifecycle {
    precondition {
      condition     = var.availability_zone == null || data.aws_subnet.selected.availability_zone == var.availability_zone
      error_message = "subnet_id must be in availability_zone when availability_zone is set."
    }

    precondition {
      condition     = var.min_size <= var.desired_size && var.desired_size <= var.max_size
      error_message = "desired_size must be between min_size and max_size."
    }
  }
}

resource "aws_autoscaling_group_tag" "efa" {
  for_each = local.tags

  autoscaling_group_name = aws_eks_node_group.efa.resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = true
  }
}
