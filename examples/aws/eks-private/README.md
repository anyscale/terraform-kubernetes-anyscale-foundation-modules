<!-- [![Build Status][badge-build]][build-status] -->
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS EKS Example - Private Networking

This example creates the resources to run Anyscale on AWS EKS with private networking (only accessible via VPN). The Envoy NLB is provisioned with `aws-load-balancer-scheme: internal`, so the Anyscale gateway is reachable only from inside your VPC (or via VPN/Tailscale/bastion).

For the publicly-reachable variant where the NLB is `scheme=internet-facing`, see [`examples/aws/eks-public/`](../eks-public/).

By default the example also wires up:

* Mountpoint-for-S3 CSI driver IAM (toggle `enable_s3_pvc`, default `true`) so the Anyscale S3 bucket is mounted as a `PersistentVolumeClaim` and registered as Anyscale shared storage via `file_storage.persistent_volume_claim` in the rendered cloud-resource YAML — configured up front at cloud registration so workloads can mount `/mnt/cluster_storage` from first launch.
* (Optional) An AWS MemoryDB (Redis) cluster (toggle `enable_memorydb`, default `false`) provisioned via the upstream [`aws-anyscale-memorydb`](https://github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules/tree/main/modules/aws-anyscale-memorydb) submodule. The endpoint is rendered into the cloud-resource YAML as `kubernetes_config.redis_endpoint` so [Anyscale Services head-node fault tolerance](https://docs.anyscale.com/release-notes/cli-sdk#0-26-99-features) is enabled at registration time.

The content of this module should be used as a starting point and modified to your own security and infrastructure requirements.

## Getting Started

### Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [AWS Credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) — **version `>=0.26.99` required if `enable_memorydb = true`** (for the `kubernetes_config.redis_endpoint` field).

The Envoy Gateway v1.7.0 helm chart used below requires Kubernetes 1.30+. The default `eks_cluster_version` (1.35 — latest on EKS Standard support as of Dec 2025) already satisfies this.

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review `variables.tf` and (optionally) create a `terraform.tfvars` file to override any defaults.
* Apply the terraform.

```shell
terraform init
terraform plan
terraform apply
```

`terraform apply` writes two files into `./generated/` for use in later steps:

* `generated/pv-pvc.yaml` — applied via `kubectl` when `enable_s3_pvc = true` (the default).
* `generated/deploy.sh` — an executable shell script that runs every post-terraform step in order (cloud register → kubectl/helm installs → verify). Use it to drive the full flow end-to-end, or copy-paste sections of it.

Note the Terraform output, which includes the cloud registration and helm upgrade commands used below.

> **Tip — drive the post-terraform steps from `generated/deploy.sh`.** The script wraps every step in this README (Register → Authenticate → Install autoscaler/LBC/Envoy Gateway → Apply PVC → Install Operator → Verify) in order. Either run it end-to-end (`./generated/deploy.sh`) or open it side-by-side with this README and copy-paste step by step. The rest of this README documents what that script is doing so you can adapt or run pieces of it manually. Because the EKS API endpoint is private-only by default, the script must be run from inside the VPC (VPN or bastion).

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials (`anyscale login`). Registration runs against the Anyscale control plane only — no cluster connectivity required — and returns a `cldrsrc_…` cloud deployment id that the next steps use.

The `anyscale_registration_command` Terraform output expands the cloud-resource details (region, S3 bucket, PVC name, MemoryDB endpoint if enabled, zones, operator IAM identity) into a flag-based `anyscale cloud register` invocation:

```shell
terraform output -raw anyscale_registration_command | sh
```

> The `anyscale cloud register -f <file>` (YAML) path is not currently usable for K8s compute stacks — CLI 0.26.100 rejects the K8s CloudResource on a missing `aws_config` block whose schema isn't documented. Use the CLI-flags command above.

Capture the cloud deployment id from the CLI output and export it — later steps reference it:

```shell
export CLOUD_DEPLOYMENT_ID=cldrsrc_...
```

### Authenticate to the EKS Cluster

Configure `kubectl` against the new cluster:

```shell
aws eks update-kubeconfig --region <aws_region> --name <eks_cluster_name>
```

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:

* [Cluster autoscaler](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)
* [AWS LBC (Load Balancer Controller)](https://github.com/kubernetes-sigs/aws-load-balancer-controller/tree/main/helm/aws-load-balancer-controller)
* [Envoy Gateway](https://gateway.envoyproxy.io/) and the Anyscale Gateway manifests
* The S3 PV/PVC (when `enable_s3_pvc = true`; the CSI driver itself is installed as an EKS managed addon by Terraform)
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) — required if utilizing GPU nodes

#### Install the Cluster Autoscaler

```shell
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.46.0 \
  --namespace kube-system \
  --set awsRegion=<aws_region> \
  --set 'autoDiscovery.clusterName'=<eks_cluster_name> \
  --install
```

#### Install the AWS Load Balancer Controller

Pass `region` and `vpcId` explicitly so the controller does not depend on reaching IMDSv2 to introspect them (some EKS Pod Identity / IMDS hop configurations block IMDS access from pods). Get the VPC id from `aws eks describe-cluster --name <eks_cluster_name> --query 'cluster.resourcesVpcConfig.vpcId' --output text`.

```shell
helm repo add eks https://aws.github.io/eks-charts
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.13.2 \
  --namespace kube-system \
  --set clusterName=<eks_cluster_name> \
  --set region=<aws_region> \
  --set vpcId=<vpc_id> \
  --install
```

#### Install Envoy Gateway and the Anyscale Gateway

The provided `sample-values_gateway.yaml` contains three documents that set up the Anyscale Envoy Gateway with `aws-load-balancer-scheme: internal`:

* An `EnvoyProxy` in `envoy-gateway-system` configuring AWS NLB annotations (internal, NLB, instance-target, cross-zone).
* A `GatewayClass` named `eg` that adds `parametersRef → EnvoyProxy` to the helm chart's default class.
* A `Gateway` in `anyscale-operator` with three listeners: an `http:80` bootstrap listener (no app traffic; needed so Envoy Gateway will program the Gateway before the Operator creates the TLS Secrets below), `https:443` for `*.i.anyscaleuserdata.com` (head-node) → secret `anyscale-<cldrsrc-id>-certificate`, and `https-session:443` for `*.s.anyscaleuserdata.com` (services) → secret `anyscale-svc-<cldrsrc-id>-certificate`.

Before applying, substitute the `<cldrsrc-with-dashes>` placeholder in the gateway YAML with the cldrsrc slug (the cloud deployment id with `_` replaced by `-`) so the TLS listeners reference the real Secret names from the start. The Operator (installed below) will create those Secrets once it's running, and the listeners flip to `ResolvedRefs: True` automatically — no second `kubectl apply` needed.

> Pasting the underscored `cldrsrc_xxx` form looks valid but is wrong — the operator's TLS Secret name uses dashes, so the listener silently stays at `ResolvedRefs: False`. The placeholder is named to spell that out.

1. Install Envoy Gateway. Apply CRDs separately so reruns with a newer chart version pick up new Gateway API / Envoy Gateway CRD fields — `helm upgrade --install` only installs `chart/crds/` on first install by design:

   ```shell
   EG_CRD_DIR=$(mktemp -d)
   trap 'rm -rf "$EG_CRD_DIR"' EXIT
   helm pull oci://docker.io/envoyproxy/gateway-helm --version v1.7.0 \
     --untar --untardir "$EG_CRD_DIR"
   kubectl apply --server-side --force-conflicts -f "$EG_CRD_DIR/gateway-helm/crds/"
   helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
     --version v1.7.0 \
     --namespace envoy-gateway-system \
     --create-namespace \
     --skip-crds \
     --install
   kubectl wait --for=condition=available deployment/envoy-gateway \
     -n envoy-gateway-system --timeout=120s
   ```

2. Substitute the cldrsrc slug and apply the Anyscale gateway documents:

   ```shell
   SECRET_SLUG=${CLOUD_DEPLOYMENT_ID//_/-}    # cldrsrc_xxx → cldrsrc-xxx
   sed "s/<cldrsrc-with-dashes>/${SECRET_SLUG}/g" sample-values_gateway.yaml | kubectl apply -f -
   ```

3. Wait for the Gateway to be programmed and capture the internal NLB hostname:

   ```shell
   kubectl wait -n anyscale-operator --for=condition=Programmed gateway/gateway --timeout=300s
   GATEWAY_HOSTNAME=$(kubectl get gateway gateway -n anyscale-operator \
     -o jsonpath='{.status.addresses[0].value}')
   echo "$GATEWAY_HOSTNAME"
   ```

   The `https` listener for `*.i.anyscaleuserdata.com` will report `ResolvedRefs: False` until the Operator install (next step) creates its TLS Secret — that's expected and doesn't block NLB programming. The `https-session` listener stays `ResolvedRefs: False` until the first Anyscale service runs.

#### Apply the S3 PVC

When `enable_s3_pvc = true` (the default), the Mountpoint-for-S3 CSI driver is installed via the **`aws-mountpoint-s3-csi-driver` EKS managed addon** — Terraform manages it through `cluster_addons` in `eks.tf` alongside coredns/kube-proxy, and AWS manages upgrades. The addon's `pod_identity_association` is wired to the IAM role from `s3_csi.tf` so the driver pods get bucket access from the first reconcile.

That leaves only the PV/PVC to apply:

```shell
kubectl apply -f ./generated/pv-pvc.yaml
kubectl wait -n anyscale-operator --for=jsonpath='{.status.phase}'=Bound \
  pvc/anyscale-shared-fuse --timeout=120s
```

This mounts the Anyscale S3 bucket as the `anyscale-shared-fuse` PVC in the `anyscale-operator` namespace, exposed to Anyscale workloads at `/mnt/cluster_storage`.

#### (Optional) Install the Nvidia Device Plugin

Required only when GPU nodes are in use. A sample file `sample-values_nvdp.yaml` is provided.

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values sample-values_nvdp.yaml \
  --create-namespace \
  --install
```

### Install the Anyscale Operator

The Terraform output `helm_upgrade_command` is pre-populated with the gateway settings (`networking.gateway.name=gateway`, `networking.gateway.namespace=anyscale-operator`, `networking.gateway.apiVersion=gateway.networking.k8s.io/v1`). Substitute `<cloud-deployment-id>` (from `$CLOUD_DEPLOYMENT_ID`), `<aws_region>`, and `<gateway-nlb-hostname>` (from `$GATEWAY_HOSTNAME`):

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=$CLOUD_DEPLOYMENT_ID \
  --set-string global.cloudProvider=aws \
  --set-string global.aws.region=<aws_region> \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set networking.gateway.enabled=true \
  --set-string networking.gateway.name=gateway \
  --set-string networking.gateway.namespace=anyscale-operator \
  --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
  --set-string networking.gateway.hostname=$GATEWAY_HOSTNAME \
  --namespace anyscale-operator \
  --install
```

### Verify the Deployment

Once the operator starts, it creates the head-node TLS Secret `anyscale-${CLOUD_DEPLOYMENT_ID//_/-}-certificate` in the `anyscale-operator` namespace. The Gateway's `https` listener was already configured to reference that name in the previous step, so it auto-flips to `ResolvedRefs: True` — no reapply needed.

```shell
# Confirm the Secret exists and the listener resolved:
kubectl get secret anyscale-${CLOUD_DEPLOYMENT_ID//_/-}-certificate -n anyscale-operator
kubectl get gateway gateway -n anyscale-operator -o jsonpath='{range .status.listeners[*]}{.name}: ResolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}'
kubectl get httproutes -n anyscale-operator   # operator auto-creates routes once workloads launch
```

The `https-session` listener for `*.s.anyscaleuserdata.com` will remain `ResolvedRefs: False` until you launch your first Anyscale service — its Secret (`anyscale-svc-<slug>-certificate`) is provisioned lazily.

### (Optional) MemoryDB

When `enable_memorydb = true`, Terraform provisions an AWS MemoryDB cluster in the private subnets via the `aws-anyscale-memorydb` submodule. The cluster endpoint is already wired into the rendered registration command's `--memorydb-cluster-id` flag, so no additional step is required — Anyscale Services head-node fault tolerance is enabled at registration time.

The MemoryDB security group permits Redis ingress (port 6379 by default) only from the EKS managed node security group.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.7 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | ~> 2.0 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.44.0 |
| <a name="provider_local"></a> [local](#provider\_local) | 2.8.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_anyscale_efs"></a> [anyscale\_efs](#module\_anyscale\_efs) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs | n/a |
| <a name="module_anyscale_iam_roles"></a> [anyscale\_iam\_roles](#module\_anyscale\_iam\_roles) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam | n/a |
| <a name="module_anyscale_memorydb"></a> [anyscale\_memorydb](#module\_anyscale\_memorydb) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-memorydb | n/a |
| <a name="module_anyscale_s3"></a> [anyscale\_s3](#module\_anyscale\_s3) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3 | n/a |
| <a name="module_anyscale_vpc"></a> [anyscale\_vpc](#module\_anyscale\_vpc) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-vpc | n/a |
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | 21.20.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.autoscaler_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.elb_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.s3_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.s3_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_security_group.allow_all_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.memorydb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [local_file.deploy_script](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [local_file.pv_pvc_yaml](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [aws_iam_role.default_nodegroup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_anyscale_cloud_name"></a> [anyscale\_cloud\_name](#input\_anyscale\_cloud\_name) | (Optional) Anyscale cloud name passed to `anyscale cloud register --name`.<br/><br/>Pick a name that is unique within your Anyscale organization.<br/><br/>ex:<pre>anyscale_cloud_name = "my-eks-private-cloud"</pre> | `string` | `"anyscale-eks-private"` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | (Optional) The AWS region in which all resources will be created.<br/><br/>ex:<pre>aws_region = "us-east-2"</pre> | `string` | `"us-east-2"` | no |
| <a name="input_bucket_force_destroy"></a> [bucket\_force\_destroy](#input\_bucket\_force\_destroy) | (Optional) When true, `terraform destroy` will delete the Anyscale S3 bucket<br/>even if it still contains objects (operator logs, cluster metadata, mounted<br/>PVC data, etc.). Default is `false` so accidental destroys do not wipe data.<br/><br/>Set to `true` for ephemeral dev / e2e test deployments where you want<br/>teardown to be one command. See `dev-overrides.tfvars.example` for a ready-made<br/>override file.<br/><br/>ex:<pre>bucket_force_destroy = true</pre> | `bool` | `false` | no |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | (Optional) The name of the EKS cluster.<br/><br/>This will be used for naming resources created by this module including the EKS cluster and the S3 bucket.<br/><br/>ex:<pre>eks_cluster_name = "anyscale-eks-private"</pre> | `string` | `"anyscale-eks-private"` | no |
| <a name="input_eks_cluster_version"></a> [eks\_cluster\_version](#input\_eks\_cluster\_version) | (Optional) The Kubernetes version of the EKS cluster.<br/><br/>Default tracks the latest version available on EKS Standard support.<br/>Envoy Gateway v1.7.0 requires Kubernetes >= 1.30.<br/><br/>ex:<pre>eks_cluster_version = "1.35"</pre> | `string` | `"1.35"` | no |
| <a name="input_enable_efs"></a> [enable\_efs](#input\_enable\_efs) | (Optional) Enable the creation of an EFS instance.<br/><br/>Provisions an EFS file system as Anyscale shared storage. Mutually useful with — but typically an alternative to — `enable_s3_pvc`: only one backend is normally attached to an Anyscale cloud at a time.<br/><br/>ex:<pre>enable_efs = true</pre> | `bool` | `false` | no |
| <a name="input_enable_memorydb"></a> [enable\_memorydb](#input\_enable\_memorydb) | (Optional) Provision an AWS MemoryDB (Redis) cluster in the private subnets via the `aws-anyscale-memorydb` cloudfoundation submodule, and emit its endpoint as `kubernetes_config.redis_endpoint` in the rendered cloud-resource YAML.<br/><br/>This wires Anyscale Services head-node fault tolerance (Anyscale CLI/SDK >= 0.26.99 required).<br/><br/>ex:<pre>enable_memorydb = true</pre> | `bool` | `false` | no |
| <a name="input_enable_s3_pvc"></a> [enable\_s3\_pvc](#input\_enable\_s3\_pvc) | (Optional) Provision the IAM role + EKS Pod Identity association for the Mountpoint for Amazon S3 CSI driver, and render a `generated/pv-pvc.yaml` that mounts the Anyscale S3 bucket as a PersistentVolumeClaim used as Anyscale shared storage.<br/><br/>This is the AWS equivalent of the Azure blob PVC pattern documented at<br/>https://docs.anyscale.com/clouds/azure/pvc — wired up at registration time<br/>via `file_storage.persistent_volume_claim` in the rendered cloud-resource<br/>YAML, rather than via post-hoc `anyscale cloud update`.<br/><br/>ex:<pre>enable_s3_pvc = true</pre> | `bool` | `true` | no |
| <a name="input_gpu_instance_types"></a> [gpu\_instance\_types](#input\_gpu\_instance\_types) | (Optional) GPU types configuration for the EKS cluster.<br/>See gpu\_instances.tfvars.example for additional GPU types.<br/><br/>ex:<pre>gpu_instance_types = {<br/>  "T4" = {<br/>    product_name   = "Tesla-T4"<br/>    instance_types = ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge"]<br/>  }<br/>  "A10G" = {<br/>    product_name   = "NVIDIA-A10G"<br/>    instance_types = ["g5.4xlarge"]<br/>  }<br/>}</pre> | <pre>map(object({<br/>    product_name   = string<br/>    instance_types = list(string)<br/>  }))</pre> | <pre>{<br/>  "T4": {<br/>    "instance_types": [<br/>      "g4dn.4xlarge"<br/>    ],<br/>    "product_name": "Tesla-T4"<br/>  }<br/>}</pre> | no |
| <a name="input_memorydb_node_type"></a> [memorydb\_node\_type](#input\_memorydb\_node\_type) | (Optional) MemoryDB node type. Only used when `enable_memorydb = true`.<br/><br/>See https://docs.aws.amazon.com/memorydb/latest/devguide/nodes.supportedtypes.html.<br/><br/>ex:<pre>memorydb_node_type = "db.r7g.large"</pre> | `string` | `"db.t4g.small"` | no |
| <a name="input_memorydb_num_replicas_per_shard"></a> [memorydb\_num\_replicas\_per\_shard](#input\_memorydb\_num\_replicas\_per\_shard) | (Optional) Number of replicas per MemoryDB shard. Only used when `enable_memorydb = true`. | `number` | `1` | no |
| <a name="input_memorydb_num_shards"></a> [memorydb\_num\_shards](#input\_memorydb\_num\_shards) | (Optional) Number of MemoryDB shards. Only used when `enable_memorydb = true`. | `number` | `1` | no |
| <a name="input_memorydb_port"></a> [memorydb\_port](#input\_memorydb\_port) | (Optional) Port on which the MemoryDB cluster listens. Only used when `enable_memorydb = true`. | `number` | `6379` | no |
| <a name="input_node_group_disk_size"></a> [node\_group\_disk\_size](#input\_node\_group\_disk\_size) | (Optional) The disk size (GB) of the EKS nodes.<br/>Possible values: [500, 1000]<br/><br/>ex:<pre>node_group_disk_size = 1000</pre> | `number` | `500` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) A map of tags to all resources that accept tags.<br/><br/>ex:<pre>tags = {<br/>  Environment = "dev"<br/>  Repo        = "terraform-kubernetes-anyscale-foundation-modules",<br/>}</pre> | `map(string)` | <pre>{<br/>  "Environment": "dev",<br/>  "Example": "aws/eks-private",<br/>  "Repo": "terraform-kubernetes-anyscale-foundation-modules",<br/>  "Test": "true"<br/>}</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The `anyscale cloud register` command with all required flags pre-populated. |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | The AWS region. This is used for Helm chart values. |
| <a name="output_deploy_script_path"></a> [deploy\_script\_path](#output\_deploy\_script\_path) | Path to a rendered shell script containing every post-terraform step in order (autoscaler, AWS LBC, Envoy Gateway + manifests, PVC, Anyscale Operator, verify). Open it to copy-paste steps, or run end-to-end after exporting CLOUD\_DEPLOYMENT\_ID. |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | The name of the EKS cluster. This is used for Helm chart values. |
| <a name="output_helm_upgrade_command"></a> [helm\_upgrade\_command](#output\_helm\_upgrade\_command) | The Anyscale Operator helm upgrade command, with gateway settings populated for the Anyscale Envoy Gateway setup. |
| <a name="output_memorydb_endpoint"></a> [memorydb\_endpoint](#output\_memorydb\_endpoint) | MemoryDB cluster configuration endpoint as host:port. Wired into the rendered registration command's `--memorydb-cluster-id` flag. Only set when `enable_memorydb = true`. |
| <a name="output_s3_pvc_bucket_name"></a> [s3\_pvc\_bucket\_name](#output\_s3\_pvc\_bucket\_name) | Name of the S3 bucket exposed as a PVC via the Mountpoint-for-S3 CSI driver. Only set when `enable_s3_pvc = true`. |
| <a name="output_s3_pvc_csi_driver_role_arn"></a> [s3\_pvc\_csi\_driver\_role\_arn](#output\_s3\_pvc\_csi\_driver\_role\_arn) | IAM role ARN assumed by the Mountpoint-for-S3 CSI driver pods via EKS Pod Identity. The pod identity association itself is managed by the `aws-mountpoint-s3-csi-driver` EKS managed addon. Only set when `enable_s3_pvc = true`. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC id. Pass to `helm upgrade aws-load-balancer-controller --set vpcId=<this>` so the controller does not need IMDS access to introspect it. |
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-6.+-F8991D.svg?logo=terraform
<!-- [build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions -->
