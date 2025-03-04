[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS EKS Example - Public Networking
This example creates the resources to run Anyscale on AWS EKS with public networking.

## Getting Started

### Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [AWS Credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review variables.tf and (optionally) create a `local.tfvars` file to override any of the defaults.
* Apply the terraform

```shell
terraform init
terraform plan
terraform apply
```

If you are using a `tfvars` file, you will need to update the above commands accordingly.
Note the output from Terraform which includes a cloud registration command you will use below.

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:
* [Cluster autoscaler](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)
* [AWS LBC (Load Balancer controller)](https://github.com/kubernetes-sigs/aws-load-balancer-controller/tree/main/helm/aws-load-balancer-controller)
* [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/deploy/) (other ingress controllers may be possible but are untested)
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) (required if utilizing GPU nodes)

Ensure that you are [authenticated to the EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html) for the remaining steps.

#### Install the Cluster autoscaler

```shell
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.46.0 \
  --namespace kube-system \
  --set awsRegion=<aws_region> \
  --set 'autoDiscovery.clusterName'=<eks_cluster_name>
```

#### Install the AWS LBC (load balancer controller)

```shell
helm repo add eks https://aws.github.io/eks-charts
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.11.0 \
  --namespace kube-system \
  --set clusterName=<eks_cluster_name>
```

#### Install the Nginx ingress controller

A sample file, `sample-values_elb.yaml` has been provided in this repo. Please review for your requirements before using.

1. Create a YAML values file named: `values_elb.yaml`:
2. Update the content with the following:

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

3. Run:

```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade --install ingress-nginx nginx/ingress-nginx \
  --version 4.12.0 \
  --namespace ingress-nginx \
  --create-namespace \
  -f values_elb.yaml
```


#### (Optional) Install the Nvidia device plugin

A sample file, `sample-values_nvdp.yaml` has been provided in this repo. Please review for your requirements before using.

1. Create a YAML values file named: `values_nvdp.yaml`
2. Update the content with the following:

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

3. Run:

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.17.0 \
  -f values_nvdp.yaml
```

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

1. Using the output from the Terraform modules, register the Anyscale Cloud. It should look sonething like:

```shell
anyscale cloud register --provider aws \
  --name my_kubernetes_cloud \
  --compute-stack k8s \
  --region us-east-2 \
  --s3-bucket-id anyscale_example_bucket \
  --efs-id fs-abcdefgh01234567 \
  --kubernetes-zones us-east-2a,us-east-2b,us-east-2c \
  --anyscale-operator-iam-identity arn:aws:iam::123456789012:role/my-kubernetes-cloud-node-group-role
```
**Please note:** You must change the cloud name to a name that you choose. You will not be able to register a cloud with a name of `<CUSTOMER_DEFINED_NAME>`.

2. Note the Cloud Deployment ID which will be used in the next step. The Anyscale CLI will return it as one of the outputs. Example:
```shell
Output
(anyscale +22.5s) For registering this cloud's Kubernetes Manager, use cloud deployment ID 'cldrsrc_12345abcdefgh67890ijklmnop'.
```

### Install the Anyscale Operator

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.89.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_anyscale_efs"></a> [anyscale\_efs](#module\_anyscale\_efs) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs | n/a |
| <a name="module_anyscale_iam_roles"></a> [anyscale\_iam\_roles](#module\_anyscale\_iam\_roles) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam | n/a |
| <a name="module_anyscale_s3"></a> [anyscale\_s3](#module\_anyscale\_s3) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3 | n/a |
| <a name="module_anyscale_vpc"></a> [anyscale\_vpc](#module\_anyscale\_vpc) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-vpc | n/a |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 20.33.1 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.autoscaler_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.elb_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_security_group.allow_all_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_iam_role.default_nodegroup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_anyscale_s3_cors_rule"></a> [anyscale\_s3\_cors\_rule](#input\_anyscale\_s3\_cors\_rule) | (Optional) A map of CORS rules for the S3 bucket.<br/><br/>ex:<pre>anyscale_s3_cors_rule = {<br/>  allowed_headers = ["*"]<br/>  allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]<br/>  allowed_origins = ["https://*.anyscale.com"]<br/>}</pre> | `map(any)` | <pre>{<br/>  "allowed_headers": [<br/>    "*"<br/>  ],<br/>  "allowed_methods": [<br/>    "GET",<br/>    "POST",<br/>    "PUT",<br/>    "HEAD",<br/>    "DELETE"<br/>  ],<br/>  "allowed_origins": [<br/>    "https://*.anyscale.com"<br/>  ],<br/>  "expose_headers": []<br/>}</pre> | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | (Optional) The AWS region in which all resources will be created.<br/><br/>ex:<pre>aws_region = "us-east-2"</pre> | `string` | `"us-east-2"` | no |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | (Optional) The name of the EKS cluster.<br/><br/>This will be used for naming resources created by this module including the EKS cluster and the S3 bucket.<br/><br/>ex:<pre>eks_cluster_name = "anyscale-eks-public"</pre> | `string` | `"anyscale-eks-public"` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | (Optional) The Kubernetes version of the EKS cluster.<br/><br/>ex:<pre>eks_cluster_version = "1.31"</pre> | `string` | `"1.31"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) A map of tags to all resources that accept tags.<br/><br/>ex:<pre>tags = {<br/>  Environment = "dev"<br/>  Repo        = "terraform-kubernetes-anyscale-foundation-modules",<br/>}</pre> | `map(string)` | <pre>{<br/>  "Environment": "dev",<br/>  "Example": "aws/eks-public",<br/>  "Repo": "terraform-kubernetes-anyscale-foundation-modules",<br/>  "Test": "true"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_anyscale_register_command"></a> [anyscale\_register\_command](#output\_anyscale\_register\_command) | Anyscale register command.<br/>This output can be used with the Anyscale CLI to register a new Anyscale Cloud.<br/>You will need to replace `<CUSTOMER_DEFINED_NAME>` with a name of your choosing before running the Anyscale CLI command. |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | The AWS region. This is used for Helm chart values. |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster. This is used for Helm chart values. |
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-5.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions
