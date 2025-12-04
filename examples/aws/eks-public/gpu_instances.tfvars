# GPU Instance Types for EKS
#
# This file contains additional GPU instance configurations that can be used
# with the EKS cluster. To use these configurations, include this file when
# running terraform:
#
#   terraform plan -var-file="gpu_instances.tfvars"
#   terraform apply -var-file="gpu_instances.tfvars"
#
# You can also selectively enable specific GPU types by setting the
# node_group_gpu_types variable.
#
# Note: Entries here will override defaults with the same key (e.g., T4 below
# overrides the default T4 to add more instance types).

# GPU types - overrides defaults and adds new types
additional_gpu_types = {
  # Override default T4 to include additional instance types
  "T4" = {
    product_name   = "Tesla-T4"
    instance_types = ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge"]
  }
  "T4-4x" = {
    product_name   = "Tesla-T4"
    instance_types = ["g4dn.12xlarge"]
  }
  "L4" = {
    product_name   = "NVIDIA-L4"
    instance_types = ["g6.2xlarge", "g6.4xlarge"]
  }
  "L4-4x" = {
    product_name   = "NVIDIA-L4"
    instance_types = ["g6.24xlarge"]
  }
}

# Enable all GPU types (default A10G plus types defined above)
node_group_gpu_types = ["T4", "A10G", "T4-4x", "L4", "L4-4x"]
