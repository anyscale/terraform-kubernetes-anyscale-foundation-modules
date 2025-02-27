[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS EKS Example - Public Networking
This example creates the resources to run Anyscale on existing AWS EKS.

## Getting Started

### Prerequisite

* AWS Credentials
* kubectl CLI
* helm CLI

Ensure your EKS cluster:

* Use the same VPC `module.anyscale_vpc.vpc_id`
* Use the same private subnet `module.anyscale_vpc.private_subnet_ids` for Node Group
* Attach the IAM policy `module.anyscale_iam_roles.anyscale_iam_s3_policy_arn` and `arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess` to the Node IAM role

### Creating Anyscale Resources

Create `terraform.tfvars`:

```hcl
aws_region = "us-west-2"
```

Run:

```shell
terraform init
terraform apply
```

### Installing K8s Components

**Install [Cluster autoscaler](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)**:

```shell
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler --version 9.46.0 \
    --namespace kube-system \
    --set awsRegion="us-west-2" \
    --set 'autoDiscovery.clusterName'=anyscale-eks-public
```

**Install [AWS LBC (load balancer controller)](https://github.com/kubernetes-sigs/aws-load-balancer-controller/tree/main/helm/aws-load-balancer-controller)**:

```shell
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller --version 1.11.0 -n kube-system \
  --set clusterName=anyscale-eks-public
```

**Install [Nginx ingress controller](https://kubernetes.github.io/ingress-nginx/deploy/)**:

Create `values_elb.yaml`:

```yaml
controller:
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
      service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
      service.beta.kubernetes.io/aws-load-balancer-type: nlb
  allowSnippetAnnotations: true
  autoscaling:
    enabled: true
```

Run:

```shell
helm upgrade --install ingress-nginx ingress-nginx \
  --version 4.12.0 \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f values_elb.yaml
```


**(Optional) Install [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm)**:

Create `values_nvdp.yaml`:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        # We allow a GPU deployment to be forced by setting the following label to "true"
        - key: "nvidia.com/gpu.product"
          operator: Exists
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/capacity-type
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/accelerator-type
    operator: Exists
    effect: NoSchedule
```

Run:

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.17.0 \
  -f values_nvdp.yaml
```

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.88.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_anyscale_efs"></a> [anyscale\_efs](#module\_anyscale\_efs) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs | n/a |
| <a name="module_anyscale_iam_roles"></a> [anyscale\_iam\_roles](#module\_anyscale\_iam\_roles) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam | n/a |
| <a name="module_anyscale_s3"></a> [anyscale\_s3](#module\_anyscale\_s3) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3 | n/a |
| <a name="module_anyscale_vpc"></a> [anyscale\_vpc](#module\_anyscale\_vpc) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-vpc | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_security_group.allow_all_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_anyscale_s3_cors_rule"></a> [anyscale\_s3\_cors\_rule](#input\_anyscale\_s3\_cors\_rule) | (Optional) A map of CORS rules for the S3 bucket.<br><br>Including here to override for Anyscale Staging. | `map(any)` | <pre>{<br>  "allowed_headers": [<br>    "*"<br>  ],<br>  "allowed_methods": [<br>    "GET",<br>    "POST",<br>    "PUT",<br>    "HEAD",<br>    "DELETE"<br>  ],<br>  "allowed_origins": [<br>    "https://*.anyscale.com"<br>  ],<br>  "expose_headers": []<br>}</pre> | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | The AWS region in which all resources will be created. | `string` | `"us-east-2"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) A map of tags to all resources that accept tags. | `map(string)` | <pre>{<br>  "Environment": "dev",<br>  "Example": "aws/eks-public",<br>  "Repo": "terraform-kubernetes-anyscale-foundation-modules",<br>  "Test": "true"<br>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_anyscale_register_command"></a> [anyscale\_register\_command](#output\_anyscale\_register\_command) | Anyscale register command.<br>This output can be used with the Anyscale CLI to register a new Anyscale Cloud.<br>You will need to replace `<CUSTOMER_DEFINED_NAME>` with a name of your choosing before running the Anyscale CLI command. |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-5.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions
