## Solution overview
The following architecture diagram illustrates SageMaker HyperPod with Amazon EKS orchestration and Anyscale.

<img src="assets/anyscale-aws-hyperpod-arch-diagram.png" width="1024" height="570">


See [here](details.md) for more details on this architecture.

## Getting Started
### Prerequisites
1. **AWS Account Setup**
    1. An **AWS account** with billing enabled
    1. [**AWS Identity and Access Management**](https://aws.amazon.com/iam/)(IAM) role permissions for SageMaker HyperPod
    1. [**AWS Credentials**](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html) set up in your local environment, either as environment variables or through credentials and profile files.
    1. [**AWS CLI**](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) installed on your local laptop.
1. **Tools** installed on your local laptop:
    1. **Git CLI** on a mac with `brew` via `brew install git`. Other [install options](https://git-scm.com/install/mac) are available.
    1. **Terraform** (version 1.0.0 or later) on a mac with `brew` via `brew tap hashicorp/tap` then `brew install terraform`. Other [install options](https://developer.hashicorp.com/terraform/tutorials/gcp-get-started/install-cli) are available.
    1. Basic understanding of Terraform and Infrastructure as Code
    1. **helm CLI** on a mac with `brew` via `brew install helm`. Other [install options](https://helm.sh/docs/intro/install/) are available.
    1. **kubectl CLI** on a mac with `brew` via `brew install kubectl`. Other [install options](https://kubernetes.io/docs/tasks/tools/) are available.
1. **Anyscale Account Setup**
    1. **Anyscale CLI** installed on your local laptop via `pip install anyscale --upgrade`.
    1. An **Anyscale organization** (account).
    1. Authenticate local environment with Anyscale. Run `anyscale login`, open the link which is output in your browser, and click approve.

## Set up SageMaker HyperPod
### Customize HyperPod Deployment Configuration

Review the default configurations in the existing `terraform.tfvars` file and make modifications to customize your deployment as needed.

* Variables you will likely want to update

    ```tf
    anyscale_new_cloud_name = "my-new-cloud-name"
    kubernetes_version = "1.31"
    eks_cluster_name = "my-eks-cluster"
    hyperpod_cluster_name = "my-hyperpod-cluster"
    resource_name_prefix = "hyperpod-prefix-name"
    aws_region = "us-west-2"
    availability_zone_id  = "usw2-az2"
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
### Verify your connection to the HyperPod cluster

Using the output from the Terraform modules, verify a connection to the HyperPod cluster. It should look sonething:

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

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

1. Using the output from the Terraform modules, register the Anyscale Cloud. It should look sonething like:

```shell
anyscale cloud register --provider aws \
  --name <anyscale-cloud-name> \
  --compute-stack k8s \
  --region us-west-2 \
  --s3-bucket-id <anyscale_example_bucket> \
  --kubernetes-zones us-west-2a,us-west-2b,us-west-2c \
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
3. Verify operator is installed:
```shell
helm list -n anyscale-operator
```

### Verify your Anyscale Cloud
```shell
anyscale job submit --cloud <anyscale-cloud-name> --working-dir https://github.com/anyscale/docs_examples/archive/refs/heads/main.zip -- python hello_world.py
```

### Clean up

```shell
kubectl delete deployment anyscale-operator -n anyscale
kubectl delete deployment ingress-nginx-controller -n ingress-nginx
kubectl delete pods --all -n ingress-nginx
```