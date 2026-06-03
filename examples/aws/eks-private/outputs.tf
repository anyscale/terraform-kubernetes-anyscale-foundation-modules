locals {
  kubernetes_zones_list = module.anyscale_vpc.availability_zones
}

data "aws_iam_role" "default_nodegroup" {
  name = module.eks.eks_managed_node_groups["default"].iam_role_name
}

output "eks_cluster_name" {
  description = "The name of the EKS cluster. This is used for Helm chart values."
  value       = var.eks_cluster_name
}

output "aws_region" {
  description = "The AWS region. This is used for Helm chart values."
  value       = var.aws_region
}

output "vpc_id" {
  description = "VPC id. Pass to `helm upgrade aws-load-balancer-controller --set vpcId=<this>` so the controller does not need IMDS access to introspect it."
  value       = module.anyscale_vpc.vpc_id
}

#####################################################################
# Rendered PV/PVC manifest for the optional Mountpoint-for-S3 PVC.
#####################################################################

locals {
  pv_pvc_yaml = <<-YAML
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: anyscale-shared-s3
    spec:
      accessModes:
        - ReadWriteMany
      capacity:
        storage: 1200Gi
      storageClassName: ""
      claimRef:
        namespace: anyscale-operator
        name: anyscale-shared-fuse
      mountOptions:
        - allow-other
        - region ${var.aws_region}
        - prefix anyscale-shared/
      csi:
        driver: s3.csi.aws.com
        volumeHandle: anyscale-shared-s3-volume
        volumeAttributes:
          bucketName: ${module.anyscale_s3.s3_bucket_id}
          authenticationSource: driver
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: anyscale-shared-fuse
      namespace: anyscale-operator
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: ""
      resources:
        requests:
          storage: 1200Gi
      volumeName: anyscale-shared-s3
  YAML
}

resource "local_file" "pv_pvc_yaml" {
  count = var.enable_s3_pvc ? 1 : 0

  filename = "${path.module}/generated/pv-pvc.yaml"
  content  = local.pv_pvc_yaml
}

#####################################################################
# Rendered helper commands (registration, helm installs).
#####################################################################

locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--provider aws",
    "--compute-stack k8s",
    "--region ${var.aws_region}",
    "--name ${var.anyscale_cloud_name}",
    "--cloud-storage-bucket-name s3://${module.anyscale_s3.s3_bucket_id}",
    "--kubernetes-zones ${join(",", local.kubernetes_zones_list)}",
    "--anyscale-operator-iam-identity ${data.aws_iam_role.default_nodegroup.arn}",
    var.enable_s3_pvc ? "--persistent-volume-claim anyscale-shared-fuse" : null,
    var.enable_efs ? "--file-storage-id ${module.anyscale_efs.efs_id}" : null,
    var.enable_memorydb ? "--memorydb-cluster-id ${module.anyscale_memorydb.memorydb_cluster_id}" : null,
    "--yes",
  ])

  helm_upgrade_command_parts = [
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string global.cloudDeploymentId=<cloud-deployment-id>",
    "--set-string global.cloudProvider=aws",
    "--set-string global.aws.region=${var.aws_region}",
    "--set-string workloads.serviceAccount.name=anyscale-operator",
    "--set networking.gateway.enabled=true",
    "--set-string networking.gateway.name=gateway",
    "--set-string networking.gateway.namespace=anyscale-operator",
    "--set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1",
    "--set-string networking.gateway.hostname=<gateway-nlb-hostname>",
    "--namespace anyscale-operator",
    "--create-namespace",
    "-i",
  ]
}

output "anyscale_registration_command" {
  description = "The `anyscale cloud register` command with all required flags pre-populated."
  value       = join(" \\\n\t", local.registration_command_parts)
}

output "helm_upgrade_command" {
  description = "The Anyscale Operator helm upgrade command, with gateway settings populated for the Anyscale Envoy Gateway setup."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}

#####################################################################
# Rendered post-terraform deployment script — ordered list of every
# helm/kubectl/anyscale command to run after `terraform apply`.
# Open generated/deploy.sh and run the steps in order, or pipe to
# bash if you trust the substitutions. The script body lives in
# `deploy.sh.tftpl` so it stays plain bash (shellcheck-friendly).
#####################################################################

resource "local_file" "deploy_script" {
  filename = "${path.module}/generated/deploy.sh"
  content = templatefile("${path.module}/deploy.sh.tftpl", {
    eks_cluster_name     = var.eks_cluster_name
    aws_region           = var.aws_region
    anyscale_cloud_name  = var.anyscale_cloud_name
    enable_s3_pvc        = var.enable_s3_pvc
    vpc_id               = module.anyscale_vpc.vpc_id
    registration_command = join(" \\\n      ", local.registration_command_parts)
  })
  file_permission = "0755"
}

output "deploy_script_path" {
  description = "Path to a rendered shell script containing every post-terraform step in order (autoscaler, AWS LBC, Envoy Gateway + manifests, PVC, Anyscale Operator, verify). Open it to copy-paste steps, or run end-to-end after exporting CLOUD_DEPLOYMENT_ID."
  value       = local_file.deploy_script.filename
}

#####################################################################
# Outputs for the optional Mountpoint-for-S3 PVC shared storage path.
#####################################################################

output "s3_pvc_bucket_name" {
  description = "Name of the S3 bucket exposed as a PVC via the Mountpoint-for-S3 CSI driver. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? module.anyscale_s3.s3_bucket_id : null
}

output "s3_pvc_csi_driver_role_arn" {
  description = "IAM role ARN assumed by the Mountpoint-for-S3 CSI driver pods via EKS Pod Identity. The pod identity association itself is managed by the `aws-mountpoint-s3-csi-driver` EKS managed addon. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? aws_iam_role.s3_csi_driver[0].arn : null
}

#####################################################################
# Outputs for the optional MemoryDB cluster.
#####################################################################

output "memorydb_endpoint" {
  description = "MemoryDB cluster configuration endpoint as host:port. Wired into the rendered registration command's `--memorydb-cluster-id` flag. Only set when `enable_memorydb = true`."
  value       = var.enable_memorydb ? "${module.anyscale_memorydb.memorydb_cluster_endpoint_address}:${module.anyscale_memorydb.memorydb_cluster_endpoint_port}" : null
}
