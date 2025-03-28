[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![Kubernetes Provider Version][badge-tf-kubernetes]](https://github.com/terraform-providers/terraform-provider-kubernetes/releases)

# Terraform Modules for Anyscale Kubernetes Foundations
[Terraform] modules to manage Kubernetes infrastructure for Anyscale. This builds the foundational cloud resources needed to run Anyscale on Kubernetes and should be paired with the [Anyscale AWS]() and [Anyscale GCP]() Terraform Modules.

**THIS IS PROVIDED AS A STARTING POINT**

**USE AT YOUR OWN RISK**

### Customization

These modules are designed with best practices in mind, ensuring a secure, efficient, and scalable Anyscale deployment. Each module is standalone, allowing you the flexibility to disable any you don't need. This is handy if you're looking to incorporate custom solutions for specific resources.


### Examples
The examples folder has a couple common use cases that have been tested. These include:
* Anyscale - AWS & EKS
  * [eks-public](https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules/tree/main/examples/aws/eks-public) - Build everything - use a common name for all resources, public networking
  * [eks-private](https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules/tree/main/examples/aws/eks-private) - Build everything - use a common name for all resources, private networking
* Anyscale - GCP & GKE
  * [gke-existing_cluster](https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules/tree/main/examples/gcp/gke-existing_cluster) - Use an existing GKE cluster, build additional resources such as object storage, service accounts, filestore.

Additional examples can be requested via an [issues] ticket.

### Specific Module Notes

## Usage

Please see specific examples above for usage.

## Reporting Issues

We use GitHub [Issues] to track community reported issues and missing features.

## Known Issues/Untested

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.12 |

## Providers

No providers.

## Modules

No modules.

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cloud_provider"></a> [cloud\_provider](#input\_cloud\_provider) | (Required) The cloud provider (aws or gcp)<br/><br/>ex:<pre>cloud_provider = "aws"</pre> | `string` | n/a | yes |
| <a name="input_aws_controlplane_role_arn"></a> [aws\_controlplane\_role\_arn](#input\_aws\_controlplane\_role\_arn) | (Optional) The ARN of the AWS IAM role that will be used by the EKS cluster to access AWS services.<br/><br/>Required if `cloud_provider` is set to `aws`.<br/><br/>ex:<pre>aws_controlplane_role_arn = "arn:aws:iam::123456789012:role/my-eks-controlplane-role"</pre> | `string` | `null` | no |
| <a name="input_aws_dataplane_role_arn"></a> [aws\_dataplane\_role\_arn](#input\_aws\_dataplane\_role\_arn) | (Optional) The ARN of the AWS IAM role that will be used by the EKS cluster to access AWS services.<br/><br/>Required if `cloud_provider` is set to `aws`.<br/><br/>ex:<pre>aws_dataplane_role_arn = "arn:aws:iam::123456789012:role/my-eks-dataplane-role"</pre> | `string` | `null` | no |
| <a name="input_kubernetes_cluster_name"></a> [kubernetes\_cluster\_name](#input\_kubernetes\_cluster\_name) | (Optional) The name of the Kubernetes cluster.<br/><br/>ex:<pre>kubernetes_cluster_name = "my-cluster"</pre> | `string` | `null` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Anyscale]: https://www.anyscale.com
[Issues]: https://github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules/issues
[badge-build]: https://github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-kubernetes]: https://img.shields.io/badge/KUBERNETES-2.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules/actions
