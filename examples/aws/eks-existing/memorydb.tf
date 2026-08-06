#################################################################
# Optional Anyscale-managed MemoryDB (Redis) cluster.
#
# When enable_memorydb = true, this provisions a MemoryDB cluster
# via the upstream `aws-anyscale-memorydb` submodule. The cluster
# endpoint is exposed via the `memorydb_endpoint` output and gets
# appended to the Anyscale registration command as
# `--memorydb-cluster-id`, so Anyscale Services head-node fault
# tolerance is wired at registration time (Anyscale CLI/SDK
# >= 0.26.99 required).
#
# Since this example brings its own EKS cluster, you must tell us
# which security group(s) are allowed to reach the MemoryDB SG via
# `memorydb_allowed_security_group_ids` — typically that's your
# EKS managed-node-group security group.
#################################################################

#trivy:ignore:avd-aws-0104
resource "aws_security_group" "memorydb" {
  #checkov:skip=CKV2_AWS_5: "Ensure that Security Groups are attached to another resource" - attached via aws_anyscale_memorydb module.
  count = var.enable_memorydb ? 1 : 0

  name        = "anyscale-eks-existing-memorydb"
  description = "Anyscale MemoryDB ingress from user-provided EKS node security groups."
  vpc_id      = var.existing_vpc_id

  dynamic "ingress" {
    for_each = var.memorydb_allowed_security_group_ids
    content {
      description     = "Redis from caller-allowed SG"
      from_port       = var.memorydb_port
      to_port         = var.memorydb_port
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }

  tags = var.tags
}

module "anyscale_memorydb" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-memorydb"

  module_enabled = var.enable_memorydb

  anyscale_memorydb_name_prefix = "anyscale-mdb-"

  memorydb_subnet_ids             = var.existing_subnet_ids
  memorydb_security_group_ids     = var.enable_memorydb ? [aws_security_group.memorydb[0].id] : []
  memorydb_port                   = var.memorydb_port
  memorydb_node_type              = var.memorydb_node_type
  memorydb_num_shards             = var.memorydb_num_shards
  memorydb_num_replicas_per_shard = var.memorydb_num_replicas_per_shard

  tags = var.tags
}
