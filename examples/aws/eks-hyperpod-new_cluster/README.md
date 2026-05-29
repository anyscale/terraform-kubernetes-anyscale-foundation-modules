<!-- [![Build Status][badge-build]][build-status] -->
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)
[![Anyscale CLI][badge-anyscale-cli]](https://docs.anyscale.com/reference/quickstart-cli)

# Anyscale on AWS SageMaker HyperPod (EKS) — New Cluster

This example provisions everything required to run **Anyscale** on a brand-new
**SageMaker HyperPod** cluster orchestrated by **Amazon EKS**, including the
VPC, IAM, EKS control plane + system node group, HyperPod cluster, S3 storage,
and the IAM roles consumed by the Anyscale Operator and the AWS Load Balancer
Controller through EKS Pod Identity.

The Kubernetes-layer install (AWS LBC, Envoy Gateway, NVIDIA device plugin,
Anyscale Operator, Karpenter NodePools) is documented below using sample value
files shipped in this directory. These sample files encode every HyperPod-
specific workaround that diverges from the stock
[Anyscale on EKS deployment docs](https://docs.anyscale.com/clouds/aws/create-eks),
so you should not need to reverse-engineer them.

The content of this module should be used as a starting point and modified to
your own security and infrastructure requirements.

## Solution overview

The following architecture diagram illustrates SageMaker HyperPod orchestrated
by Amazon EKS, with Anyscale running on top.

<img src="assets/anyscale-aws-hyperpod-arch-diagram.png" width="1024" height="570">

See [details.md](details.md) for the longer-form architecture walkthrough.

## HyperPod-specific gotchas this module fixes

If you skip the sample value files in this directory and use the stock Anyscale
on EKS docs, you will hit the following four production blockers. Each one is
already handled below; this section is a quick reference for why the configs
look the way they do.

| # | Symptom | Root cause | Fix in this module |
|---|---------|------------|--------------------|
| 1 | Ray pods stuck `Pending`; Karpenter logs `unknown label eks.amazonaws.com/capacityType`. | Anyscale operator hardcodes `eks.amazonaws.com/capacityType=ON_DEMAND` as a pod nodeSelector. HyperPod API + Karpenter reject the `eks.amazonaws.com/` prefix (reserved domain). | `workloads.marketType.enableDefaults: false` in `sample-values_anyscale-operator.yaml`. |
| 2 | Workspaces can't be reached (SSH, browser IDE, HTTPS). `kubectl describe svc` shows NLB with zero registered targets. | LBC's default `instance` target type fails: HyperPod nodes have a non-standard `providerID`, are invisible to `ec2:DescribeInstances` in the customer account, and lack standard EC2 instance metadata. | `defaultTargetType: ip` in `sample-values_aws-lbc.yaml` + `aws-load-balancer-nlb-target-type: ip` in `sample-envoyproxy.yaml`. Subnet tags `kubernetes.io/role/elb=1` (public) and `kubernetes.io/role/internal-elb=1` (private) added by the VPC module. Use LBC **v2.11.0+** (the first release with the `sagemaker-hyperpod` compute type from [PR #3886](https://github.com/kubernetes-sigs/aws-load-balancer-controller/pull/3886)). |
| 3 | (Still open) LBC logs `cannot resolve pod ENI for pods: [...]` even with `target-type: ip`. | HyperPod enables VPC CNI prefix delegation by default; pod IPs come from `/28` ENI prefixes, but the LBC resolves IPs via the `addresses.private-ip-address` EC2 filter (secondary IPs only). Tracked upstream as [LBC #4666](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4666). | Disable prefix delegation on the VPC CNI add-on (reduces max pods per node — validate before doing this): `kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=false`. |
| 4 | GPU pods stuck `Pending` when an `accelerator_type` is requested. | HyperPod does NOT deploy GPU Feature Discovery, so `nvidia.com/gpu.product` is never set. Anyscale's accelerator-type scheduler has nothing to match against. | Use generic `GPU: <count>` requests + `nvidia.com/gpu=present:NoSchedule` taint on GPU NodePools (see `sample-karpenter-nodepool-gpu.yaml`). |
| 5 | Spot ICE causes NodeClaim cycling forever; no fallback to on-demand. | HyperPod's Karpenter provider does not honor the upstream `karpenter.sh/capacity-type` requirement for spot↔on-demand fallback. The HyperPod-native fallback is at the `HyperpodNodeClass` level: list both spot and on-demand `InstanceGroups` in the same NodeClass and Karpenter prefers spot using EC2 Spot Placement Scores. | `sample-hyperpod-nodeclass.yaml` ships with on-demand-only InstanceGroups; uncomment the spot lines once you've validated fallback in your account. |

Items 1, 2, and 3 are the immediate **production blockers**. Items 4 and 5
are workarounds we are tracking jointly with the HyperPod team.

## Getting started

### Prerequisites

1. **AWS Account Setup**
    1. An **AWS account** with billing enabled.
    2. [**AWS IAM**](https://aws.amazon.com/iam/) permissions for SageMaker HyperPod, EKS, VPC, IAM, and S3.
    3. [**AWS Credentials**](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) configured locally (env vars or `~/.aws/credentials`).
    4. [**AWS CLI**](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed locally.
2. **Tools**
    1. **Git** — `brew install git` ([other options](https://git-scm.com/install/mac)).
    2. **Terraform** ≥ 1.0 — `brew tap hashicorp/tap && brew install terraform` ([other options](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli)).
    3. **kubectl** — `brew install kubectl` ([other options](https://kubernetes.io/docs/tasks/tools/)).
    4. **helm** — `brew install helm` ([other options](https://helm.sh/docs/intro/install/)).
3. **Anyscale Account Setup**
    1. **Anyscale CLI** — `pip install -U anyscale`.
    2. An **Anyscale organization**.
    3. `anyscale login` and approve the browser prompt.

### Creating the Anyscale + HyperPod infrastructure

Steps for deploying via Terraform:

1. Review `variables.tf` and customize `terraform.tfvars` to match your
   environment. At minimum, update:

    ```tf
    anyscale_new_cloud_name = "my-new-cloud-name"
    kubernetes_version      = "1.31"
    eks_cluster_name        = "my-eks-cluster"
    hyperpod_cluster_name   = "my-hyperpod-cluster"
    resource_name_prefix    = "hyperpod-prefix-name"
    aws_region              = "us-west-2"
    availability_zone_id    = "usw2-az2"
    ```

2. (Optional but recommended) Stage the HyperPod dependencies Helm chart locally
   so Terraform can install it as part of the apply:

    ```shell
    git clone https://github.com/aws/sagemaker-hyperpod-cli.git /tmp/helm-repo
    ```

3. Apply the Terraform.

    > The defaults create 2 NAT Gateways (and therefore consume 2 EIPs).
    > Bump your Elastic IP quota first if your account is at the default limit.

    ```shell
    terraform init
    terraform plan
    terraform apply
    ```

4. Read the `z_next_steps` output. Terraform renders a step-by-step set of
   commands (kubeconfig, LBC install, Envoy Gateway install, Anyscale register,
   operator install, NodePool apply) pre-populated with your cluster name,
   region, VPC id, S3 bucket arn, and IAM role arn. The rest of this README
   walks through those same steps with extra context.

### Install the Kubernetes prerequisites

The Anyscale Operator on HyperPod requires the following components in this
order:

1. [AWS Load Balancer Controller](https://github.com/kubernetes-sigs/aws-load-balancer-controller) (≥ **v2.11.0**, **IP target mode**).
2. [Envoy Gateway](https://gateway.envoyproxy.io) v1.7.0 (replaces ingress-nginx — recommended ingress per the [Anyscale docs](https://docs.anyscale.com/clouds/aws/create-eks)).
3. (Optional, GPU only) [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin).

Karpenter's control plane is **managed by SageMaker HyperPod itself** when
`NodeProvisioningMode=Continuous` (set by this Terraform stack) — you do not
install Karpenter via Helm. The `hyperpod-dependencies` Helm release installed
by Terraform ships the HyperPod health-monitoring agent, the training operator,
and (on inference-enabled clusters) the LBC CRDs. You still need to create the
`HyperpodNodeClass` + `NodePool` custom resources yourself (samples provided
in step 7 below). Cluster Autoscaler is **not** used on HyperPod.

> Make sure you are [authenticated to the EKS cluster](https://docs.aws.amazon.com/eks/latest/userguide/create-kubeconfig.html) before continuing.
>
> ```shell
> aws eks update-kubeconfig --region <aws_region> --name <eks_cluster_name>
> kubectl get nodes -L node.kubernetes.io/instance-type \
>   -L sagemaker.amazonaws.com/node-health-status \
>   -L sagemaker.amazonaws.com/deep-health-check-status
> ```

#### 1. Install the AWS Load Balancer Controller (HyperPod-compatible)

A sample values file, `sample-values_aws-lbc.yaml`, is the single source of
truth for the LBC config (`defaultTargetType: ip`, `replicaCount`, tolerations).
The three dynamic values (`clusterName`, `region`, `vpcId`) are passed with
`--set` below so they override the file's placeholders automatically — you do
**not** need to hand-edit the file. (The `z_next_steps` Terraform output renders
this exact command pre-filled with your values.)

The Terraform stack has already:

- Created the LBC IAM role with the upstream
  [v2.11.0 IAM policy](https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json).
- Bound that role to the `kube-system/aws-load-balancer-controller` service
  account via an EKS Pod Identity association (no OIDC bootstrap required).
- Tagged the public subnets with `kubernetes.io/role/elb=1` and the private
  subnets with `kubernetes.io/role/internal-elb=1` (subnet auto-discovery does
  not fall back to instance metadata on HyperPod).

```shell
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version 1.13.2 \
  --namespace kube-system \
  --values sample-values_aws-lbc.yaml \
  --set clusterName=<eks_cluster_name> \
  --set region=<aws_region> \
  --set vpcId=<vpc_id> \
  --install
```

> **One-time CRD fix.** If the `hyperpod-dependencies` chart shipped LBC CRDs
> earlier in the apply (some HyperPod inference add-on revisions do), `helm`
> will refuse to adopt them. Run the snippet from step 3 of the `z_next_steps`
> output before re-running the `helm upgrade` above.

> **Known open issue — VPC CNI prefix delegation.** Even with `target-type: ip`,
> the LBC currently cannot resolve pod ENIs on HyperPod when VPC CNI prefix
> delegation is enabled (HyperPod's default). Controller logs show
> `cannot resolve pod ENI for pods: [...]`. Tracked upstream as
> [LBC #4666](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4666).
> Workaround (validate first — disabling prefix delegation reduces the max
> pods per node):
>
> ```shell
> kubectl set env daemonset aws-node -n kube-system ENABLE_PREFIX_DELEGATION=false
> kubectl rollout restart daemonset aws-node -n kube-system
> ```

#### 2. Install Envoy Gateway and the HyperPod-compatible EnvoyProxy

```shell
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=120s
```

Apply the HyperPod-compatible `EnvoyProxy` (IP target mode) and the `eg`
`GatewayClass`:

```shell
kubectl apply -f sample-envoyproxy.yaml
kubectl apply -f sample-gatewayclass.yaml
```

The only difference between `sample-envoyproxy.yaml` and the EnvoyProxy in the
upstream Anyscale docs is:

```yaml
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip   # was: instance
```

Without this single annotation, *every* HyperPod node fails to register with
the NLB and all workspace traffic (SSH, browser IDE, HTTPS) breaks.

#### 3. (Optional) Install the NVIDIA device plugin

Required only if you will run GPU workloads. A sample values file,
`sample-values_nvdp.yaml`, is provided.

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values sample-values_nvdp.yaml \
  --create-namespace \
  --install
```

The values file documents the GPU Feature Discovery caveat. **Short version:**
do not request `accelerator_type=*` in your Anyscale compute templates on
HyperPod — request `GPU: <count>` instead. Karpenter will route the pod to a
GPU NodePool via the `nvidia.com/gpu` extended resource.

### Register the Anyscale Cloud

Ensure you are logged in with `anyscale login`, then run the registration
command rendered in the `z_next_steps` Terraform output. It looks like:

```shell
anyscale cloud register \
  --name <anyscale-cloud-name> \
  --region <aws_region> \
  --provider aws \
  --compute-stack k8s \
  --kubernetes-zones <zone-a>,<zone-b>,<zone-c> \
  --s3-bucket-id <s3_bucket_arn> \
  --anyscale-operator-iam-identity <sagemaker_iam_role_arn>
```

Capture the `cldrsrc_*` value printed at the end of the output — every step
below requires it.

### Create the Anyscale Gateway

The Anyscale operator targets a Kubernetes Gateway by name. Create the
namespace, edit `sample-gateway.yaml` to replace `<cloud-resource-id>` with
your `cldrsrc_*` id, and apply.

```shell
kubectl create namespace anyscale-operator || true
# edit sample-gateway.yaml: replace <cloud-resource-id>
kubectl apply -f sample-gateway.yaml

kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}'
```

Record the printed address — that goes into `networking.gateway.hostname` (or
`networking.gateway.ip`) in the operator values file.

### Install the Anyscale Operator

Edit `sample-values_anyscale-operator.yaml` and fill in the three placeholders
(`<cloud-resource-id>`, `<aws_region>`, `<gateway-address>`). Keep
`workloads.marketType.enableDefaults: false` — this is what makes Ray pods
schedulable on HyperPod. Then:

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update anyscale
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  --values sample-values_anyscale-operator.yaml \
  --wait \
  --install
```

Watch the rollout:

```shell
kubectl get deployments anyscale-operator -n anyscale-operator -w
```

### Apply the HyperPod-compatible HyperpodNodeClass + Karpenter NodePools

HyperPod manages the Karpenter control plane for you, but it does NOT ship a
default `HyperpodNodeClass` or `NodePool`. You must create both.

1. **`HyperpodNodeClass`** (`apiVersion: karpenter.sagemaker.amazonaws.com/v1`,
   `kind: HyperpodNodeClass`) maps Karpenter capacity requests to your
   pre-created HyperPod `InstanceGroups`. Find your InstanceGroup names with:

    ```shell
    aws sagemaker describe-cluster --cluster-name <hyperpod_cluster_name> \
      --query 'InstanceGroups[].InstanceGroupName'
    ```

    Edit `sample-hyperpod-nodeclass.yaml` to list those InstanceGroup names,
    then:

    ```shell
    kubectl apply -f sample-hyperpod-nodeclass.yaml
    ```

    > **Spot/on-demand fallback.** HyperPod's Karpenter provider does NOT
    > honor the upstream `karpenter.sh/capacity-type` NodePool requirement.
    > The HyperPod-native fallback mechanism is to list BOTH spot and
    > on-demand InstanceGroups in the same `HyperpodNodeClass` — Karpenter
    > then prefers spot and falls back to on-demand based on EC2 Spot
    > Placement Scores. The sample ships with only on-demand
    > InstanceGroups; uncomment the spot lines once you've validated the
    > fallback works in your account.

2. **`NodePool`** custom resources reference the `HyperpodNodeClass` above and
   set taints/labels for workload isolation. Two reference NodePool files are
   provided:

    - `sample-karpenter-nodepool-cpu.yaml` — CPU pool with
      `node.anyscale.com/capacity-type=ON_DEMAND:NoSchedule`.
    - `sample-karpenter-nodepool-gpu.yaml` — GPU pool with
      `nvidia.com/gpu=present:NoSchedule`.

    Both reference `name: hyperpod-default` — match the `metadata.name` of
    your `HyperpodNodeClass` from step 1.

    ```shell
    kubectl apply -f sample-karpenter-nodepool-cpu.yaml
    kubectl apply -f sample-karpenter-nodepool-gpu.yaml
    ```

### Verify the Anyscale cloud

```shell
anyscale cloud verify --name <anyscale-cloud-name>
anyscale job submit --cloud <anyscale-cloud-name> \
  --working-dir https://github.com/anyscale/docs_examples/archive/refs/heads/main.zip \
  -- python hello_world.py
```

## Production hardening (required before running production workloads)

This example gets you a **functional** Anyscale-on-HyperPod cloud. Before you put
production traffic on it, address the following two items — neither is configured
out of the box.

### 1. Enable head node fault tolerance

Anyscale recommends head node fault tolerance for **all** production services. It
uses a Redis-compatible external storage cluster so services keep serving from
worker-node replicas while the head node recovers. Because this cloud is created
with `anyscale cloud register` (not `anyscale cloud setup`), you provision the
Redis cluster yourself and reference it in the cloud resource.

This stack ships an optional **`memorydb` module** that provisions a
HyperPod-compatible Amazon MemoryDB cluster (single shard, 1 replica, TLS) in the
EKS module's multi-AZ private subnets, locked down to the shared cluster security
group. It satisfies all of Anyscale's requirements for the Kubernetes data plane:

- Reachable from the network that runs your Anyscale workloads (same VPC + SG).
- **Single shard** (multi-shard is not supported), **1 replica**, **~2 GiB**.
- **TLS** enabled (AWS-managed public CA — no `certificate_path` needed).

Enable it (off by default because MemoryDB has ongoing cost):

```tf
# terraform.tfvars
create_memorydb_module = true
```

After `terraform apply`, read the `redis_endpoint` output (a `rediss://…:6379`
address) and set it on the cloud resource:

```shell
terraform output redis_endpoint
anyscale cloud get --name <anyscale-cloud-name> --output cloud-resources.yaml
# add the endpoint under kubernetes_config (see below)
anyscale cloud update --name <anyscale-cloud-name> --resources-file cloud-resources.yaml
```

Example `kubernetes_config` block:

```yaml
kubernetes_config:
  anyscale_operator_iam_identity: <sagemaker_iam_role_arn>
  zones:
    - us-west-2a
    - us-west-2b
  redis_endpoint: rediss://<prefix>-memorydb.xxxxxx.clustercfg.memorydb.us-west-2.amazonaws.com:6379
```

Configure a CloudWatch alarm on the cluster's `DatabaseMemoryUsagePercentage`
metric (trigger at > 80%). See the Anyscale docs on
[head node fault tolerance](https://docs.anyscale.com/configuration/head-node-fault-tolerance)
for per-service overrides and the full requirements.

> The MemoryDB module uses the built-in `open-access` ACL (no auth); network
> isolation comes from the dedicated security group. To require auth, swap in an
> `aws_memorydb_acl` + `aws_memorydb_user` in `modules/memorydb` and pass the
> credentials to Anyscale via the `redis_endpoint`. If you prefer an in-cluster
> Redis instead (single shard, ≥1 replica, reachable at `*.svc.cluster.local`),
> set `create_memorydb_module = false` and point `redis_endpoint` at it.

### 2. EKS system node group sizing

The `eks_cluster` module's system node group hosts CoreDNS, the AWS Load Balancer
Controller (`replicaCount: 2`), Envoy Gateway, and the Anyscale operator (Ray /
application pods run on HyperPod instance groups via Karpenter, not here). It
**defaults to HA**: `m5.large` × `desired/min = 2`, `max = 3` — enough pod density
to also tolerate the prefix-delegation workaround above. Override via the
`system_node_*` variables on the `eks_cluster` module if needed:

```tf
system_node_instance_types = ["m5.large"]
system_node_desired_size   = 2
system_node_min_size       = 2
system_node_max_size       = 3
```

> The node group runs in a **single AZ** (one `private_node` subnet), so it
> survives node failure but not a full AZ outage. For AZ-failure resilience, add
> a second `private_node` subnet in another AZ and include it in the node group's
> `subnet_ids`.

### Tear down

```shell
helm uninstall anyscale-operator -n anyscale-operator
kubectl delete -f sample-gateway.yaml || true
helm uninstall eg -n envoy-gateway-system
helm uninstall aws-load-balancer-controller -n kube-system
anyscale cloud delete --name <anyscale-cloud-name>
terraform destroy
```

## Long-term roadmap (tracking with the HyperPod team)

| Workaround | Owner | Long-term fix |
|------------|-------|---------------|
| `workloads.marketType.enableDefaults: false` | Anyscale + HyperPod | Make the capacity-type label configurable in the Anyscale operator so it can be set to a HyperPod-supported domain (e.g. `karpenter.sh/capacity-type`). |
| `nvidia.com/gpu=present:NoSchedule` taint instead of accelerator-type | HyperPod | Bundle GPU Feature Discovery so `nvidia.com/gpu.product` lands on nodes and accelerator-type scheduling works. |
| LBC IP target mode + explicit `region`/`vpcId` | Anyscale | Document this as the EKS variant or change the operator default. |
| Spot/on-demand fallback via mixed-`InstanceGroups` `HyperpodNodeClass` instead of `karpenter.sh/capacity-type` | HyperPod | Make the upstream `karpenter.sh/capacity-type` NodePool requirement work, OR document the InstanceGroup-list strategy clearly in the HyperPod Karpenter docs. |
| Disable VPC CNI prefix delegation | LBC project + HyperPod | Ship the LBC fix proposed in [#4667](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4667) that resolves pod ENIs through ENI `Ipv4Prefixes` so IP target mode works without disabling prefix delegation. |

## Companion repositories

- Anyscale Terraform module (this repo): https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules
- AWS HyperPod-on-EKS Terraform module: https://github.com/awslabs/awsome-distributed-training/tree/main/1.architectures/7.sagemaker-hyperpod-eks/terraform-modules
- Anyscale on EKS docs: https://docs.anyscale.com/clouds/aws/create-eks

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.10.0 |
| <a name="requirement_awscc"></a> [awscc](#requirement\_awscc) | >= 1.53.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 3.0.0 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.0.0 |
| <a name="requirement_null"></a> [null](#requirement\_null) | >= 3.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_aws_lbc_iam_role"></a> [aws\_lbc\_iam\_role](#module\_aws\_lbc\_iam\_role) | ./modules/aws_lbc_iam_role | n/a |
| <a name="module_eks_cluster"></a> [eks\_cluster](#module\_eks\_cluster) | ./modules/eks_cluster | n/a |
| <a name="module_helm_chart"></a> [helm\_chart](#module\_helm\_chart) | ./modules/helm_chart | n/a |
| <a name="module_hyperpod_cluster"></a> [hyperpod\_cluster](#module\_hyperpod\_cluster) | ./modules/hyperpod_cluster | n/a |
| <a name="module_lifecycle_script"></a> [lifecycle\_script](#module\_lifecycle\_script) | ./modules/lifecycle_script | n/a |
| <a name="module_memorydb"></a> [memorydb](#module\_memorydb) | ./modules/memorydb | n/a |
| <a name="module_private_subnet"></a> [private\_subnet](#module\_private\_subnet) | ./modules/private_subnet | n/a |
| <a name="module_s3_bucket"></a> [s3\_bucket](#module\_s3\_bucket) | ./modules/s3_bucket | n/a |
| <a name="module_s3_endpoint"></a> [s3\_endpoint](#module\_s3\_endpoint) | ./modules/s3_endpoint | n/a |
| <a name="module_sagemaker_iam_role"></a> [sagemaker\_iam\_role](#module\_sagemaker_iam_role) | ./modules/sagemaker_iam_role | n/a |
| <a name="module_security_group"></a> [security\_group](#module\_security\_group) | ./modules/security_group | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | ./modules/vpc | n/a |

## Key Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_anyscale_new_cloud_name"></a> [anyscale\_new\_cloud\_name](#input\_anyscale\_new\_cloud\_name) | Name of the new Anyscale cloud. | `string` | n/a | yes |
| <a name="input_anyscale_operator_namespace"></a> [anyscale\_operator\_namespace](#input\_anyscale\_operator\_namespace) | Kubernetes namespace where the Anyscale Operator runs. | `string` | `"anyscale-operator"` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region. | `string` | `"us-west-2"` | no |
| <a name="input_create_aws_lbc_iam_role_module"></a> [create\_aws\_lbc\_iam\_role\_module](#input\_create\_aws\_lbc\_iam\_role\_module) | Create the IAM role consumed by the AWS Load Balancer Controller via EKS Pod Identity. **Required on HyperPod (IP target mode).** | `bool` | `true` | no |
| <a name="input_create_memorydb_module"></a> [create\_memorydb\_module](#input\_create\_memorydb\_module) | Create a MemoryDB cluster for Anyscale head node fault tolerance. **Set `true` for production** (incurs ongoing cost). | `bool` | `false` | no |
| <a name="input_memorydb_node_type"></a> [memorydb\_node\_type](#input\_memorydb\_node\_type) | MemoryDB node type for head node fault tolerance. | `string` | `"db.t4g.small"` | no |
| <a name="input_eks_cluster_name"></a> [eks\_cluster\_name](#input\_eks\_cluster\_name) | EKS cluster name. | `string` | `"sagemaker-hyperpod-eks-cluster"` | no |
| <a name="input_hyperpod_cluster_name"></a> [hyperpod\_cluster\_name](#input\_hyperpod\_cluster\_name) | HyperPod cluster name. | `string` | `"ml-cluster"` | no |
| <a name="input_kubernetes_version"></a> [kubernetes\_version](#input\_kubernetes\_version) | Kubernetes version. | `string` | `"1.31"` | no |
| <a name="input_resource_name_prefix"></a> [resource\_name\_prefix](#input\_resource\_name\_prefix) | Prefix for AWS resource names. | `string` | `"sagemaker-hyperpod-eks"` | no |

See `variables.tf` for the full input list (subnet CIDRs, instance group definitions, module toggles, etc.).

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_z_next_steps"></a> [z\_next\_steps](#output\_z\_next\_steps) | Rendered step-by-step commands (kubeconfig, LBC install, Envoy Gateway, Anyscale register, operator install, NodePool apply). |
| <a name="output_aws_region"></a> [aws\_region](#output\_aws\_region) | AWS region. |
| <a name="output_eks_cluster_name"></a> [eks\_cluster\_name](#output\_eks\_cluster\_name) | EKS cluster name. |
| <a name="output_hyperpod_cluster_name"></a> [hyperpod\_cluster\_name](#output\_hyperpod\_cluster\_name) | HyperPod cluster name. |
| <a name="output_sagemaker_iam_role_arn"></a> [sagemaker\_iam\_role\_arn](#output\_sagemaker\_iam\_role\_arn) | IAM role consumed by `--anyscale-operator-iam-identity`. |
| <a name="output_aws_lbc_iam_role_arn"></a> [aws\_lbc\_iam\_role\_arn](#output\_aws\_lbc\_iam\_role\_arn) | IAM role used by the AWS LBC via Pod Identity. |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | S3 bucket consumed by `--s3-bucket-id`. |
| <a name="output_redis_endpoint"></a> [redis\_endpoint](#output\_redis\_endpoint) | TLS Redis endpoint for head node fault tolerance (`null` unless `create_memorydb_module = true`). |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | VPC id (used in LBC `--set vpcId=`). |

See `outputs.tf` for the full output list.
<!-- END_TF_DOCS -->

<!-- References -->
[Terraform]: https://www.terraform.io
[Issues]: https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules/issues
[badge-build]: https://github.com/anyscale/terraform-kubernetes-anyscale-foundation-modules/workflows/CI/CD%20Pipeline/badge.svg
[badge-terraform]: https://img.shields.io/badge/terraform-1.x%20-623CE4.svg?logo=terraform
[badge-tf-aws]: https://img.shields.io/badge/AWS-6.+-F8991D.svg?logo=terraform
[badge-anyscale-cli]: https://img.shields.io/badge/Anyscale_CLI-0.0.0%20-blue.svg
