# This EFA worker pool extends the standard Anyscale EKS public example with a
# p5.48xlarge H100 node group.
module "h100_efa_nodegroup" {
  source = "../../../modules/aws-efa-nodegroup"

  cluster_name  = var.eks_cluster_name
  vpc_id        = module.anyscale_vpc.vpc_id
  subnet_id     = local.efa_node_subnet_id
  node_role_arn = data.aws_iam_role.default_nodegroup.arn

  availability_zone = local.efa_node_availability_zone
  workload_name     = var.efa_workload_name

  cluster_security_group_ids = [
    module.eks.cluster_security_group_id,
  ]

  additional_security_group_ids = [
    module.eks.node_security_group_id,
  ]

  instance_type = "p5.48xlarge"
  ami_type      = "AL2023_x86_64_NVIDIA"

  capacity_type           = "ON_DEMAND"
  capacity_reservation_id = var.efa_capacity_reservation_id

  min_size     = 0
  desired_size = 0
  max_size     = 4

  root_volume_size_gb = var.node_group_disk_size

  tags = var.tags

  depends_on = [
    module.eks,
  ]
}
