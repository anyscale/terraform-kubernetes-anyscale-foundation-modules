#################################################################
# Optional Anyscale-managed MemoryDB (Redis) cluster.
#
# When enable_memorydb = true, this provisions a MemoryDB cluster
# via the upstream `aws-anyscale-memorydb` submodule. The cluster
# endpoint is published as `kubernetes_config.redis_endpoint` in
# the rendered cloud-resource.yaml so Anyscale Services head-node
# fault tolerance is wired at registration time (requires Anyscale
# CLI / SDK >= 0.26.99).
#
# A dedicated security group restricts ingress to the EKS managed
# node security group on var.memorydb_port (default 6379) only.
#################################################################

#trivy:ignore:avd-aws-0104
resource "aws_security_group" "memorydb" {
  #checkov:skip=CKV2_AWS_5: "Ensure that Security Groups are attached to another resource" - attached via aws_anyscale_memorydb module.
  count = var.enable_memorydb ? 1 : 0

  name        = "${var.eks_cluster_name}-memorydb"
  description = "Anyscale MemoryDB ingress from EKS workload nodes."
  vpc_id      = module.anyscale_vpc.vpc_id

  ingress {
    description     = "Redis from EKS node group"
    from_port       = var.memorydb_port
    to_port         = var.memorydb_port
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  tags = var.tags
}

module "anyscale_memorydb" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source = "github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-memorydb"

  module_enabled = var.enable_memorydb

  anyscale_memorydb_name_prefix = "anyscale-mdb-"

  memorydb_subnet_ids             = module.anyscale_vpc.private_subnet_ids
  memorydb_security_group_ids     = var.enable_memorydb ? [aws_security_group.memorydb[0].id] : []
  memorydb_port                   = var.memorydb_port
  memorydb_node_type              = var.memorydb_node_type
  memorydb_num_shards             = var.memorydb_num_shards
  memorydb_num_replicas_per_shard = var.memorydb_num_replicas_per_shard

  tags = var.tags
}
