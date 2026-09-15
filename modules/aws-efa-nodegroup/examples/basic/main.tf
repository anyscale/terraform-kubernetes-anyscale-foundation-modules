terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "h100_efa_nodegroup" {
  source = "../.."

  cluster_name  = var.cluster_name
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id
  node_role_arn = var.node_role_arn

  availability_zone = var.availability_zone

  desired_size = var.desired_size
  min_size     = var.min_size
  max_size     = var.max_size

  cluster_security_group_ids    = var.cluster_security_group_ids
  additional_security_group_ids = var.additional_security_group_ids

  capacity_type           = var.capacity_type
  capacity_reservation_id = var.capacity_reservation_id

  tags = var.tags
}
