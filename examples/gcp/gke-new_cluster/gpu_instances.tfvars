# GPU Instance Types for GKE
#
# This file contains additional GPU instance configurations that can be used
# with the GKE cluster. To use these configurations, include this file when
# running terraform:
#
#   terraform plan -var-file="gpu_instances.tfvars"
#   terraform apply -var-file="gpu_instances.tfvars"
#
# You can also selectively enable specific GPU types by setting the
# node_group_gpu_types variable.

# Additional GPU configurations beyond the defaults
additional_gpu_configs = {
  "T4-lowcpu" = {
    instance = {
      disk_type          = "pd-ssd"
      gpu_driver_version = "LATEST"
      accelerator_count  = 1
      accelerator_type   = "nvidia-tesla-t4"
      machine_type       = "n1-standard-4"
    }
    node_labels = {
      "nvidia.com/gpu.product" = "nvidia-tesla-t4"
    }
  }

  "T4-highcpu" = {
    instance = {
      disk_type          = "pd-ssd"
      gpu_driver_version = "LATEST"
      accelerator_count  = 1
      accelerator_type   = "nvidia-tesla-t4"
      machine_type       = "n1-standard-16"
    }
    node_labels = {
      "nvidia.com/gpu.product" = "nvidia-tesla-t4"
    }
  }

  "T4-4x" = {
    instance = {
      disk_type          = "pd-ssd"
      gpu_driver_version = "LATEST"
      accelerator_count  = 4
      accelerator_type   = "nvidia-tesla-t4"
      machine_type       = "n1-standard-32"
    }
    node_labels = {
      "nvidia.com/gpu.product" = "nvidia-tesla-t4"
    }
  }

  "L4-medium" = {
    instance = {
      disk_type          = "pd-ssd"
      gpu_driver_version = "LATEST"
      accelerator_count  = 1
      accelerator_type   = "nvidia-l4"
      machine_type       = "g2-standard-16"
    }
    node_labels = {
      "nvidia.com/gpu.product" = "nvidia-l4"
    }
  }

  "L4-4x" = {
    instance = {
      disk_type          = "pd-ssd"
      gpu_driver_version = "LATEST"
      accelerator_count  = 4
      accelerator_type   = "nvidia-l4"
      machine_type       = "g2-standard-48"
    }
    node_labels = {
      "nvidia.com/gpu.product" = "nvidia-l4"
    }
  }
}

# Enable all GPU types (defaults plus additional types defined above)
node_group_gpu_types = ["T4", "T4-lowcpu", "T4-highcpu", "T4-4x", "L4", "L4-medium", "L4-4x"]
