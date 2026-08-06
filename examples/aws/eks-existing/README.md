<!-- [![Build Status][badge-build]][build-status] -->
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS EKS Example - Existing EKS Cluster
This example creates the resources to run Anyscale on an existing AWS EKS cluster.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Getting Started

### Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [AWS Credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)
* Existing [AWS VPC](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html)
* Existing [AWS EKS Cluster](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html) running in the existing VPC

Ensure your EKS cluster:

* Attach the IAM policy `module.anyscale_iam_roles.anyscale_iam_s3_policy_arn` and `arn:aws:iam::aws:policy/AmazonElasticFileSystemClientReadWriteAccess` to the Node IAM role

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review variables.tf and (optionally) create a `terraform.tfvars` file to override any of the defaults.
* Apply the terraform

```shell
terraform init
terraform plan
terraform apply
```

If you are using a `tfvars` file, you will need to update the above commands accordingly.

`terraform apply` writes the following files into `./generated/` for use in later steps:

* `generated/pv-pvc.yaml` — applied via `kubectl` when `enable_s3_pvc = true`.
* `generated/deploy.sh` — an executable shell script that runs every post-terraform step in order (cloud register → kubectl/helm installs → verify). Use it to drive the full flow end-to-end, or copy-paste sections of it.

> **Tip — drive the post-terraform steps from `generated/deploy.sh`.** The script wraps every step in this README (Register → Install autoscaler/LBC/Envoy Gateway → (optional) S3 CSI addon + PVC → Install Operator → Verify) in order. Because this example targets a BYO EKS cluster, you'll need to substitute the placeholders inside the script (`<eks_cluster_name>`, `<anyscale_cloud_name>`, `<node_IAM_role_arn>`) before running it. Either run it end-to-end (`./generated/deploy.sh`) or open it side-by-side with this README and copy-paste step by step.

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials (`anyscale login`). Registration runs against the Anyscale control plane only — no cluster connectivity required — and returns a `cldrsrc_…` cloud deployment id that the next steps use.

Use the `anyscale_registration_command` Terraform output (it pre-populates `--provider aws --compute-stack k8s --region <region> --name <name> --cloud-storage-bucket-name s3://<bucket> --kubernetes-zones <zones>`, plus `--persistent-volume-claim`, `--file-storage-id`, and `--memorydb-cluster-id` when those toggles are enabled). Replace the `<anyscale_cloud_name>` and `<node_IAM_role_arn>` placeholders with your values:

```shell
terraform output -raw anyscale_registration_command
# review the command, fill placeholders, then run it (or pipe to sh after editing)
```

Capture the cloud deployment id from the CLI output and export it — later steps reference it:

```shell
export CLOUD_DEPLOYMENT_ID=cldrsrc_...
```

### Installing K8s Components

The Anyscale Operator requires the following components:
* [Cluster autoscaler](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler)
* [AWS LBC (Load Balancer controller)](https://github.com/kubernetes-sigs/aws-load-balancer-controller/tree/main/helm/aws-load-balancer-controller)
* [Envoy Gateway](https://gateway.envoyproxy.io/) and the Anyscale Gateway manifests
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) (required if utilizing GPU nodes)

**Note:** Ensure that you are [authenticated to the EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html) for the remaining steps.

#### Install the Cluster autoscaler

1. Run the following to install the Kubernetes Autoscaler helm chart:

```shell
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
  --version 9.46.0 \
  --namespace kube-system \
  --set awsRegion=<aws_region> \
  --set 'autoDiscovery.clusterName'=<eks_cluster_name> \
  --install
```

#### Install the AWS LBC (load balancer controller)
1. Run the following to install the AWS Load Balancer Controller helm chart. Pass `region` and `vpcId` explicitly so the controller does not depend on reaching IMDSv2 to introspect them (some EKS Pod Identity / IMDS hop configurations block IMDS access from pods).

```shell
helm repo add eks https://aws.github.io/eks-charts
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.13.2 \
  --namespace kube-system \
  --set clusterName=<eks_cluster_name> \
  --set region=<aws_region> \
  --set vpcId=<existing_vpc_id> \
  --install
```

#### Install Envoy Gateway and the Anyscale Gateway

The provided `sample-values_gateway.yaml` contains three documents that set up the Anyscale Envoy Gateway:

* An `EnvoyProxy` in `envoy-gateway-system` configuring AWS NLB annotations (default `aws-load-balancer-scheme: internet-facing`; flip to `internal` if your cluster is private).
* A `GatewayClass` named `eg` that adds `parametersRef → EnvoyProxy` to the helm chart's default class.
* A `Gateway` in `anyscale-operator` with three listeners: an `http:80` bootstrap listener (no app traffic; needed so Envoy Gateway will program the Gateway before the Operator creates the TLS Secrets below), `https:443` for `*.i.anyscaleuserdata.com` (head-node) → secret `anyscale-<cldrsrc-id>-certificate`, and `https-session:443` for `*.s.anyscaleuserdata.com` (services) → secret `anyscale-svc-<cldrsrc-id>-certificate`.

Before applying, substitute the `<cldrsrc-with-dashes>` placeholder in the gateway YAML with the cldrsrc slug (the cloud deployment id with `_` replaced by `-`) so the TLS listeners reference the real Secret names from the start. The Operator (installed below) will create those Secrets once it's running, and the listeners flip to `ResolvedRefs: True` automatically — no second `kubectl apply` needed.

> Pasting the underscored `cldrsrc_xxx` form looks valid but is wrong — the operator's TLS Secret name uses dashes, so the listener silently stays at `ResolvedRefs: False`. The placeholder is named to spell that out.

1. Install Envoy Gateway (Kubernetes 1.30+ required by v1.7.0). Apply CRDs separately so reruns with a newer chart version pick up new Gateway API / Envoy Gateway CRD fields — `helm upgrade --install` only installs `chart/crds/` on first install by design:

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

3. Wait for the Gateway to be programmed and capture the NLB hostname:

   ```shell
   kubectl wait -n anyscale-operator --for=condition=Programmed gateway/gateway --timeout=300s
   GATEWAY_HOSTNAME=$(kubectl get gateway gateway -n anyscale-operator \
     -o jsonpath='{.status.addresses[0].value}')
   echo "$GATEWAY_HOSTNAME"
   ```

   The `https` listener will report `ResolvedRefs: False` until the Operator install (final step) creates its TLS Secret — that's expected and doesn't block NLB programming. The `https-session` listener stays `ResolvedRefs: False` until the first Anyscale service runs.

#### (Optional) MemoryDB (Redis) for Anyscale Services head-node fault tolerance

If you'd like Anyscale Services to use a managed Redis for head-node fault tolerance ([release note](https://docs.anyscale.com/release-notes/cli-sdk#0-26-99-features), Anyscale CLI/SDK >= 0.26.99 required), set in your tfvars:

```hcl
enable_memorydb                     = true
memorydb_allowed_security_group_ids = ["<your-EKS-node-security-group-id>"]
# Optional sizing knobs (defaults: db.t4g.small, 1 shard, 1 replica, port 6379):
# memorydb_node_type              = "db.r7g.large"
# memorydb_num_shards             = 1
# memorydb_num_replicas_per_shard = 1
```

Then `terraform apply` provisions:

- An `aws-anyscale-memorydb` cluster in the subnets you passed via `existing_subnet_ids`.
- A dedicated security group that allows Redis ingress (`memorydb_port`, default 6379) **only** from the security group IDs you list in `memorydb_allowed_security_group_ids` — typically your EKS managed-node-group SG so Anyscale workloads can connect.

The endpoint is available as `terraform output -raw memorydb_endpoint` (host:port format), and `anyscale_registration_command` automatically appends `--memorydb-cluster-id <id>` so the cloud is registered with the Redis endpoint at registration time.

#### (Optional) S3 PVC Plugin — Mountpoint for Amazon S3 CSI driver

If you'd like Anyscale shared storage backed by S3, set `enable_s3_pvc = true` in your tfvars and re-run `terraform apply`. Terraform creates an IAM role scoped to the Anyscale S3 bucket and renders the PV+PVC manifest at `./generated/pv-pvc.yaml`.

Because this example uses an existing EKS cluster, you also need to install the EKS managed addon and wire up the Pod Identity Association yourself. Two `aws eks` calls:

```shell
# 1. Install the EKS managed addon (idempotent)
aws eks create-addon \
  --cluster-name <eks_cluster_name> \
  --addon-name aws-mountpoint-s3-csi-driver \
  --resolve-conflicts OVERWRITE

# 2. Bind the CSI service account to the IAM role created by Terraform
aws eks create-pod-identity-association \
  --cluster-name <eks_cluster_name> \
  --namespace kube-system \
  --service-account s3-csi-driver-sa \
  --role-arn $(terraform output -raw s3_pvc_csi_driver_role_arn)
```

Your cluster also needs the **`eks-pod-identity-agent`** addon installed for the Pod Identity binding to take effect. Most clusters created in the last year have it; if yours doesn't:

```shell
aws eks create-addon \
  --cluster-name <eks_cluster_name> \
  --addon-name eks-pod-identity-agent
```

Then apply the rendered PV/PVC and verify it binds:

```shell
kubectl apply -f ./generated/pv-pvc.yaml
kubectl wait -n anyscale-operator --for=jsonpath='{.status.phase}'=Bound \
  pvc/anyscale-shared-fuse --timeout=120s
```

With `enable_s3_pvc = true`, the `anyscale_registration_command` output already includes `--persistent-volume-claim anyscale-shared-fuse`, so the Anyscale cloud is registered with the PVC at registration time.

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
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values values_nvdp.yaml \
  --create-namespace \
  --install
```

### Install the Anyscale Operator

Use `$CLOUD_DEPLOYMENT_ID` (from the earlier register step), `$GATEWAY_HOSTNAME` (captured after the Gateway was Programmed), and your AWS region:

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

Once the operator starts, it creates the head-node TLS Secret `anyscale-${CLOUD_DEPLOYMENT_ID//_/-}-certificate` in the `anyscale-operator` namespace. The Gateway's `https` listener was already configured to reference that name in the earlier gateway-apply step, so it auto-flips to `ResolvedRefs: True` — no reapply needed.

```shell
kubectl get secret anyscale-${CLOUD_DEPLOYMENT_ID//_/-}-certificate -n anyscale-operator
kubectl get gateway gateway -n anyscale-operator -o jsonpath='{range .status.listeners[*]}{.name}: ResolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}'
kubectl get httproutes -n anyscale-operator   # operator auto-creates routes once workloads launch
```

The `https-session` listener will remain `ResolvedRefs: False` until you launch your first Anyscale service — its Secret is provisioned lazily.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_local"></a> [local](#requirement\_local) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |
| <a name="provider_local"></a> [local](#provider\_local) | 2.9.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_anyscale_efs"></a> [anyscale\_efs](#module\_anyscale\_efs) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-efs | n/a |
| <a name="module_anyscale_iam_roles"></a> [anyscale\_iam\_roles](#module\_anyscale\_iam\_roles) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-iam | n/a |
| <a name="module_anyscale_memorydb"></a> [anyscale\_memorydb](#module\_anyscale\_memorydb) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-memorydb | n/a |
| <a name="module_anyscale_s3"></a> [anyscale\_s3](#module\_anyscale\_s3) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-s3 | n/a |
| <a name="module_aws_anyscale_securitygroup_self"></a> [aws\_anyscale\_securitygroup\_self](#module\_aws\_anyscale\_securitygroup\_self) | github.com/anyscale/terraform-aws-anyscale-cloudfoundation-modules//modules/aws-anyscale-securitygroups | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_role.s3_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.s3_csi_driver](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_security_group.memorydb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [local_file.deploy_script](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [local_file.pv_pvc_yaml](https://registry.terraform.io/providers/hashicorp/local/latest/docs/resources/file) | resource |
| [aws_subnet.existing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_customer_ingress_cidr_ranges"></a> [customer\_ingress\_cidr\_ranges](#input\_customer\_ingress\_cidr\_ranges) | The IPv4 CIDR block that is allowed to access the clusters.<br/>This provides the ability to lock down the v1 stack to just the public IPs of a corporate network.<br/>This is added to the security group and allows port 443 (https) and 22 (ssh) access.<br/>ex: `52.1.1.23/32,10.1.0.0/16'<br/>` | `string` | n/a | yes |
| <a name="input_existing_subnet_ids"></a> [existing\_subnet\_ids](#input\_existing\_subnet\_ids) | (Required) Existing Subnet IDs.<br/>The IDs of existing subnets to use. This should not be the entire ARN of the subnet, just the ID.<br/>These subnets should be in the `existing_vpc_id`.<br/>ex:<pre>existing_subnet_ids = ["subnet-1234567890", "subnet-0987654321"]</pre> | `list(string)` | n/a | yes |
| <a name="input_existing_vpc_id"></a> [existing\_vpc\_id](#input\_existing\_vpc\_id) | (Required) Existing VPC ID.<br/>The ID of an existing VPC to use. This should not be the entire ARN of the VPC, just the ID.<br/>ex:<pre>existing_vpc_id = "vpc-1234567890"</pre><pre></pre> | `string` | n/a | yes |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | The AWS region in which all resources will be created. | `string` | `"us-east-2"` | no |
| <a name="input_enable_efs"></a> [enable\_efs](#input\_enable\_efs) | (Optional) Enable the creation of an EFS instance.<br/><br/>This is optional for Anyscale deployments. EFS is used for shared storage between nodes.<br/><br/>ex:<pre>enable_efs = true</pre> | `bool` | `false` | no |
| <a name="input_enable_memorydb"></a> [enable\_memorydb](#input\_enable\_memorydb) | (Optional) Provision an AWS MemoryDB (Redis) cluster in the existing<br/>subnets via the `aws-anyscale-memorydb` cloudfoundation submodule, and<br/>emit its endpoint so it can be registered with the Anyscale cloud as<br/>`kubernetes_config.redis_endpoint` (Anyscale CLI/SDK >= 0.26.99 required).<br/><br/>When `true`, you must also set `memorydb_allowed_security_group_ids` to a<br/>list containing your EKS managed-node-group security group id(s) — that's<br/>what gates ingress to the MemoryDB SG.<br/><br/>ex:<pre>enable_memorydb = true</pre> | `bool` | `false` | no |
| <a name="input_enable_s3_pvc"></a> [enable\_s3\_pvc](#input\_enable\_s3\_pvc) | (Optional) Provision the IAM role used by the Mountpoint for Amazon S3 CSI<br/>driver pods, and render a `generated/pv-pvc.yaml` that mounts the Anyscale S3<br/>bucket as a PersistentVolumeClaim used as Anyscale shared storage.<br/><br/>Because this example brings its own EKS cluster, Terraform only creates the<br/>IAM role here. You then install the Mountpoint-S3 CSI driver and bind the<br/>role to the `s3-csi-driver-sa` service account via two `aws eks` CLI calls<br/>(see the README's "Optional: S3 PVC Plugin" section).<br/><br/>Mirrors the Azure blob PVC pattern documented at<br/>https://docs.anyscale.com/clouds/azure/pvc, wired up at registration time<br/>via `--persistent-volume-claim anyscale-shared-fuse`.<br/><br/>ex:<pre>enable_s3_pvc = true</pre> | `bool` | `false` | no |
| <a name="input_memorydb_allowed_security_group_ids"></a> [memorydb\_allowed\_security\_group\_ids](#input\_memorydb\_allowed\_security\_group\_ids) | (Optional) Security group IDs allowed ingress to the MemoryDB cluster on<br/>`memorydb_port`. Should be your EKS managed-node-group security group(s).<br/>Required when `enable_memorydb = true`.<br/><br/>ex:<pre>memorydb_allowed_security_group_ids = ["sg-0123456789abcdef0"]</pre> | `list(string)` | `[]` | no |
| <a name="input_memorydb_node_type"></a> [memorydb\_node\_type](#input\_memorydb\_node\_type) | (Optional) MemoryDB node type. Only used when `enable_memorydb = true`.<br/>See https://docs.aws.amazon.com/memorydb/latest/devguide/nodes.supportedtypes.html. | `string` | `"db.t4g.small"` | no |
| <a name="input_memorydb_num_replicas_per_shard"></a> [memorydb\_num\_replicas\_per\_shard](#input\_memorydb\_num\_replicas\_per\_shard) | (Optional) Number of replicas per MemoryDB shard. Only used when `enable_memorydb = true`. | `number` | `1` | no |
| <a name="input_memorydb_num_shards"></a> [memorydb\_num\_shards](#input\_memorydb\_num\_shards) | (Optional) Number of MemoryDB shards. Only used when `enable_memorydb = true`. | `number` | `1` | no |
| <a name="input_memorydb_port"></a> [memorydb\_port](#input\_memorydb\_port) | (Optional) Port the MemoryDB cluster listens on. Only used when `enable_memorydb = true`. | `number` | `6379` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) A map of tags to all resources that accept tags. | `map(string)` | <pre>{<br/>  "Environment": "dev",<br/>  "Example": "aws/eks-existing",<br/>  "Repo": "terraform-kubernetes-anyscale-foundation-modules",<br/>  "Test": "true"<br/>}</pre> | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The Anyscale registration command. |
| <a name="output_deploy_script_path"></a> [deploy\_script\_path](#output\_deploy\_script\_path) | Path to a rendered shell script containing every post-terraform step in order (autoscaler, AWS LBC, optional S3 CSI addon, Envoy Gateway + manifests, PVC, Anyscale Operator, verify). Open it to copy-paste steps after substituting the BYO placeholders (<eks\_cluster\_name>, <anyscale\_cloud\_name>, <node\_IAM\_role\_arn>). |
| <a name="output_helm_upgrade_command"></a> [helm\_upgrade\_command](#output\_helm\_upgrade\_command) | The helm upgrade command. |
| <a name="output_memorydb_endpoint"></a> [memorydb\_endpoint](#output\_memorydb\_endpoint) | MemoryDB cluster configuration endpoint as host:port. Only set when `enable_memorydb = true`. |
| <a name="output_s3_pvc_bucket_name"></a> [s3\_pvc\_bucket\_name](#output\_s3\_pvc\_bucket\_name) | Name of the S3 bucket exposed as a PVC via the Mountpoint-for-S3 CSI driver. Only set when `enable_s3_pvc = true`. |
| <a name="output_s3_pvc_csi_driver_role_arn"></a> [s3\_pvc\_csi\_driver\_role\_arn](#output\_s3\_pvc\_csi\_driver\_role\_arn) | IAM role ARN that the Mountpoint-for-S3 CSI driver pods should assume via EKS Pod Identity. Pass this to `aws eks create-pod-identity-association --role-arn`. Only set when `enable_s3_pvc = true`. |
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/sa-sandbox-terraform/issues
[badge-build]: https://github.com/anyscale/sa-sandbox-terraform/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-5.+-F8991D.svg?logo=terraform
<!-- [build-status]: https://github.com/anyscale/sa-sandbox-terraform/actions -->
