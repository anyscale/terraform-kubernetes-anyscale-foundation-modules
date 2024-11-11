[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS EKS Example - Public Networking
This example creates the resources to run Anyscale on AWS EKS with a public networking.

## Known issues

- Running `terraform destroy` can time out while deleting the ingress helm chart

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

No providers.

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_anyscale_efs"></a> [anyscale\_efs](#module\_anyscale\_efs) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs | n/a |
| <a name="module_anyscale_eks_cluster"></a> [anyscale\_eks\_cluster](#module\_anyscale\_eks\_cluster) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-eks-cluster | n/a |
| <a name="module_anyscale_eks_nodegroups"></a> [anyscale\_eks\_nodegroups](#module\_anyscale\_eks\_nodegroups) | ../../../../terraform-aws-anyscale-cloudfoundation-modules/modules/aws-anyscale-eks-nodegroups | n/a |
| <a name="module_anyscale_iam_roles"></a> [anyscale\_iam\_roles](#module\_anyscale\_iam\_roles) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam | n/a |
| <a name="module_anyscale_k8s_helm"></a> [anyscale\_k8s\_helm](#module\_anyscale\_k8s\_helm) | ../../../modules/anyscale-k8s-helm | n/a |
| <a name="module_anyscale_k8s_namespace"></a> [anyscale\_k8s\_namespace](#module\_anyscale\_k8s\_namespace) | ../../../modules/anyscale-k8s-namespace | n/a |
| <a name="module_anyscale_s3"></a> [anyscale\_s3](#module\_anyscale\_s3) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3 | n/a |
| <a name="module_anyscale_securitygroup"></a> [anyscale\_securitygroup](#module\_anyscale\_securitygroup) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-securitygroups | n/a |
| <a name="module_anyscale_vpc"></a> [anyscale\_vpc](#module\_anyscale\_vpc) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-vpc | n/a |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_anyscale_cloud_id"></a> [anyscale\_cloud\_id](#input\_anyscale\_cloud\_id) | (Optional) Anyscale Cloud ID. Default is `null`. | `string` | `null` | no |
| <a name="input_anyscale_deploy_env"></a> [anyscale\_deploy\_env](#input\_anyscale\_deploy\_env) | (Optional) Anyscale deploy environment. Used in resource names and tags. | `string` | `"production"` | no |
| <a name="input_anyscale_s3_cors_rule"></a> [anyscale\_s3\_cors\_rule](#input\_anyscale\_s3\_cors\_rule) | (Optional) A map of CORS rules for the S3 bucket.<br/><br/>Including here to override for Anyscale Staging. | `map(any)` | <pre>{<br/>  "allowed_headers": [<br/>    "*"<br/>  ],<br/>  "allowed_methods": [<br/>    "GET",<br/>    "POST",<br/>    "PUT",<br/>    "HEAD",<br/>    "DELETE"<br/>  ],<br/>  "allowed_origins": [<br/>    "https://*.anyscale.com"<br/>  ],<br/>  "expose_headers": []<br/>}</pre> | no |
| <a name="input_anyscale_trusted_role_arns"></a> [anyscale\_trusted\_role\_arns](#input\_anyscale\_trusted\_role\_arns) | (Optional) A list of ARNs of IAM roles that are trusted by the Anyscale IAM role.<br/><br/>Including here to override for Anyscale Staging. | `list(string)` | `[]` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | The AWS region in which all resources will be created. | `string` | `"us-east-2"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) A map of tags to all resources that accept tags. | `map(string)` | <pre>{<br/>  "environment": "example",<br/>  "example": "aws/eks-public",<br/>  "repo": "terraform-kubernetes-anyscale-foundation-modules",<br/>  "test": true<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_anyscale_register_command"></a> [anyscale\_register\_command](#output\_anyscale\_register\_command) | Anyscale register command.<br/>This output can be used with the Anyscale CLI to register a new Anyscale Cloud.<br/>You will need to replace `<CUSTOMER_DEFINED_NAME>` with a name of your choosing before running the Anyscale CLI command. |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster. |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-5.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions
