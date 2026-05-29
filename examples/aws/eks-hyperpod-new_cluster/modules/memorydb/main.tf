# ----------------------------------------------------------------------------
# Amazon MemoryDB cluster used as the Redis-compatible external storage backend
# for Anyscale head node fault tolerance.
#
# Anyscale requires a SINGLE-SHARD, >= 1-replica, TLS-enabled Redis-compatible
# cluster reachable from the Kubernetes data plane. MemoryDB satisfies all three
# and is the AWS-native, durable option (vs. an in-cluster Redis pod).
#
# The cluster's TLS uses an AWS-managed public CA, so Anyscale needs no custom
# certificate_path — the default ca-certificates bundle validates it. Connect
# with the `rediss://` scheme (see the redis_endpoint output).
# ----------------------------------------------------------------------------

# MemoryDB cluster + subnet group names must be lowercase alphanumeric/hyphens
# (no underscores), so sanitize the prefix the same way the s3_bucket module does.
locals {
  name = "${replace(lower(var.resource_name_prefix), "_", "-")}-memorydb"
}

resource "aws_security_group" "memorydb" {
  name        = local.name
  description = "Allow Redis access to the Anyscale head-node-fault-tolerance MemoryDB cluster from the cluster data plane."
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from the shared EKS + HyperPod cluster security group."
    from_port       = var.port
    to_port         = var.port
    protocol        = "tcp"
    security_groups = [var.source_security_group_id]
  }

  egress {
    description = "Allow all outbound."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({ Name = local.name }, var.tags)
}

resource "aws_memorydb_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = var.tags
}

resource "aws_memorydb_cluster" "this" {
  name      = local.name
  node_type = var.node_type

  # Single shard with one replica — the configuration Anyscale supports for head
  # node fault tolerance (multi-shard is NOT supported).
  num_shards             = 1
  num_replicas_per_shard = 1

  port               = var.port
  tls_enabled        = true
  subnet_group_name  = aws_memorydb_subnet_group.this.name
  security_group_ids = [aws_security_group.memorydb.id]

  # "open-access" is the built-in MemoryDB ACL (no auth). Network isolation is
  # provided by the dedicated security group above. To require auth, replace this
  # with an aws_memorydb_acl + aws_memorydb_user and supply the credentials to
  # Anyscale via the redis_endpoint.
  acl_name = "open-access"

  tags = var.tags
}
