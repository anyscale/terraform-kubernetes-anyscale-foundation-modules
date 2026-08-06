#################################################################
# IAM role for the Mountpoint for Amazon S3 CSI driver.
#
# When enable_s3_pvc = true, this creates the IAM role the CSI
# driver pods (s3-csi-driver-sa in kube-system) will assume via
# EKS Pod Identity, plus an inline policy scoped to the Anyscale
# S3 bucket created by module.anyscale_s3.
#
# Because this example brings its own EKS cluster, Terraform does
# NOT install the EKS managed addon or create the Pod Identity
# Association on your behalf — that's two aws-CLI calls in the
# README's "Optional: S3 PVC Plugin" section.
#
# This mirrors the Azure blobfuse2 PVC pattern documented at
# https://docs.anyscale.com/clouds/azure/pvc but on AWS.
#################################################################

#trivy:ignore:avd-aws-0057
resource "aws_iam_role" "s3_csi_driver" {
  #checkov:skip=CKV_AWS_60: "Ensure IAM role allows only specific services or principals to assume it" - principal is the EKS Pod Identity service.
  count = var.enable_s3_pvc ? 1 : 0

  name        = "anyscale-eks-existing-s3-csi-driver"
  description = "Role assumed by the aws-mountpoint-s3-csi-driver pods (via EKS Pod Identity) to access the Anyscale S3 bucket as a PVC."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = var.tags
}

#trivy:ignore:avd-aws-0057
resource "aws_iam_role_policy" "s3_csi_driver" {
  #checkov:skip=CKV_AWS_290: "Ensure IAM policies does not allow write access without constraints" - constrained to the Anyscale bucket only.
  #checkov:skip=CKV_AWS_355: "Ensure no IAM policies documents allow * as a statement's resource for restrictable actions" - object-level actions need bucket/* and are bucket-scoped.
  count = var.enable_s3_pvc ? 1 : 0

  name = "anyscale-eks-existing-s3-csi-driver"
  role = aws_iam_role.s3_csi_driver[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MountpointBucketLevel"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [module.anyscale_s3.s3_bucket_arn]
      },
      {
        Sid    = "MountpointObjectLevel"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = ["${module.anyscale_s3.s3_bucket_arn}/*"]
      }
    ]
  })
}
