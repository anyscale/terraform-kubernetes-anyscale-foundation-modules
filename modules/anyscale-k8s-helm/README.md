[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![OpenTofu Version][badge-opentofu]](https://github.com/opentofu/opentofu/releases)
[![Kubernetes Provider Version][badge-tf-kubernetes]](https://github.com/terraform-providers/terraform-provider-kubernetes/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)
[![Google Provider Version][badge-tf-google]](https://github.com/terraform-providers/terraform-provider-google/releases)

# anyscale-k8s-helm
This module creates Kubernetes helm charts for Anyscale applications and workloads.

<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 2.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |
| <a name="requirement_time"></a> [time](#requirement\_time) | >= 0.12 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_helm"></a> [helm](#provider\_helm) | 2.15.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | 2.32.0 |
| <a name="provider_time"></a> [time](#provider\_time) | 0.12.1 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [helm_release.anyscale_cluster_autoscaler](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.aws_loadbalancer](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.feature_metrics_server](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nginx_ingress](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.nvidia](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.prometheus](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubernetes_namespace.ingress_nginx](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/namespace) | resource |
| [time_sleep.wait_helm_termination](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [time_sleep.wait_ingress](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) | resource |
| [kubernetes_service.nginx_ingress](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/data-sources/service) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cloud_provider"></a> [cloud\_provider](#input\_cloud\_provider) | (Required) The cloud provider (aws or gcp)<br><br>ex:<pre>cloud_provider = "aws"</pre> | `string` | n/a | yes |
| <a name="input_anyscale_aws_loadbalancer_chart"></a> [anyscale\_aws\_loadbalancer\_chart](#input\_anyscale\_aws\_loadbalancer\_chart) | (Optional) The Helm chart to install the AWS Load Balancer Controller.<br><br>Requires `cloud_provider` to be set to `aws`.<br><br>ex:<pre>anyscale_aws_loadbalancer_chart = {<br>  enabled       = true<br>  name          = "aws-load-balancer-controller"<br>  repository   = "https://aws.github.io/eks-charts"<br>  chart         = "aws-load-balancer-controller"<br>  chart_version = "1.2.7"<br>  namespace     = "kube-system"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "aws-load-balancer-controller",<br>  "chart_version": "1.11.0",<br>  "enabled": true,<br>  "name": "aws-load-balancer-controller",<br>  "namespace": "kube-system",<br>  "repository": "https://aws.github.io/eks-charts",<br>  "values": {}<br>}</pre> | no |
| <a name="input_anyscale_cluster_autoscaler_chart"></a> [anyscale\_cluster\_autoscaler\_chart](#input\_anyscale\_cluster\_autoscaler\_chart) | (Optional) The Helm chart to install the Cluster Autoscaler.<br><br>ex:<pre>anyscale_cluster_autoscaler_chart = {<br>  enabled       = true<br>  name          = "cluster-autoscaler"<br>  respository   = "https://kubernetes.github.io/autoscaler"<br>  chart         = "cluster-autoscaler"<br>  chart_version = "9.37.0"<br>  namespace     = "kube-system"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "cluster-autoscaler",<br>  "chart_version": "9.37.0",<br>  "enabled": true,<br>  "name": "cluster-autoscaler",<br>  "namespace": "kube-system",<br>  "repository": "https://kubernetes.github.io/autoscaler",<br>  "values": {}<br>}</pre> | no |
| <a name="input_anyscale_ingress_chart"></a> [anyscale\_ingress\_chart](#input\_anyscale\_ingress\_chart) | (Optional) The Helm chart to install the Cluster Ingress.<br><br>ex:<pre>anyscale_ingress_chart = {<br>  enabled       = true<br>  name          = "anyscale-ingress"<br>  respository   = "https://kubernetes.github.io/ingress-nginx"<br>  chart         = "ingress-nginx"<br>  chart_version = "4.11.1"<br>  namespace     = "ingress-nginx"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "ingress-nginx",<br>  "chart_version": "4.11.1",<br>  "enabled": true,<br>  "name": "anyscale-ingress",<br>  "namespace": "ingress-nginx",<br>  "repository": "https://kubernetes.github.io/ingress-nginx",<br>  "values": {<br>    "controller.allowSnippetAnnotations": "true",<br>    "controller.autoscaling.enabled": "true",<br>    "controller.service.type": "LoadBalancer"<br>  }<br>}</pre> | no |
| <a name="input_anyscale_ingress_internal_lb"></a> [anyscale\_ingress\_internal\_lb](#input\_anyscale\_ingress\_internal\_lb) | (Optioanl) Determines if the AWS NLB should be internal.<br><br>Requires `cloud_provider` to be set to `aws`.<br>Requires `anyscale_ingress_chart` to be enabled.<br><br>ex:<pre>anyscale_ingress_internal_lb = true</pre> | `bool` | `false` | no |
| <a name="input_anyscale_metrics_server_chart"></a> [anyscale\_metrics\_server\_chart](#input\_anyscale\_metrics\_server\_chart) | (Optional) The Helm chart to install the Metrics Server.<br><br>Required for the Anyscale Autoscaler to function.<br><br>ex:<pre>anyscale_metrics_server_chart = {<br>  enabled       = true<br>  name          = "metrics-server"<br>  respository   = "https://kubernetes-sigs.github.io/metrics-server/"<br>  chart         = "metrics-server"<br>  chart_version = "3.12.1"<br>  namespace     = "metrics-server"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "metrics-server",<br>  "chart_version": "3.12.1",<br>  "enabled": true,<br>  "name": "metrics-server",<br>  "namespace": "metrics-server",<br>  "repository": "https://kubernetes-sigs.github.io/metrics-server/",<br>  "values": {}<br>}</pre> | no |
| <a name="input_anyscale_nvidia_device_plugin_chart"></a> [anyscale\_nvidia\_device\_plugin\_chart](#input\_anyscale\_nvidia\_device\_plugin\_chart) | (Optional) The Helm chart to install the NVIDIA Device Plugin.<br><br>Valid settings can be found in the [nvidia documentation](https://github.com/NVIDIA/k8s-device-plugin?tab=readme-ov-file#deploying-with-gpu-feature-discovery-for-automatic-node-labels)<br><br>ex:<pre>anyscale_nvidia_device_plugin_chart = {<br>  enabled       = true<br>  name          = "nvidia-device-plugin"<br>  respository   = "https://nvidia.github.io/k8s-device-plugin"<br>  chart         = "nvidia-device-plugin"<br>  chart_version = "0.16.2"<br>  namespace     = "nvidia-device-plugin"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "nvidia-device-plugin",<br>  "chart_version": "0.16.2",<br>  "enabled": true,<br>  "name": "anyscale-nvidia-device-plugin",<br>  "namespace": "nvidia-device-plugin",<br>  "repository": "https://nvidia.github.io/k8s-device-plugin",<br>  "values": {<br>    "gfd.enabled": "true",<br>    "nfd.worker.tolerations[0].effect": "NoSchedule",<br>    "nfd.worker.tolerations[0].key": "node-role.kubernetes.io/master",<br>    "nfd.worker.tolerations[0].operator": "Equal",<br>    "nfd.worker.tolerations[0].value": "",<br>    "nfd.worker.tolerations[1].effect": "NoSchedule",<br>    "nfd.worker.tolerations[1].key": "nvidia.com/gpu",<br>    "nfd.worker.tolerations[1].operator": "Equal",<br>    "nfd.worker.tolerations[1].value": "present",<br>    "nfd.worker.tolerations[2].effect": "NoSchedule",<br>    "nfd.worker.tolerations[2].key": "node.anyscale.com/accelerator-type",<br>    "nfd.worker.tolerations[2].operator": "Equal",<br>    "nfd.worker.tolerations[2].value": "GPU",<br>    "nfd.worker.tolerations[3].effect": "NoSchedule",<br>    "nfd.worker.tolerations[3].key": "node.anyscale.com/capacity-type",<br>    "nfd.worker.tolerations[3].operator": "Equal",<br>    "nfd.worker.tolerations[3].value": "ANY",<br>    "priorityClassName": "system-node-critical",<br>    "tolerations[0].effect": "NoSchedule",<br>    "tolerations[0].key": "nvidia.com/gpu",<br>    "tolerations[0].operator": "Equal",<br>    "tolerations[0].value": "present",<br>    "tolerations[1].effect": "NoSchedule",<br>    "tolerations[1].key": "node.anyscale.com/accelerator-type",<br>    "tolerations[1].operator": "Equal",<br>    "tolerations[1].value": "GPU",<br>    "tolerations[2].effect": "NoSchedule",<br>    "tolerations[2].key": "node.anyscale.com/capacity-type",<br>    "tolerations[2].operator": "Equal",<br>    "tolerations[2].value": "ANY"<br>  }<br>}</pre> | no |
| <a name="input_anyscale_prometheus_chart"></a> [anyscale\_prometheus\_chart](#input\_anyscale\_prometheus\_chart) | (Optional) The Helm chart to install Prometheus.<br><br>ex:<pre>anyscale_prometheus_chart = {<br>  enabled       = true<br>  name          = "prometheus"<br>  respository   = "https://prometheus-community.github.io/helm-charts"<br>  chart         = "prometheus"<br>  chart_version = "16.0.0"<br>  namespace     = "prometheus"<br>  values        = {<br>    "some.other.config" = "value"<br>  }<br>}</pre> | <pre>object({<br>    enabled       = bool<br>    name          = optional(string)<br>    repository    = optional(string)<br>    chart         = optional(string)<br>    chart_version = optional(string)<br>    namespace     = optional(string)<br>    values        = optional(map(string))<br>  })</pre> | <pre>{<br>  "chart": "prometheus",<br>  "chart_version": "25.26.0",<br>  "enabled": false,<br>  "name": "prometheus",<br>  "namespace": "prometheus",<br>  "repository": "https://prometheus-community.github.io/helm-charts",<br>  "values": {}<br>}</pre> | no |
| <a name="input_eks_cluster_region"></a> [eks\_cluster\_region](#input\_eks\_cluster\_region) | (Optional) The region of the EKS cluster.<br><br>ex:<pre>eks_cluster_region = "us-west-2"</pre> | `string` | `null` | no |
| <a name="input_kubernetes_cluster_name"></a> [kubernetes\_cluster\_name](#input\_kubernetes\_cluster\_name) | (Optional) The name of the Kubernetes cluster.<br><br>ex:<pre>kubernetes_cluster_name = "my-cluster"</pre> | `string` | `null` | no |
| <a name="input_module_enabled"></a> [module\_enabled](#input\_module\_enabled) | (Optional) Determines if this module should create resources.<br><br>If set to true, `eks_role_arn`, `anyscale_subnet_ids`, and `anyscale_security_group_id` must be provided.<br>ex:<pre>module_enabled = true</pre> | `bool` | `false` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_helm_autoscaler_status"></a> [helm\_autoscaler\_status](#output\_helm\_autoscaler\_status) | Status of the Cluster Autoscaler Helm release |
| <a name="output_helm_nginx_ingress_status"></a> [helm\_nginx\_ingress\_status](#output\_helm\_nginx\_ingress\_status) | Status of the Ingress Helm release |
| <a name="output_helm_nvidia_status"></a> [helm\_nvidia\_status](#output\_helm\_nvidia\_status) | Status of the Nvidia Helm release |
| <a name="output_nginx_ingress_lb_hostname"></a> [nginx\_ingress\_lb\_hostname](#output\_nginx\_ingress\_lb\_hostname) | Hostname of the nginx load balancer |
| <a name="output_nginx_ingress_lb_ips"></a> [nginx\_ingress\_lb\_ips](#output\_nginx\_ingress\_lb\_ips) | IPs of the nginx load balancer |
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-5.+-F8991D.svg?logo=terraform
[build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions
[badge-opentofu]: https://img.shields.io/badge/opentofu-1.x%20-623CE4.svg?logo=terraform
[badge-tf-google]: https://img.shields.io/badge/Google-5.+-F8991D.svg?logo=terraform
[badge-tf-kubernetes]: https://img.shields.io/badge/KUBERNETES-2.+-F8991D.svg?logo=terraform
