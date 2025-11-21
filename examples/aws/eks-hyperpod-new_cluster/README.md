<!-- [![Build Status][badge-build]][build-status] -->
[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale AWS SageMaker HyperPod EKS Example - New Cluster
This example creates the resources to setup a new SageMaker HyperPod cluster orchestrated on AWS EKS and creates the resources to run Anyscale on AWS EKS.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Use Amazon SageMaker HyperPod and Anyscale for next-generation distributed computing
_by Sindhura Palakodety, Anoop Saha, Dominic Catalano, Florian Gauter, Alex Iankoulski, and Mark Vinciguerra on 09 OCT 2025 in Advanced (300), Amazon Machine Learning, Amazon SageMaker Autopilot, Amazon SageMaker HyperPod, Artificial Intelligence, Expert (400), Generative AI, PyTorch on AWS, Technical How-to Permalink  Comments  Share_

_This post was written with Dominic Catalano from Anyscale._

Organizations building and deploying large-scale AI models often face critical infrastructure challenges that can directly impact their bottom line: unstable training clusters that fail mid-job, inefficient resource utilization driving up costs, and complex distributed computing frameworks requiring specialized expertise. These factors can lead to unused GPU hours, delayed projects, and frustrated data science teams. This post demonstrates how you can address these challenges by providing a resilient, efficient infrastructure for distributed AI workloads.

Amazon SageMaker HyperPod is a purpose-built persistent generative AI infrastructure optimized for machine learning (ML) workloads. It provides robust infrastructure for large-scale ML workloads with high-performance hardware, so organizations can build heterogeneous clusters using tens to thousands of GPU accelerators. With nodes optimally co-located on a single spine, SageMaker HyperPod reduces networking overhead for distributed training. It maintains operational stability through continuous monitoring of node health, automatically swapping faulty nodes with healthy ones and resuming training from the most recently saved checkpoint, all of which can help save up to 40% of training time. For advanced ML users, SageMaker HyperPod allows SSH access to the nodes in the cluster, enabling deep infrastructure control, and allows access to SageMaker tooling, including Amazon SageMaker Studio, MLflow, and SageMaker distributed training libraries, along with support for various open-source training libraries and frameworks. SageMaker Flexible Training Plans complement this by enabling GPU capacity reservation up to 8 weeks in advance for durations up to 6 months.

The Anyscale platform integrates seamlessly with SageMaker HyperPod when using Amazon Elastic Kubernetes Service (Amazon EKS) as the cluster orchestrator. Ray is the leading AI compute engine, offering Python-based distributed computing capabilities to address AI workloads ranging from multimodal AI, data processing, model training, and model serving. Anyscale unlocks the power of Ray with comprehensive tooling for developer agility, critical fault tolerance, and an optimized version called RayTurbo, designed to deliver leading cost-efficiency. Through a unified control plane, organizations benefit from simplified management of complex distributed AI use cases with fine-grained control across hardware.

The combined solution provides extensive monitoring through SageMaker HyperPod real-time dashboards tracking node health, GPU utilization, and network traffic. Integration with Amazon CloudWatch Container Insights, Amazon Managed Service for Prometheus, and Amazon Managed Grafana delivers deep visibility into cluster performance, complemented by Anyscale’s monitoring framework, which provides built-in metrics for monitoring Ray clusters and the workloads that run on them.

This post demonstrates how to integrate the Anyscale platform with SageMaker HyperPod. This combination can deliver tangible business outcomes: reduced time-to-market for AI initiatives, lower total cost of ownership through optimized resource utilization, and increased data science productivity by minimizing infrastructure management overhead. It is ideal for Amazon EKS and Kubernetes-focused organizations, teams with large-scale distributed training needs, and those invested in the Ray ecosystem or SageMaker.


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
7. Worker pods execute their assigned tasks, potentially accessing required data from the storage services – such as Amazon Simple Storage Service (Amazon S3), Amazon Elastic File System (Amazon EFS), or Amazon FSx for Lustre – in the user VPC.
8. Throughout the job execution, metrics and logs are published to Amazon CloudWatch and Amazon Managed Service for Prometheus or Amazon Managed Grafana for observability.
9. When the Ray job is complete, the job artifacts (final model weights, inference results, and so on) are saved to the designated storage service.
10. Job results (status, metrics, logs) are sent through the Anyscale Operator back to the Anyscale Control Plane.

This flow shows distribution and execution of user-submitted jobs across the available computing resources, while maintaining monitoring and data accessibility throughout the process.
## Getting Started
### Prerequisites

* [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [AWS Credentials](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)
* [AWS Identity and Access Management](https://aws.amazon.com/iam/)(IAM) role permissions for SageMaker HyperPod.
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/)

## Set up SageMaker HyperPod

> **_NOTE:_** For more information on how to set up SageMaker HyperPod with Amazon EKS orchestration see Amazon SageMaker HyperPod quickstart. You can also refer to Amazon EKS Support in Amazon SageMaker HyperPod workshop, Using CloudFormation, [Using Terraform](https://catalog.workshops.aws/sagemaker-hyperpod-eks/en-US/00-setup/01-workshop-infra-tf), or the aws-do-hyperpod framework for additional ways to create your cluster.

The instructions below follow the [Using Terraform](https://catalog.workshops.aws/sagemaker-hyperpod-eks/en-US/00-setup/01-workshop-infra-tf) guide to setup a HyperPod cluster.

### Customize HyperPod Deployment Configuration

> Note: `terraform.tfvars` has been included to match the example from AWS.

Start by reviewing the default configurations in the `terraform.tfvars` file and make modifications to customize your deployment as needed.

If you wish to reuse any cloud resources rather than creating new ones, set the associated `create_*_module` variable to false and provide the id for the corresponding resource as the value of the `existing_*` variable.

For example, if you want to reuse an existing VPC, set `create_vpc_module` to `false`, then set `existing_vpc_id` to your `VPC ID`, like `vpc-1234567890abcdef0`.

#### Using a `custom.tfvars` File
To modify your deployment details without having to open and edit other files directly, create a `custom.tfvars` file with your parameter overrides.

For example, the following `custom.tfvars` file would enable the creation of all new resources including a new EKS Cluster and a HyperPod instance group of 2 ml.m5.4xlarge instances in us-west-2:
```shell
cat > custom.tfvars << EOL
kubernetes_version = "1.32"
eks_cluster_name = "my-eks-cluster"
hyperpod_cluster_name = "my-hp-cluster"
resource_name_prefix = "hp-eks-test"
availability_zone_id  = "usw2-az2"
instance_groups = {
    2CPU-8GB-instance-group = {
        instance_type = "ml.m5.large",
        instance_count = 2,
        ebs_volume_size_in_gb = 100,
        threads_per_core = 2,
        enable_stress_check = true,
        enable_connectivity_check = true,
        lifecycle_script = "on_create.sh"
    },
    4CPU-16GB-instance-group = {
        instance_type = "ml.m5.xlarge",
        instance_count = 2,
        ebs_volume_size_in_gb = 100,
        threads_per_core = 2,
        enable_stress_check = true,
        enable_connectivity_check = true,
        lifecycle_script = "on_create.sh"
    },
    8CPU-32GB-instance-group = {
        instance_type = "ml.m5.2xlarge",
        instance_count = 2,
        ebs_volume_size_in_gb = 100,
        threads_per_core = 2,
        enable_stress_check = true,
        enable_connectivity_check = true,
        lifecycle_script = "on_create.sh"
    }
}
EOL
```

### Deployment

> Note: You may need to increase some quotas e.g., the defaults create 2 NAT Gateways which require Elastic IP Addresses.

First, clone the HyperPod Helm charts GitHub repository  to locally stage the dependencies Helm chart:

```shell
git clone https://github.com/aws/sagemaker-hyperpod-cli.git /tmp/helm-repo
```

Apply the terraform

```shell
terraform init
terraform plan
terraform apply
```

If you created a `custom.tfvars` file, plan using the -var-file flag:

```shell
terraform init
terraform plan   -var-file=custom.tfvars
terraform apply  -var-file=custom.tfvars
```

### Environment Variables

Run the `terraform_outputs.sh` script, which populates the `env_vars.sh` script with your environment variables for future reference:

```shell
cd ..
chmod +x terraform_outputs.sh
./terraform_outputs.sh
cat env_vars.sh
```
Source the `env_vars.sh` script to set your environment variables:

```shell
source env_vars.sh
```
Verify that your environment variables are set:

```shell
echo $EKS_CLUSTER_NAME
echo $PRIVATE_SUBNET_ID
echo $SECURITY_GROUP_ID
```

### Verify your connection to the HyperPod cluster

Update with the name of your EKS cluster (not HyperPod cluster).
If you do not know the name then bbtain the name of the EKS cluster on the SageMaker HyperPod console.
In your cluster details, you will see your EKS cluster orchestrator.

```shell
aws eks update-kubeconfig --region <region> --name <my-eks-cluster>
kubectl get nodes -L node.kubernetes.io/instance-type -L sagemaker.amazonaws.com/node-health-status -L sagemaker.amazonaws.com/deep-health-check-status $@
```

### Installing K8s Components

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

### Create an EFS file system

```shell
source ./env_vars
echo "Creating EFS file system..."

echo "Retrieving Subnet ID..."
SUBNET_ID=$(aws sagemaker describe-cluster \
    --cluster-name $AWS_EKS_HYPERPOD_CLUSTER \
    --region $AWS_REGION \
    --query 'VpcConfig.Subnets' \
    --output text)
echo "Subnet ID: $SUBNET_ID"

echo "Retrieving VPC ID..."
VPC_ID=$(aws ec2 describe-subnets \
  --subnet-ids ${SUBNET_ID} \
  --query "Subnets[0].VpcId" \
  --output text)
echo "VPC ID: $VPC_ID"


echo "Retrieving Security Group ID..."
SECURITY_GROUP_ID=$(aws sagemaker describe-cluster \
	--cluster-name $AWS_EKS_HYPERPOD_CLUSTER \
	--region $AWS_REGION \
	--query 'VpcConfig.SecurityGroupIds[0]' \
	--output text)
echo "Security group ID: $SECURITY_GROUP_ID"


EFS_ID=$(aws efs create-file-system \
  --region $AWS_REGION \
  --encrypted \
  --performance-mode "$PERFORMANCE_MODE" \
  --throughput-mode "$THROUGHPUT_MODE" \
  --tags Key=Name,Value="$EFS_NAME" \
  --query 'FileSystemId' \
  --output text)

echo "EFS created with ID: $EFS_ID"

echo "Waiting for EFS file system $EFS_ID in region $AWS_REGION to become available..."

MAX_RETRIES=30
RETRY_INTERVAL=10  # seconds

for ((i=1; i<=MAX_RETRIES; i++)); do
  STATUS=$(aws efs describe-file-systems \
    --file-system-id "$EFS_ID" \
    --region ${AWS_REGION} \
    --query "FileSystems[0].LifeCycleState" \
    --output text 2>/dev/null)

  if [[ "$STATUS" == "available" ]]; then
    echo "✅ EFS $EFS_ID is now available."
    break
  fi

  echo "[$i/$MAX_RETRIES] EFS not ready yet (status: $STATUS). Retrying in ${RETRY_INTERVAL}s..."
  sleep $RETRY_INTERVAL
done

echo "Creating mount target in subnet $SUBNET_ID..."
aws efs create-mount-target \
  --region $AWS_REGION \
  --file-system-id "$EFS_ID" \
  --subnet-id "$SUBNET_ID" \
  --security-groups "$SECURITY_GROUP_ID"

echo "Mount target created for EFS $EFS_ID"

echo "export EFS_ID=$EFS_ID" > ./efs_env.sh

echo ""
echo "EFS File System Details:"
aws efs describe-file-systems --file-system-id "$EFS_ID" --region $AWS_REGION
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

1. Using the below example, replace `<aws_region>` with the AWS region where EKS is running, and replace `<cloud-deployment-id>` with the appropriate value from the `anyscale cloud register` output. Please note that you can also change the namespace to one that you wish to associate with Anyscale pods.
2. Using your updated helm upgrade command, install the Anyscale Operator.

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.cloudProvider=aws \
  --set-string global.aws.region=<aws_region> \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --namespace anyscale-operator \
  --create-namespace \
  --install
```

### Verify your Anyscale Cloud
```shell
anyscale job submit --cloud <your_cloud_name> --working-dir https://github.com/anyscale/docs_examples/archive/refs/heads/main.zip -- python hello_world.py
```
