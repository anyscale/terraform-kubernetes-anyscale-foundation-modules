[![Build Status][badge-build]][build-status]
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)
[![Anyscale CLI][badge-anyscale-cli]](https://docs.anyscale.com/reference/quickstart-cli)

# Anyscale AWS SageMaker HyperPod EKS Example - New Cluster
This example creates the resources to setup a new SageMaker HyperPod cluster orchestrated on AWS EKS and creates the resources to run Anyscale on AWS EKS.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Use Amazon SageMaker HyperPod and Anyscale for next-generation distributed computing
_by Sindhura Palakodety, Anoop Saha, Dominic Catalano, Florian Gauter, Alex Iankoulski, and Mark Vinciguerra on 09 OCT 2025 in [Advanced (300)](https://aws.amazon.com/blogs/machine-learning/category/learning-levels/advanced-300/), [Amazon Machine Learning](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/amazon-machine-learning/), [Amazon SageMaker Autopilot](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/sagemaker/amazon-sagemaker-autopilot/), [Amazon SageMaker HyperPod](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/sagemaker/amazon-sagemaker-hyperpod/), [Artificial Intelligence](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/), [Expert (400)](), [Generative AI](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/generative-ai/), [PyTorch on AWS](https://aws.amazon.com/blogs/machine-learning/category/artificial-intelligence/pytorch-on-aws/), [Technical How-to Permalink  Comments  Share](https://aws.amazon.com/blogs/machine-learning/category/post-types/technical-how-to/)_

_This post was written with Dominic Catalano from Anyscale._

Organizations building and deploying large-scale AI models often face critical infrastructure challenges that can directly impact their bottom line: unstable training clusters that fail mid-job, inefficient resource utilization driving up costs, and complex distributed computing frameworks requiring specialized expertise. These factors can lead to unused GPU hours, delayed projects, and frustrated data science teams. This post demonstrates how you can address these challenges by providing a resilient, efficient infrastructure for distributed AI workloads.

[Amazon SageMaker HyperPod](https://aws.amazon.com/sagemaker/ai/hyperpod/) is a purpose-built persistent generative AI infrastructure optimized for machine learning (ML) workloads. It provides robust infrastructure for large-scale ML workloads with high-performance hardware, so organizations can build heterogeneous clusters using tens to thousands of GPU accelerators. With nodes optimally co-located on a single spine, SageMaker HyperPod reduces networking overhead for distributed training. It maintains operational stability through continuous monitoring of node health, automatically swapping faulty nodes with healthy ones and resuming training from the most recently saved checkpoint, all of which can help save up to 40% of training time. For advanced ML users, SageMaker HyperPod allows SSH access to the nodes in the cluster, enabling deep infrastructure control, and allows access to SageMaker tooling, including Amazon SageMaker Studio, MLflow, and SageMaker distributed training libraries, along with support for various open-source training libraries and frameworks. SageMaker Flexible Training Plans complement this by enabling GPU capacity reservation up to 8 weeks in advance for durations up to 6 months.

The [Anyscale platform](https://www.anyscale.com/product/platform) integrates seamlessly with SageMaker HyperPod when using [Amazon Elastic Kubernetes Service](https://aws.amazon.com/eks/) (Amazon EKS) as the cluster orchestrator. [Ray](https://www.ray.io/) is the leading AI compute engine, offering Python-based distributed computing capabilities to address AI workloads ranging from multimodal AI, data processing, model training, and model serving. Anyscale unlocks the power of Ray with comprehensive tooling for developer agility, critical fault tolerance, and an optimized version called [Anyscale Runtime](https://www.anyscale.com/blog/announcing-anyscale-runtime-powered-by-ray), designed to deliver leading cost-efficiency. Through a unified control plane, organizations benefit from simplified management of complex distributed AI use cases with fine-grained control across hardware.

The combined solution provides extensive monitoring through [SageMaker HyperPod real-time dashboards](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-eks-cluster-observability.html) tracking node health, GPU utilization, and network traffic. Integration with Amazon CloudWatch Container Insights, [Amazon Managed Service for Prometheus](https://aws.amazon.com/prometheus/), and [Amazon Managed Grafana](https://aws.amazon.com/prometheus/) delivers deep visibility into cluster performance, complemented by [Anyscale’s monitoring framework](https://docs.anyscale.com/monitoring/metrics), which provides built-in metrics for monitoring Ray clusters and the workloads that run on them.

This post demonstrates how to integrate the Anyscale platform with SageMaker HyperPod. This combination can deliver tangible business outcomes: reduced time-to-market for AI initiatives, lower total cost of ownership through optimized resource utilization, and increased data science productivity by minimizing infrastructure management overhead. It is ideal for Amazon EKS and Kubernetes-focused organizations, teams with large-scale distributed training needs, and those invested in the [Ray ecosystem](https://www.anyscale.com/blog/understanding-the-ray-ecosystem-and-community) or SageMaker.


## Solution overview
The following architecture diagram illustrates SageMaker HyperPod with Amazon EKS orchestration and Anyscale.

<img src="assets/anyscale-aws-hyperpod-arch-diagram.png" width="1024" height="570">

The sequence of events in this architecture is as follows:

1. A user submits a job to the Anyscale Control Plane, which is the main user-facing endpoint.
2. The Anyscale Control Plane communicates this job to the Anyscale Operator within the SageMaker HyperPod cluster in the SageMaker HyperPod virtual private cloud (VPC).
3. The Anyscale Operator, upon receiving the job, initiates the process of creating the necessary pods by reaching out to the EKS control plane.
4. The EKS control plane orchestrates creation of a Ray head pod and worker pods. These pods represent a Ray cluster, running on SageMaker HyperPod with Amazon EKS.
5. The Anyscale Operator submits the job through the head pod, which serves as the primary coordinator for the distributed workload.
6. The head pod distributes the workload across multiple worker pods, as shown in the hierarchical structure in the SageMaker HyperPod EKS cluster.
7. Worker pods execute their assigned tasks, potentially accessing required data from the storage services – such as [Amazon Simple Storage Service](https://aws.amazon.com/s3/) (Amazon S3), [Amazon Elastic File System](https://aws.amazon.com/efs/) (Amazon EFS), or [Amazon FSx for Lustre](https://aws.amazon.com/fsx/lustre/) – in the user VPC.
8. Throughout the job execution, metrics and logs are published to [Amazon CloudWatch](https://aws.amazon.com/cloudwatch/) and Amazon Managed Service for Prometheus or Amazon Managed Grafana for observability.
9. When the Ray job is complete, the job artifacts (final model weights, inference results, and so on) are saved to the designated storage service.
10. Job results (status, metrics, logs) are sent through the Anyscale Operator back to the Anyscale Control Plane.

This flow shows distribution and execution of user-submitted jobs across the available computing resources, while maintaining monitoring and data accessibility throughout the process.

## What this Terraform module provisions

In support of the flow above, this Terraform stack creates and wires up the
following resources end-to-end so that the only post-`terraform apply` work is
a handful of `helm`/`kubectl` commands (all rendered for you in the
`z_next_steps` output):

### AWS infrastructure

- **VPC** (`modules/vpc`) with two public subnets, two NAT Gateways, and the
  subnet tags required by the AWS Load Balancer Controller's auto-discovery:
  `kubernetes.io/role/elb=1` on public subnets,
  `kubernetes.io/cluster/<eks_cluster_name>=shared` on every subnet.
- **HyperPod private subnet** (`modules/private_subnet`) — a dedicated subnet
  in a specific AZ for HyperPod cross-account ENIs, tagged
  `kubernetes.io/role/internal-elb=1`.
- **Security group** (`modules/security_group`) — single SG shared between EKS
  nodes and HyperPod instance groups, with intra-SG + Lustre + egress rules.
- **S3 bucket** (`modules/s3_bucket`) + **S3 Gateway endpoint**
  (`modules/s3_endpoint`) for lifecycle scripts and Anyscale workload data.
- **EKS cluster** (`modules/eks_cluster`) — control plane plus a small managed
  node group sized for system pods (CoreDNS, AWS LBC, Envoy Gateway, Anyscale
  operator). Cluster log types enabled: api, audit, authenticator,
  controllerManager, scheduler.
- **EKS add-ons** — `vpc-cni`, `kube-proxy`, `coredns`,
  `eks-pod-identity-agent` (used by the LBC and the Anyscale operator).
- **SageMaker IAM role** (`modules/sagemaker_iam_role`) — execution role for
  the HyperPod cluster *and* the role assumed by the
  `anyscale-operator/anyscale-operator` service account via Pod Identity.
- **AWS LBC IAM role** (`modules/aws_lbc_iam_role`) — dedicated role assumed
  by the `kube-system/aws-load-balancer-controller` SA via Pod Identity, with
  the upstream LBC v2.11.0 IAM policy.
- **HyperPod cluster** (`modules/hyperpod_cluster`) — created with
  `awscc_sagemaker_cluster`, wired to the EKS cluster as the orchestrator,
  using the dedicated private subnet + shared security group.
- **Lifecycle script** (`modules/lifecycle_script`) — `on_create.sh` uploaded
  to the S3 bucket.
- **HyperPod dependencies Helm release** (`modules/helm_chart`) — installs
  the HyperPod health-monitoring agent, training operator, and (on
  inference-enabled clusters) the AWS LBC CRDs into `kube-system`. The
  Karpenter control plane itself is **managed by SageMaker HyperPod**
  whenever `NodeProvisioningMode=Continuous` (set here) — you do not install
  Karpenter via Helm. You DO still need to install the
  `HyperpodNodeClass` + `NodePool` custom resources after the apply.

### Kubernetes layer (installed via `helm`/`kubectl` after `terraform apply`)

| Component | Why | Sample file |
|-----------|-----|-------------|
| AWS Load Balancer Controller (≥ v2.11) | Provides NLB/ALB for the Envoy Gateway. Must run in **IP target mode** on HyperPod. v2.11 is the first release with the dedicated `sagemaker-hyperpod` pod-compute-type code path ([PR #3886](https://github.com/kubernetes-sigs/aws-load-balancer-controller/pull/3886)). | `sample-values_aws-lbc.yaml` |
| Envoy Gateway v1.7.0 | Recommended Anyscale ingress (replaces ingress-nginx). | `sample-envoyproxy.yaml`, `sample-gatewayclass.yaml`, `sample-gateway.yaml` |
| NVIDIA device plugin (optional) | Surfaces `nvidia.com/gpu` extended resource. GPU Feature Discovery is **not** bundled on HyperPod, so accelerator-type scheduling is unavailable — use generic `GPU: <n>` requests instead. | `sample-values_nvdp.yaml` |
| Anyscale Operator | Bridges the Anyscale control plane to the cluster. Must run with `workloads.marketType.enableDefaults: false` on HyperPod. | `sample-values_anyscale-operator.yaml` |
| `HyperpodNodeClass` + Karpenter NodePools (CPU + GPU) | Map Karpenter capacity requests to HyperPod InstanceGroups. GPU NodePool uses `nvidia.com/gpu=present:NoSchedule`, not the Anyscale accelerator-type taint. Spot-on-demand fallback is configured at the `HyperpodNodeClass` level (mixed InstanceGroups), not via Karpenter's `capacity-type` requirement. | `sample-hyperpod-nodeclass.yaml`, `sample-karpenter-nodepool-cpu.yaml`, `sample-karpenter-nodepool-gpu.yaml` |

See [README.md](README.md) for the step-by-step install commands and
[README.md#hyperpod-specific-gotchas-this-module-fixes](README.md) for the rationale behind each
divergence from the stock [Anyscale on EKS docs](https://docs.anyscale.com/clouds/aws/create-eks).