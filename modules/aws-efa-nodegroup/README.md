# AWS EFA EKS Managed Node Group Module

This module creates the AWS infrastructure required before Kubernetes can expose
EFA devices to Pods running on `p5.48xlarge` H100 workers.

It is intentionally scoped to the GPU worker node group. It expects an existing
EKS cluster, VPC, subnet, and worker-node IAM role from an Anyscale/EKS
foundation module.

## What It Creates

```text
aws_placement_group strategy=cluster
EFA security group with self-referencing all ingress/egress
aws_launch_template with EFA-only network interfaces
aws_eks_node_group pinned to one subnet/AZ
```

The default network interface layout is for `p5.48xlarge`:

```text
network card 0, device 0: interface  (primary ENA/IP)
network card 0, device 1: efa-only   (RDMA)
network cards 1-31, device 0: efa-only
```

That gives one IP-consuming ENA interface for Kubernetes/TCP bootstrap traffic
and 32 EFA-only interfaces for RDMA payload traffic.

The module intentionally defaults to `p5.48xlarge` and H100 node metadata. The
caller still controls the workload identity through `workload_name`, which is
used in generated resource names, Kubernetes labels, default taints, and
Cluster Autoscaler node-template tags. Override `labels`, `taints`, or
`enable_cluster_autoscaler_tags` when integrating with a different scheduler
policy.

## Example

```hcl
module "h100_efa_nodegroup" {
  source = "./modules/aws-efa-nodegroup"

  cluster_name  = "my-eks-cluster"
  vpc_id        = "vpc-0123456789abcdef0"
  subnet_id     = "subnet-0123456789abcdef0"
  node_role_arn = "arn:aws:iam::123456789012:role/eks-node-role"

  availability_zone = "us-west-2a"
  workload_name     = "training"
  desired_size      = 4
  min_size          = 0
  max_size          = 4

  cluster_security_group_ids    = ["sg-eks-control-plane"]
  additional_security_group_ids = ["sg-existing-anyscale-or-node-sg"]

  tags = {
    project = "h100-efa"
  }
}
```

For Capacity Blocks:

```hcl
capacity_type           = "CAPACITY_BLOCK"
capacity_reservation_id = "cr-0123456789abcdef0"
subnet_id               = "subnet-in-the-reservation-az"
```

## Follow-On Kubernetes Layer

After this module is applied, install either the EFA device plugin or EFA DRA
driver. With the device plugin path, a `p5.48xlarge` node should advertise:

```text
nvidia.com/gpu: 8
vpc.amazonaws.com/efa: 32
```

Pods for this node group should request all node-local devices:

```yaml
resources:
  limits:
    nvidia.com/gpu: 8
    vpc.amazonaws.com/efa: 32
```

## Validation

Run in a Terraform-capable environment:

```bash
terraform fmt -recursive
terraform init
terraform validate
terraform plan
```

After apply:

```bash
kubectl get nodes -l efa=true -o wide
kubectl describe node <node-name> | egrep 'nvidia.com/gpu|vpc.amazonaws.com/efa'
```

Then run workload-image checks that exercise EFA device discovery, NCCL, and
any collective communication libraries used by the workload.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0, < 7.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0, < 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_autoscaling_group_tag.efa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group_tag) | resource |
| [aws_eks_node_group.efa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_launch_template.efa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_placement_group.efa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/placement_group) | resource |
| [aws_security_group.efa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.cluster_ingress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.efa_all_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.efa_self_egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.efa_self_ingress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | (Required) Name of the existing EKS cluster. | `string` | n/a | yes |
| <a name="input_node_role_arn"></a> [node\_role\_arn](#input\_node\_role\_arn) | (Required) IAM role ARN for the EKS managed node group workers. | `string` | n/a | yes |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | (Required) Single subnet ID for the EFA managed node group. Use a private subnet in one Availability Zone. | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | (Required) VPC ID where the EKS worker nodes and EFA security group are created. | `string` | n/a | yes |
| <a name="input_additional_security_group_ids"></a> [additional\_security\_group\_ids](#input\_additional\_security\_group\_ids) | (Optional) Additional security group IDs attached to every launch-template network interface, such as an existing Anyscale/EKS node security group. | `list(string)` | `[]` | no |
| <a name="input_allow_all_egress"></a> [allow\_all\_egress](#input\_allow\_all\_egress) | (Optional) Whether to allow outbound IPv4 traffic from the EFA security group. | `bool` | `true` | no |
| <a name="input_ami_id"></a> [ami\_id](#input\_ami\_id) | (Optional) Custom AMI ID for the launch template. If set, provide bootstrap-compatible user data outside this module if needed. | `string` | `null` | no |
| <a name="input_ami_type"></a> [ami\_type](#input\_ami\_type) | (Optional) EKS managed node group AMI type. Ignored when ami\_id is set in the launch template. | `string` | `"AL2023_x86_64_NVIDIA"` | no |
| <a name="input_availability_zone"></a> [availability\_zone](#input\_availability\_zone) | (Optional) Expected Availability Zone for subnet\_id. When set, the module verifies the subnet is in this AZ. | `string` | `null` | no |
| <a name="input_capacity_reservation_id"></a> [capacity\_reservation\_id](#input\_capacity\_reservation\_id) | (Optional) Targeted EC2 Capacity Reservation ID. Required when capacity\_type is CAPACITY\_BLOCK; also usable with ON\_DEMAND targeted reservations. | `string` | `null` | no |
| <a name="input_capacity_type"></a> [capacity\_type](#input\_capacity\_type) | (Optional) EKS managed node group capacity type. | `string` | `"ON_DEMAND"` | no |
| <a name="input_cluster_security_group_ids"></a> [cluster\_security\_group\_ids](#input\_cluster\_security\_group\_ids) | (Optional) EKS control-plane or cluster security group IDs allowed to initiate traffic to EFA nodes. | `list(string)` | `[]` | no |
| <a name="input_create_efa_security_group"></a> [create\_efa\_security\_group](#input\_create\_efa\_security\_group) | (Optional) Whether to create the EFA security group. | `bool` | `true` | no |
| <a name="input_desired_size"></a> [desired\_size](#input\_desired\_size) | (Optional) Desired number of EFA worker nodes. | `number` | `4` | no |
| <a name="input_efa_interface_count"></a> [efa\_interface\_count](#input\_efa\_interface\_count) | (Optional) Number of EFA-only interfaces to generate when network\_interfaces is not supplied. p5.48xlarge supports 32. | `number` | `32` | no |
| <a name="input_efa_security_group_id"></a> [efa\_security\_group\_id](#input\_efa\_security\_group\_id) | (Optional) Existing EFA security group ID to use when create\_efa\_security\_group is false. | `string` | `null` | no |
| <a name="input_efa_security_group_name"></a> [efa\_security\_group\_name](#input\_efa\_security\_group\_name) | (Optional) Name for the EFA security group. | `string` | `null` | no |
| <a name="input_efa_security_group_name_prefix"></a> [efa\_security\_group\_name\_prefix](#input\_efa\_security\_group\_name\_prefix) | (Optional) Name prefix for the EFA security group. | `string` | `null` | no |
| <a name="input_enable_cluster_autoscaler_tags"></a> [enable\_cluster\_autoscaler\_tags](#input\_enable\_cluster\_autoscaler\_tags) | (Optional) Whether to add Cluster Autoscaler node-template tags for the P5/H100/EFA labels, taints, and resources. | `bool` | `true` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | (Optional) EFA-capable GPU instance type for the node group. | `string` | `"p5.48xlarge"` | no |
| <a name="input_labels"></a> [labels](#input\_labels) | (Optional) Additional or overriding Kubernetes labels for the managed node group. The module supplies P5/H100/EFA defaults. | `map(string)` | `{}` | no |
| <a name="input_launch_template_name_prefix"></a> [launch\_template\_name\_prefix](#input\_launch\_template\_name\_prefix) | (Optional) Explicit launch template name prefix. | `string` | `null` | no |
| <a name="input_max_size"></a> [max\_size](#input\_max\_size) | (Optional) Maximum number of EFA worker nodes. | `number` | `4` | no |
| <a name="input_min_size"></a> [min\_size](#input\_min\_size) | (Optional) Minimum number of EFA worker nodes. | `number` | `0` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | (Optional) Prefix used for generated resource names. | `string` | `null` | no |
| <a name="input_network_interfaces"></a> [network\_interfaces](#input\_network\_interfaces) | (Optional) Override launch-template network interface layout.<br/><br/>Leave null for the p5.48xlarge one-IP layout:<br/>card 0 device 0 interface, card 0 device 1 efa-only, cards 1..31 device 0 efa-only. | <pre>list(object({<br/>    network_card_index = number<br/>    device_index       = number<br/>    interface_type     = string<br/>  }))</pre> | `null` | no |
| <a name="input_node_group_name"></a> [node\_group\_name](#input\_node\_group\_name) | (Optional) Explicit EKS managed node group name. | `string` | `null` | no |
| <a name="input_placement_group_name"></a> [placement\_group\_name](#input\_placement\_group\_name) | (Optional) Explicit placement group name. Defaults to a name derived from name\_prefix. | `string` | `null` | no |
| <a name="input_revoke_security_group_rules_on_delete"></a> [revoke\_security\_group\_rules\_on\_delete](#input\_revoke\_security\_group\_rules\_on\_delete) | (Optional) Whether Terraform revokes security group rules before deleting the EFA security group. | `bool` | `false` | no |
| <a name="input_root_block_device_name"></a> [root\_block\_device\_name](#input\_root\_block\_device\_name) | (Optional) Root block device name for the EKS optimized AMI. | `string` | `"/dev/xvda"` | no |
| <a name="input_root_volume_encrypted"></a> [root\_volume\_encrypted](#input\_root\_volume\_encrypted) | (Optional) Whether to encrypt the root EBS volume. | `bool` | `true` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | (Optional) Root EBS volume size in GiB. | `number` | `300` | no |
| <a name="input_root_volume_type"></a> [root\_volume\_type](#input\_root\_volume\_type) | (Optional) Root EBS volume type. | `string` | `"gp3"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags applied to resources that support tags. | `map(string)` | `{}` | no |
| <a name="input_taints"></a> [taints](#input\_taints) | (Optional) Kubernetes taints for the managed node group.<br/><br/>Effects must use AWS EKS API values: NO\_SCHEDULE, NO\_EXECUTE, or PREFER\_NO\_SCHEDULE. | <pre>list(object({<br/>    key    = string<br/>    value  = string<br/>    effect = string<br/>  }))</pre> | `null` | no |
| <a name="input_update_max_unavailable"></a> [update\_max\_unavailable](#input\_update\_max\_unavailable) | (Optional) Maximum unavailable nodes during managed node group updates. | `number` | `1` | no |
| <a name="input_workload_label_key"></a> [workload\_label\_key](#input\_workload\_label\_key) | (Optional) Kubernetes label and taint key used to isolate this P5/H100 EFA node group. | `string` | `"workload"` | no |
| <a name="input_workload_name"></a> [workload\_name](#input\_workload\_name) | (Optional) Workload name used in default resource names, Kubernetes labels, taints, and Cluster Autoscaler template tags. | `string` | `"h100-efa"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_efa_security_group_id"></a> [efa\_security\_group\_id](#output\_efa\_security\_group\_id) | Security group ID used by EFA network interfaces. |
| <a name="output_launch_template_default_version"></a> [launch\_template\_default\_version](#output\_launch\_template\_default\_version) | Default version of the EFA launch template. |
| <a name="output_launch_template_id"></a> [launch\_template\_id](#output\_launch\_template\_id) | ID of the EFA launch template. |
| <a name="output_launch_template_latest_version"></a> [launch\_template\_latest\_version](#output\_launch\_template\_latest\_version) | Latest version of the EFA launch template. |
| <a name="output_network_interfaces"></a> [network\_interfaces](#output\_network\_interfaces) | Network interface layout rendered into the launch template. |
| <a name="output_node_group_arn"></a> [node\_group\_arn](#output\_node\_group\_arn) | ARN of the EKS managed node group. |
| <a name="output_node_group_name"></a> [node\_group\_name](#output\_node\_group\_name) | Name of the EKS managed node group. |
| <a name="output_node_group_status"></a> [node\_group\_status](#output\_node\_group\_status) | Status of the EKS managed node group. |
| <a name="output_placement_group_name"></a> [placement\_group\_name](#output\_placement\_group\_name) | Name of the cluster placement group. |
| <a name="output_security_group_ids"></a> [security\_group\_ids](#output\_security\_group\_ids) | Full set of security group IDs attached to launch-template network interfaces. |
| <a name="output_subnet_availability_zone"></a> [subnet\_availability\_zone](#output\_subnet\_availability\_zone) | Availability Zone of subnet\_id. |
<!-- END_TF_DOCS -->
