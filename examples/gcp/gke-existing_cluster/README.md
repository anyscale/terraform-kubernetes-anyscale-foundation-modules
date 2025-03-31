[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![Google Provider Version][badge-tf-google]](https://github.com/terraform-providers/terraform-provider-google/releases)

# Anyscale GKE Example - Existing Cluster

This example creates the resources to run Anyscale with an existing GKE cluster.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Known Issues on GKE

- Autopilot GKE clusters are not supported.
- Node auto-provisioning for GKE failing with GPU nodes: https://github.com/GoogleCloudPlatform/container-engine-accelerators/issues/407

## Getting Started

### Prerequisites

* [Google Cloud Project](https://cloud.google.com/resource-manager/docs/creating-managing-projects)
* [Google Cloud SDK/CLI](https://cloud.google.com/sdk/docs/install)
* [Google Cloud CLI Authentication](https://cloud.google.com/docs/authentication/gcloud)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

1. Review variables.tf and (optionally) create a `terraform.tfvars` file with required variables:
    * Your Anyscale Organization ID can be found under Organization Settings.

    ```tf
    google_project_id = "<your_project_id>"
    google_region = "<your_google_region>"
    existing_gke_cluster_name = "<your_gke_cluster_name>"
    existing_gke_cluster_location = "<your_cluster_region_or_zone>"
    existing_vpc_name      = "<your_vpc_network>"
    ```

1. Apply the terraform:

    ```shell
    terraform init
    terraform plan
    terraform apply
    ```

If you are using a `tfvars` file, you will need to update the above commands accordingly.
Note the output from Terraform which includes an example cloud registration command you will use below.

**Important**: Use the GKE Node Service Account created through Terraform to configure your node pool for running Anyscale workloads.

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:
* [Cluster autoscaler](https://cloud.google.com/kubernetes-engine/docs/concepts/cluster-autoscaler) (enabled by default in GKE)
* [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/deploy/) (other ingress controllers may be possible but are untested)
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin) (enabled by default in GKE if utilizing GPU nodes)

**Note:** Ensure that you are [authenticated to the GKE cluster](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl) for the remaining steps.

#### Install the Nginx ingress controller

Sample files, `sample-values_nginx_gke_private.yaml` and `sample-values_nginx_gke_public.yaml` have been provided in this repo. Please review for your requirements before using.

1. Choose if the cluster should be public or private facing.
2. If public, create a YAML values file named `values_nginx_gke_public.yaml`
    * Add the following:
    ```yaml
    controller:
      service:
        type: LoadBalancer
        annotations:
          cloud.google.com/load-balancer-type: "External"
      allowSnippetAnnotations: true
      autoscaling:
        enabled: true
    ```
3. If private, create a YAML values file named `values_nginx_gke_private.yaml`
    * Add the following:
    ```yaml
    controller:
      service:
        type: LoadBalancer
        annotations:
          cloud.google.com/load-balancer-type: "Internal"
      allowSnippetAnnotations: true
      autoscaling:
        enabled: true
    ```
4. Run the following, replacing with the appropriate values file:

    ```shell
    helm repo add nginx https://kubernetes.github.io/ingress-nginx
    helm upgrade ingress-nginx nginx/ingress-nginx \
      --version 4.12.1 \
      --namespace ingress-nginx \
      --values values_nginx_gke_<private|public>.yaml \
      --create-namespace \
      --install
    ```

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

1. Using the output from the Terraform modules, register the Anyscale Cloud. It will look like:

```shell
anyscale cloud register \
  --name <cloud_name> \
  --provider gcp \
  --region <gke_region> \
  --compute-stack k8s \
  --kubernetes-zones <gke_zones> \
  --anyscale-operator-iam-identity <service_account_email> \
  --cloud-storage-bucket-name <storage_bucket> \
  --project-id <project_id> \
  --vpc-name <vpc_name> \
  --file-storage-id <filestore_name> \
  --filestore-location <filestore_zone>
```

**Please note:** You must change the cloud name to a name that you choose. You will not be able to register a cloud with a name of `<CUSTOMER_DEFINED_NAME>`.

1. After running the command, capture the Cloud Deployment ID from the output - you'll need this for subsequent steps.

### Install the Anyscale Operator

1. Using the below example, replace `<gke_region>` with the GCP region where GKE is running, replace `<service_account_email>` with the Google Cloud service account email, and replace `<cloud_deployment_id>` with the appropriate value from the `anyscale cloud register` output. Please note that you can also change the namespace to one that you wish to associate with Anyscale pods.
1. Using your updated helm upgrade command, install the Anyscale Operator.
1. Install the Anyscale Operator using the cloud deployment ID from the previous step:

    ```shell
    helm repo add anyscale https://anyscale.github.io/helm-charts
    helm upgrade anyscale-operator anyscale/anyscale-operator \
      --set-string cloudDeploymentId=<cloud_deployment_id> \
      --set-string cloudProvider=gcp \
      --set-string region=<gke_region> \
      --set-string operatorIamIdentity=<service_account_email> \
      --set-string workloadServiceAccountName=anyscale-operator \
      --namespace anyscale-operator \
      --create-namespace \
      --install
    ```

1. (Optional) For the L4 GPU instances (`g2-standard-16`) to work, modify the Anyscale Operator `instance-types` ConfigMap:
    ```
      instance_types.yaml: |-
        ...
        8CPU-32GB-1xL4:
          resources:
            CPU: 8
            GPU: 1
            accelerator_type:L4: 1
            memory: 32Gi
    ```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | 5.45.2 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_anyscale_cloudstorage"></a> [anyscale\_cloudstorage](#module\_anyscale\_cloudstorage) | github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-cloudstorage | n/a |
| <a name="module_anyscale_filestore"></a> [anyscale\_filestore](#module\_anyscale\_filestore) | github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-filestore | n/a |

## Resources

| Name | Type |
|------|------|
| [google_compute_firewall.allow-common-ingress](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_project_iam_member.gke_nodes_roles](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/project_iam_member) | resource |
| [google_service_account.gke_nodes](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account) | resource |
| [google_service_account_iam_binding.workload_identity_bindings](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_account_iam_binding) | resource |
| [google_compute_zones.available](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/compute_zones) | data source |
| [google_container_cluster.existing_gke_cluster](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_existing_gke_cluster_location"></a> [existing\_gke\_cluster\_location](#input\_existing\_gke\_cluster\_location) | (Required) The location of the existing GKE cluster.<br><br>This value can be found in the Google Cloud Console under "Kubernetes Engine" > "Clusters".<br>If the cluster is regional, this will be the region (e.g., "us-central1").<br><br>ex:<pre>existing_gke_cluster_location = "us-central1-a"</pre> | `string` | n/a | yes |
| <a name="input_existing_gke_cluster_name"></a> [existing\_gke\_cluster\_name](#input\_existing\_gke\_cluster\_name) | (Required) The name of the existing GKE cluster.<br><br>This value can be found in the Google Cloud Console under "Kubernetes Engine" > "Clusters".<br><br>ex:<pre>existing_gke_cluster_name = "my-gke-cluster"</pre> | `string` | n/a | yes |
| <a name="input_existing_vpc_name"></a> [existing\_vpc\_name](#input\_existing\_vpc\_name) | (Required) The name of the existing VPC | `string` | n/a | yes |
| <a name="input_google_project_id"></a> [google\_project\_id](#input\_google\_project\_id) | (Required) The Google Cloud Project ID<br><br>This value can be found in the Google Cloud Console under "Project info".<br><br>ex:<pre>google_project_id = "my-project-id"</pre> | `string` | n/a | yes |
| <a name="input_google_region"></a> [google\_region](#input\_google\_region) | (Required) The Google region in which all resources will be created.<br><br>ex:<pre>google_region = "us-central1"</pre> | `string` | n/a | yes |
| <a name="input_anyscale_cloud_id"></a> [anyscale\_cloud\_id](#input\_anyscale\_cloud\_id) | (Optional) Anyscale Cloud ID<br><br>This value can be found under "Cloud settings" in the Anyscale Console This will be used for labeling resources.<br><br>ex:<pre>anyscale_cloud_id = "cld_12345abcdefghijklmnop67890"</pre> | `string` | `null` | no |
| <a name="input_anyscale_k8s_namespace"></a> [anyscale\_k8s\_namespace](#input\_anyscale\_k8s\_namespace) | (Optional) The Anyscale namespace to deploy the workload<br><br>ex:<pre>anyscale_k8s_namespace = "anyscale-operator"</pre> | `string` | `"anyscale-operator"` | no |
| <a name="input_enable_filestore"></a> [enable\_filestore](#input\_enable\_filestore) | (Optional) Enable the creation of a Google Filestore instance.<br><br>This is optional for Anyscale deployments. Filestore is used for shared storage between nodes.<br><br>ex:<pre>enable_filestore = true</pre> | `bool` | `false` | no |
| <a name="input_ingress_cidr_ranges"></a> [ingress\_cidr\_ranges](#input\_ingress\_cidr\_ranges) | (Optional) The IPv4 CIDR blocks that allows access Anyscale clusters.<br><br>These are added to the firewall and allows port 443 (https) and 22 (ssh) access.<br><br>ex:<pre>ingress_cidr_ranges=["52.1.1.23/32","10.1.0.0/16"]</pre> | `list(string)` | <pre>[<br>  "0.0.0.0/0"<br>]</pre> | no |
| <a name="input_labels"></a> [labels](#input\_labels) | (Optional) A map of labels to all resources that accept labels.<br><br>ex:<pre>labels = {<br>  "example" = true<br>  "environment" = "example"<br>}</pre> | `map(string)` | <pre>{<br>  "environment": "example",<br>  "example": true<br>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_anyscale_operator_service_account_email"></a> [anyscale\_operator\_service\_account\_email](#output\_anyscale\_operator\_service\_account\_email) | The Anyscale operator service account email. |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The Anyscale registration command. |
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-terraform-google-cloudfoundation-modules/issues
[badge-build]: https://github.com/anyscale/sa-terraform-google-cloudfoundation-modules/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-google]: https://img.shields.io/badge/GCP-6.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/sa-terraform-google-cloudfoundation-modules/actions
