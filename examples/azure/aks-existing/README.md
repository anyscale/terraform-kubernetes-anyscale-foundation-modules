[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![Azure Provider Version][badge-tf-azure]](https://github.com/hashicorp/terraform-provider-azurerm/releases)

# Anyscale Azure AKS Example - Existing AKS Cluster
This example creates the resources to run Anyscale on an existing Azure AKS cluster.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Getting Started

### Prerequisites

* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)
  * [Sign into the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/get-started-with-azure-cli#sign-into-the-azure-cli)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) (> v0.26.24)
* Existing [Azure Resource Group](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/manage-resource-groups-portal)
* Existing [Azure AKS Cluster](https://learn.microsoft.com/en-us/azure/aks/learn/quick-kubernetes-deploy-portal) running in the existing Resource Group


### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review variables.tf and create a `terraform.tfvars` file with your values. You can copy `terraform.tfvars.example` to `terraform.tfvars` and edit the placeholders.

```hcl
azure_subscription_id         = "<your-subscription-id>"
existing_resource_group_name = "<your-resource-group-name>"
existing_aks_cluster_name    = "<your-aks-cluster-name>"
storage_account_name          = "anyscalesaexisting"  # must yield a globally unique storage account name (3-24 chars)
```

* Apply the terraform

```shell
terraform init
terraform plan
terraform apply -var-file=terraform.tfvars
```

If you use a different tfvars file, pass it with `-var-file=<file>`.
Note the output from Terraform which includes example cloud registration and helm commands you will use below.

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:
* [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/deploy/) (other ingress controllers may be possible but are untested)
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) (required if utilizing GPU nodes)

**Note:** Ensure that you are authenticated to the AKS cluster for the remaining steps:

```shell
az aks get-credentials --resource-group <azure_resource_group_name> --name <aks_cluster_name> --overwrite-existing
```

#### Install the Nginx ingress controller

A sample file, `sample-values_nginx.yaml` has been provided in this repo. Please review for your requirements before using.

Run:

```shell
helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm upgrade ingress-nginx nginx/ingress-nginx \
  --version 4.12.1 \
  --namespace ingress-nginx \
  --values sample-values_nginx.yaml \
  --create-namespace \
  --install
```

#### (Optional) Install the Nvidia device plugin

A sample file, `sample-values_nvdp.yaml` has been provided in this repo. Please review for AKS requirements before using.

1. Create a YAML values file named: `values_nvdp.yaml`
2. Update the content with the following:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: "kubernetes.azure.com/accelerator"
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
  - key: kubernetes.azure.com/scalesetpriority
    operator: Exists
    effect: NoSchedule
```

3. Run:

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values values_nvdp.yaml \
  --create-namespace \
  --install
```

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

Using the output from the Terraform modules, register the Anyscale Cloud. It should look something like:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region ... \
  --provider azure \
  --compute-stack k8s \
  --cloud-storage-bucket-name 'azure://...' \
  --cloud-storage-bucket-endpoint 'https://....blob.core.windows.net'
```

### Install the Anyscale Operator

Update helm repo cache:

```
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Using the output from the `cloud register`, install the Anyscale Operator on the AKS Cluster. It should look something like:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=cldrsrc_... \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=... \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  --wait \
  -i
```

[optional] If you are using GPU types other than T4 follow these steps:
A sample file, `sample-custom_values.yaml` has been provided in this repo. Make a copy `custom_values.yaml` and update based on your GPU types before using.

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  ...
  -f custom_values.yaml \
  --create-namespace \
  -i
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | 4.26.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.26.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_federated_identity_credential.anyscale_operator_fic](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_role_assignment.anyscale_blob_contrib](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.sa](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_account) | resource |
| [azurerm_storage_container.blob](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_container) | resource |
| [azurerm_user_assigned_identity.anyscale_operator](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_kubernetes_cluster.existing](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/data-sources/kubernetes_cluster) | data source |
| [azurerm_resource_group.existing](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_azure_subscription_id"></a> [azure\_subscription\_id](#input\_azure\_subscription\_id) | (Required) Azure subscription ID | `string` | n/a | yes |
| <a name="input_existing_aks_cluster_name"></a> [existing\_aks\_cluster\_name](#input\_existing\_aks\_cluster\_name) | (Required) Existing AKS cluster name.<br>The name of an existing AKS cluster. The cluster must have:<br>- OIDC issuer enabled (oidc\_issuer\_enabled = true)<br>- Workload identity enabled (workload\_identity\_enabled = true)<br>- Node pools configured with appropriate taints and labels for Anyscale<br><br>ex:<pre>existing_aks_cluster_name = "my-aks-cluster"</pre> | `string` | n/a | yes |
| <a name="input_existing_resource_group_name"></a> [existing\_resource\_group\_name](#input\_existing\_resource\_group\_name) | (Required) Existing Resource Group name.<br>The name of an existing Azure Resource Group where the AKS cluster is deployed.<br><br>ex:<pre>existing_resource_group_name = "my-aks-resource-group"</pre> | `string` | n/a | yes |
| <a name="input_anyscale_cloud_name"></a> [anyscale\_cloud\_name](#input\_anyscale\_cloud\_name) | (Optional) Name prefix for Anyscale resources.<br>This will be used as a prefix for the Storage Account and other created resources.<br><br>ex:<pre>anyscale_cloud_name = "anyscale-prod"</pre> | `string` | `"anyscale"` | no |
| <a name="input_anyscale_operator_namespace"></a> [anyscale\_operator\_namespace](#input\_anyscale\_operator\_namespace) | (Optional) Kubernetes namespace for the Anyscale operator. | `string` | `"anyscale-operator"` | no |
| <a name="input_cors_rule"></a> [cors\_rule](#input\_cors\_rule) | (Optional)<br>Object containing a rule of Cross-Origin Resource Sharing.<br>The default allows GET, POST, PUT, HEAD, and DELETE<br>access for the purpose of viewing logs and other functionality<br>from within the Anyscale Web UI (*.anyscale.com).<br><br>ex:<pre>cors_rule = {<br>  allowed_headers = ["*"]<br>  allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]<br>  allowed_origins = ["https://*.anyscale.com"]<br>  expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]<br>}</pre> | <pre>object({<br>    allowed_headers    = list(string)<br>    allowed_methods    = list(string)<br>    allowed_origins    = list(string)<br>    expose_headers     = list(string)<br>    max_age_in_seconds = optional(number, 0)<br>  })</pre> | <pre>{<br>  "allowed_headers": [<br>    "*"<br>  ],<br>  "allowed_methods": [<br>    "GET",<br>    "POST",<br>    "PUT",<br>    "HEAD",<br>    "DELETE"<br>  ],<br>  "allowed_origins": [<br>    "https://*.anyscale.com"<br>  ],<br>  "expose_headers": [<br>    "Accept-Ranges",<br>    "Content-Range",<br>    "Content-Length"<br>  ]<br>}</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags applied to all taggable resources. | `map(string)` | <pre>{<br>  "Environment": "dev",<br>  "Example": "azure/aks-existing",<br>  "Repo": "terraform-kubernetes-anyscale-foundation-modules",<br>  "Test": "true"<br>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_anyscale_operator_client_id"></a> [anyscale\_operator\_client\_id](#output\_anyscale\_operator\_client\_id) | Client ID of the Azure User Assigned Identity created for Anyscale. |
| <a name="output_anyscale_operator_principal_id"></a> [anyscale\_operator\_principal\_id](#output\_anyscale\_operator\_principal\_id) | Principal ID of the Azure User Assigned Identity created for Anyscale. |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The Anyscale registration command. |
| <a name="output_azure_aks_cluster_name"></a> [azure\_aks\_cluster\_name](#output\_azure\_aks\_cluster\_name) | Name of the existing Azure AKS cluster. |
| <a name="output_azure_resource_group_name"></a> [azure\_resource\_group\_name](#output\_azure\_resource\_group\_name) | Name of the Azure Resource Group used for the cluster. |
| <a name="output_azure_storage_account_name"></a> [azure\_storage\_account\_name](#output\_azure\_storage\_account\_name) | Name of the Azure Storage Account created for Anyscale. |
| <a name="output_helm_upgrade_command"></a> [helm\_upgrade\_command](#output\_helm\_upgrade\_command) | The helm upgrade command. |
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-azure]: https://img.shields.io/badge/Azure-4.26.0-0078D4.svg?logo=terraform
