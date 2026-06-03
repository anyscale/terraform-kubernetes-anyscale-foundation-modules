data "aws_subnet" "existing" {
  for_each = toset(var.existing_subnet_ids)
  id       = each.value
}

locals {
  kubernetes_zones = join(",", [for s in data.aws_subnet.existing : s.availability_zone])
}

locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--region ${var.aws_region}",
    "--provider aws",
    "--compute-stack k8s",
    "--kubernetes-zones ${local.kubernetes_zones}",
    "--s3-bucket-id ${module.anyscale_s3.s3_bucket_id}",
    var.enable_efs ? "--efs-id ${module.anyscale_efs.efs_id}" : null,
    var.enable_s3_pvc ? "--persistent-volume-claim anyscale-shared-fuse" : null,
    var.enable_memorydb ? "--memorydb-cluster-id ${module.anyscale_memorydb.memorydb_cluster_id}" : null,
    "--anyscale-operator-iam-identity <node_IAM_role_arn>",
  ])

  helm_upgrade_command_parts = compact([
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
    "-i"
  ])

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

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = join(" \\\n\t", local.registration_command_parts)
}

output "helm_upgrade_command" {
  description = "The helm upgrade command."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}

output "s3_pvc_bucket_name" {
  description = "Name of the S3 bucket exposed as a PVC via the Mountpoint-for-S3 CSI driver. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? module.anyscale_s3.s3_bucket_id : null
}

output "s3_pvc_csi_driver_role_arn" {
  description = "IAM role ARN that the Mountpoint-for-S3 CSI driver pods should assume via EKS Pod Identity. Pass this to `aws eks create-pod-identity-association --role-arn`. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? aws_iam_role.s3_csi_driver[0].arn : null
}

output "memorydb_endpoint" {
  description = "MemoryDB cluster configuration endpoint as host:port. Only set when `enable_memorydb = true`."
  value       = var.enable_memorydb ? "${module.anyscale_memorydb.memorydb_cluster_endpoint_address}:${module.anyscale_memorydb.memorydb_cluster_endpoint_port}" : null
}

#####################################################################
# Rendered post-terraform deployment script — ordered list of every
# helm/kubectl/anyscale command to run after `terraform apply`.
# Because this example uses an existing EKS cluster, you'll need to
# substitute <eks_cluster_name>, <anyscale_cloud_name>, and
# <node_IAM_role_arn> placeholders before running. The script body
# lives in `deploy.sh.tftpl` so it stays plain bash (shellcheck-friendly).
#####################################################################

resource "local_file" "deploy_script" {
  filename = "${path.module}/generated/deploy.sh"
  content = templatefile("${path.module}/deploy.sh.tftpl", {
    aws_region             = var.aws_region
    existing_vpc_id        = var.existing_vpc_id
    enable_s3_pvc          = var.enable_s3_pvc
    s3_csi_driver_role_arn = var.enable_s3_pvc ? aws_iam_role.s3_csi_driver[0].arn : ""
    registration_command   = join(" \\\n      ", local.registration_command_parts)
  })
  file_permission = "0755"
}

output "deploy_script_path" {
  description = "Path to a rendered shell script containing every post-terraform step in order (autoscaler, AWS LBC, optional S3 CSI addon, Envoy Gateway + manifests, PVC, Anyscale Operator, verify). Open it to copy-paste steps after substituting the BYO placeholders (<eks_cluster_name>, <anyscale_cloud_name>, <node_IAM_role_arn>)."
  value       = local_file.deploy_script.filename
}
