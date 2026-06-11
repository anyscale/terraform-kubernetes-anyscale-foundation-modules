locals {
  efa_capacity_reservation_enabled = var.efa_capacity_reservation_id != null && var.efa_capacity_reservation_id != ""
  efa_node_subnet_id               = local.efa_capacity_reservation_enabled ? aws_subnet.efa_private[0].id : module.anyscale_vpc.private_subnet_ids[0]
  efa_node_availability_zone       = local.efa_capacity_reservation_enabled ? aws_subnet.efa_private[0].availability_zone : module.anyscale_vpc.availability_zones[0]
}

resource "aws_subnet" "efa_private" {
  count = local.efa_capacity_reservation_enabled ? 1 : 0

  vpc_id               = module.anyscale_vpc.vpc_id
  cidr_block           = var.efa_private_subnet_cidr
  availability_zone_id = var.efa_capacity_reservation_az_id

  tags = merge(var.tags, {
    "Name"                            = "anyscale-${var.eks_cluster_name}-private-efa"
    "kubernetes.io/role/internal-elb" = "1"
  })

  lifecycle {
    precondition {
      condition     = var.efa_capacity_reservation_az_id != null && var.efa_capacity_reservation_az_id != ""
      error_message = "efa_capacity_reservation_az_id is required when efa_capacity_reservation_id is set."
    }
  }
}

resource "aws_route_table_association" "efa_private" {
  count = local.efa_capacity_reservation_enabled ? 1 : 0

  subnet_id      = aws_subnet.efa_private[0].id
  route_table_id = module.anyscale_vpc.private_route_table_ids[0]
}
