# ----------------------------------------------------------------------------
# Raw resource outputs
# ----------------------------------------------------------------------------

# VPC outputs
output "vpc_id" {
  description = "ID of the VPC."
  value       = var.create_vpc_module ? module.vpc[0].vpc_id : var.existing_vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = var.create_vpc_module ? module.vpc[0].vpc_cidr : null
}

output "public_subnet_1_id" {
  description = "ID of the first public subnet."
  value       = var.create_vpc_module ? module.vpc[0].public_subnet_1_id : null
}

output "public_subnet_2_id" {
  description = "ID of the second public subnet."
  value       = var.create_vpc_module ? module.vpc[0].public_subnet_2_id : null
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway."
  value       = var.create_vpc_module ? module.vpc[0].nat_gateway_1_id : var.existing_nat_gateway_id
}

# Private subnet outputs
output "private_subnet_id" {
  description = "ID of the HyperPod private subnet."
  value       = var.create_private_subnet_module ? module.private_subnet[0].private_subnet_id : var.existing_private_subnet_id
}

output "private_route_table_id" {
  description = "ID of the HyperPod private route table."
  value       = var.create_private_subnet_module ? module.private_subnet[0].private_route_table_id : var.existing_private_route_table_id
}

# Security group outputs
output "security_group_id" {
  description = "ID of the cluster security group shared between EKS nodes and HyperPod instance groups."
  value       = var.create_security_group_module ? module.security_group[0].security_group_id : var.existing_security_group_id
}

# EKS outputs
output "eks_cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = var.create_eks_module ? module.eks_cluster[0].eks_cluster_arn : data.aws_eks_cluster.existing_eks_cluster[0].arn
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster."
  value       = var.create_eks_module ? module.eks_cluster[0].eks_cluster_name : var.existing_eks_cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint of the EKS cluster."
  value       = var.create_eks_module ? module.eks_cluster[0].eks_cluster_endpoint : data.aws_eks_cluster.existing_eks_cluster[0].endpoint
}

output "eks_cluster_certificate_authority" {
  description = "Certificate authority of the EKS cluster."
  value       = var.create_eks_module ? module.eks_cluster[0].eks_cluster_certificate_authority : data.aws_eks_cluster.existing_eks_cluster[0].certificate_authority[0].data
  sensitive   = true
}

# S3 outputs
output "s3_bucket_name" {
  description = "Name of the Anyscale + HyperPod shared S3 bucket."
  value       = var.create_s3_bucket_module ? module.s3_bucket[0].s3_bucket_name : var.existing_s3_bucket_name
}

output "s3_bucket_arn" {
  description = "ARN of the Anyscale + HyperPod shared S3 bucket."
  value       = var.create_s3_bucket_module ? module.s3_bucket[0].s3_bucket_arn : (var.existing_s3_bucket_name != "" ? data.aws_s3_bucket.existing_s3_bucket[0].arn : null)
}

output "s3_endpoint_id" {
  description = "ID of the S3 Gateway VPC endpoint."
  value       = var.create_s3_endpoint_module ? module.s3_endpoint[0].vpc_endpoint_id : null
}

# IAM outputs
output "sagemaker_iam_role_arn" {
  description = "ARN of the SageMaker / Anyscale operator IAM role (consumed by --anyscale-operator-iam-identity)."
  value       = var.create_sagemaker_iam_role_module ? module.sagemaker_iam_role[0].sagemaker_iam_role_arn : null
}

output "sagemaker_iam_role_name" {
  description = "Name of the SageMaker / Anyscale operator IAM role."
  value       = var.create_sagemaker_iam_role_module ? module.sagemaker_iam_role[0].sagemaker_iam_role_name : var.existing_sagemaker_iam_role_name
}

output "aws_lbc_iam_role_arn" {
  description = "ARN of the IAM role assumed by the AWS Load Balancer Controller via EKS Pod Identity."
  value       = var.create_aws_lbc_iam_role_module ? module.aws_lbc_iam_role[0].aws_lbc_iam_role_arn : null
}

# Head node fault tolerance (MemoryDB) outputs
output "redis_endpoint" {
  description = "TLS Redis endpoint for Anyscale head node fault tolerance. Set this as redis_endpoint under kubernetes_config on the Anyscale cloud resource. Null unless create_memorydb_module = true."
  value       = var.create_memorydb_module ? module.memorydb[0].redis_endpoint : null
}

# HyperPod outputs
output "hyperpod_cluster_name" {
  description = "Name of the HyperPod cluster."
  value       = local.deploy_hyperpod ? module.hyperpod_cluster[0].hyperpod_cluster_name : null
}

output "hyperpod_cluster_arn" {
  description = "ARN of the HyperPod cluster."
  value       = local.deploy_hyperpod ? module.hyperpod_cluster[0].hyperpod_cluster_arn : null
}

output "hyperpod_cluster_status" {
  description = "Status of the HyperPod cluster."
  value       = local.deploy_hyperpod ? module.hyperpod_cluster[0].hyperpod_cluster_status : null
}

# Helm chart outputs (HyperPod dependencies — Karpenter, inference add-on, etc.)
output "helm_release_name" {
  description = "Name of the HyperPod dependencies Helm release."
  value       = var.create_helm_chart_module ? module.helm_chart[0].helm_release_name : null
}

output "helm_release_status" {
  description = "Status of the HyperPod dependencies Helm release."
  value       = var.create_helm_chart_module ? module.helm_chart[0].helm_release_status : null
}

# Region
output "aws_region" {
  description = "AWS region used by the deployment."
  value       = var.aws_region
}

# ----------------------------------------------------------------------------
# Derived locals used to render helper commands
# ----------------------------------------------------------------------------

locals {
  public_subnet_1_id = var.create_vpc_module ? module.vpc[0].public_subnet_1_id : null
  public_subnet_2_id = var.create_vpc_module ? module.vpc[0].public_subnet_2_id : null

  s3_bucket_id           = var.create_s3_bucket_module ? module.s3_bucket[0].s3_bucket_arn : (var.existing_s3_bucket_name != "" ? data.aws_s3_bucket.existing_s3_bucket[0].arn : null)
  sagemaker_iam_role_arn = var.create_sagemaker_iam_role_module ? module.sagemaker_iam_role[0].sagemaker_iam_role_arn : null
  aws_lbc_iam_role_arn   = var.create_aws_lbc_iam_role_module ? module.aws_lbc_iam_role[0].aws_lbc_iam_role_arn : null
  redis_endpoint         = var.create_memorydb_module ? module.memorydb[0].redis_endpoint : ""
}

data "aws_subnet" "public_1" {
  count = var.create_vpc_module ? 1 : 0
  id    = local.public_subnet_1_id
}

data "aws_subnet" "public_2" {
  count = var.create_vpc_module ? 1 : 0
  id    = local.public_subnet_2_id
}

data "aws_subnet" "private_1" {
  id = var.create_private_subnet_module ? module.private_subnet[0].private_subnet_id : var.existing_private_subnet_id
}

locals {
  kubernetes_zones_list = sort(distinct(compact([
    var.create_vpc_module ? data.aws_subnet.public_1[0].availability_zone : null,
    var.create_vpc_module ? data.aws_subnet.public_2[0].availability_zone : null,
    data.aws_subnet.private_1.availability_zone,
  ])))

  kubernetes_zones = join(",", local.kubernetes_zones_list)
}

# ----------------------------------------------------------------------------
# Rendered helper command parts (the strings shown to the operator in the
# `next_steps` output below).
# ----------------------------------------------------------------------------

locals {
  kubeconfig_command = "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.eks_cluster_name}"

  verify_nodes_command = "kubectl get nodes -L node.kubernetes.io/instance-type -L sagemaker.amazonaws.com/node-health-status -L sagemaker.amazonaws.com/deep-health-check-status"

  # helm chart v1.13.2 maps to LBC v2.11.x (first release with the dedicated
  # sagemaker-hyperpod compute type from kubernetes-sigs PR #3886).
  lbc_helm_command_parts = [
    "helm repo add eks https://aws.github.io/eks-charts && helm repo update eks",
    "helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller",
    "  --version 1.13.2",
    "  --namespace kube-system",
    "  --values sample-values_aws-lbc.yaml",
    # The three dynamic values below are auto-filled from Terraform and override
    # the <placeholder> values in sample-values_aws-lbc.yaml, so you do not need
    # to hand-edit that file. defaultTargetType/serviceAccount/replicaCount/
    # tolerations all come from the values file (single source of truth).
    "  --set clusterName=${local.eks_cluster_name}",
    "  --set region=${var.aws_region}",
    "  --set vpcId=${var.create_vpc_module ? module.vpc[0].vpc_id : var.existing_vpc_id}",
    "  --install",
  ]

  envoy_gateway_command_parts = [
    "helm install eg oci://docker.io/envoyproxy/gateway-helm",
    "  --version v1.7.0",
    "  --namespace envoy-gateway-system",
    "  --create-namespace",
  ]

  registration_command_parts = compact([
    "anyscale cloud register",
    "  --name ${var.anyscale_new_cloud_name}",
    "  --region ${var.aws_region}",
    "  --provider aws",
    "  --compute-stack k8s",
    "  --kubernetes-zones ${local.kubernetes_zones}",
    "  --s3-bucket-id ${local.s3_bucket_id}",
    "  --anyscale-operator-iam-identity ${local.sagemaker_iam_role_arn}",
  ])

  operator_helm_command_parts = compact([
    "helm repo add anyscale https://anyscale.github.io/helm-charts && helm repo update anyscale",
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "  --namespace ${var.anyscale_operator_namespace}",
    "  --create-namespace",
    "  --values sample-values_anyscale-operator.yaml",
    "  --wait",
    "  --install",
  ])
}

# ----------------------------------------------------------------------------
# Single rendered "next steps" output. This is the value an operator will copy
# from `terraform apply` to bring the cluster the rest of the way to a
# production-ready Anyscale-on-HyperPod deployment.
# ----------------------------------------------------------------------------

output "z_next_steps" {
  description = "Step-by-step commands to finish the Anyscale-on-HyperPod deployment."
  value       = <<-EOT

  ============================================================================
   1. Authenticate kubectl against the new EKS cluster
  ============================================================================
  ${local.kubeconfig_command}
  ${local.verify_nodes_command}

  ============================================================================
   2. Install the AWS Load Balancer Controller v2.11+ (IP target mode —
      REQUIRED for HyperPod). Pod Identity already maps the SA to the LBC
      IAM role created by Terraform.

      A reference values file is provided as sample-values_aws-lbc.yaml.
      v2.11 is the first release with the dedicated `sagemaker-hyperpod`
      pod-compute-type code path (LBC PR #3886).
  ============================================================================
  ${join(" \\\n", local.lbc_helm_command_parts)}

  ============================================================================
   3. (One-time) If the HyperPod inference add-on already created stale LBC
      CRDs, label them for Helm adoption BEFORE step 2 succeeds:
  ============================================================================
  for crd in $(kubectl get crd -o name | grep elbv2.k8s.aws); do
    kubectl label  $crd app.kubernetes.io/managed-by=Helm --overwrite
    kubectl annotate $crd meta.helm.sh/release-name=aws-load-balancer-controller --overwrite
    kubectl annotate $crd meta.helm.sh/release-namespace=kube-system --overwrite
  done

  ============================================================================
   3b. (Known open issue) If LBC logs `cannot resolve pod ENI for pods: [...]`
       even with target-type: ip, disable VPC CNI prefix delegation. Tracked
       upstream at LBC #4666. Reduces max pods per node — validate first.
  ============================================================================
  kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=false
  kubectl rollout restart daemonset aws-node -n kube-system

  ============================================================================
   4. Install Envoy Gateway (replaces ingress-nginx) and apply the HyperPod-
      compatible EnvoyProxy + GatewayClass (NLB target-type=ip).
  ============================================================================
  ${join(" \\\n", local.envoy_gateway_command_parts)}
  kubectl wait --for=condition=available deployment/envoy-gateway -n envoy-gateway-system --timeout=120s
  kubectl apply -f sample-envoyproxy.yaml
  kubectl apply -f sample-gatewayclass.yaml

  ============================================================================
   5. (Optional, only if you will run GPU workloads) Install the NVIDIA
      device plugin. See sample-values_nvdp.yaml for HyperPod tolerations
      and the note about GPU Feature Discovery being unavailable on HyperPod.
  ============================================================================
  helm repo add nvdp https://nvidia.github.io/k8s-device-plugin && helm repo update nvdp
  helm upgrade nvdp nvdp/nvidia-device-plugin \
    --namespace nvidia-device-plugin --version 0.17.1 \
    --values sample-values_nvdp.yaml --create-namespace --install

  ============================================================================
   6. Register the Anyscale cloud. Save the cldrsrc_* id printed at the end.
  ============================================================================
  ${join(" \\\n", local.registration_command_parts)}

  ============================================================================
   6b. (PRODUCTION) Enable head node fault tolerance. Anyscale recommends this
       for all production services. Only applies when create_memorydb_module=true
       (this deployment's redis_endpoint is shown below; empty if disabled).

       redis_endpoint: ${local.redis_endpoint}

       anyscale cloud get --name ${var.anyscale_new_cloud_name} --output cloud-resources.yaml
       # add under kubernetes_config:
       #   redis_endpoint: ${local.redis_endpoint}
       anyscale cloud update --name ${var.anyscale_new_cloud_name} --resources-file cloud-resources.yaml

       Then add a CloudWatch alarm on the MemoryDB DatabaseMemoryUsagePercentage
       metric (trigger > 80%).
  ============================================================================

  ============================================================================
   7. Create the Anyscale operator namespace + Gateway. Replace
      <cloud-resource-id> in sample-gateway.yaml with the cldrsrc_* id.
  ============================================================================
  kubectl create namespace ${var.anyscale_operator_namespace} || true
  # edit sample-gateway.yaml: replace <cloud-resource-id>
  kubectl apply -f sample-gateway.yaml
  kubectl get gateway gateway -n ${var.anyscale_operator_namespace} \
    -o jsonpath='{.status.addresses[0].value}'

  ============================================================================
   8. Install the Anyscale operator. Edit sample-values_anyscale-operator.yaml
      to set <cloud-resource-id>, <aws_region>, and <gateway-address> from
      step 7.

      IMPORTANT: keep `workloads.marketType.enableDefaults: false` — this is
      what makes Ray pods schedulable on HyperPod (the default capacityType
      nodeSelector is rejected by the HyperPod API + Karpenter).
  ============================================================================
  ${join(" \\\n", local.operator_helm_command_parts)}

  ============================================================================
   9. (Recommended) Create the HyperpodNodeClass + NodePools that drive
      Karpenter on HyperPod. The Karpenter control plane is managed by
      HyperPod itself; you only install the custom resources below.

      a) Find your HyperPod InstanceGroup names:
         aws sagemaker describe-cluster --cluster-name ${var.hyperpod_cluster_name} \
           --query 'InstanceGroups[].InstanceGroupName'

      b) Edit sample-hyperpod-nodeclass.yaml to list those InstanceGroups
         (start with on-demand only — HyperPod's Karpenter does NOT honor
         karpenter.sh/capacity-type for spot↔on-demand fallback; the
         HyperPod-native fallback is via mixed InstanceGroups in the same
         HyperpodNodeClass).
  ============================================================================
  kubectl apply -f sample-hyperpod-nodeclass.yaml
  kubectl apply -f sample-karpenter-nodepool-cpu.yaml
  kubectl apply -f sample-karpenter-nodepool-gpu.yaml

  ============================================================================
   10. Verify the cloud end-to-end:
  ============================================================================
  anyscale cloud verify --name ${var.anyscale_new_cloud_name}
  anyscale job submit --cloud ${var.anyscale_new_cloud_name} \
    --working-dir https://github.com/anyscale/docs_examples/archive/refs/heads/main.zip \
    -- python hello_world.py

  EOT
}
