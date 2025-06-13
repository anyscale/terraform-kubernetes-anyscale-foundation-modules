# ---------------------------------------------------------------------------------------------------------------------
# ENVIRONMENT VARIABLES
# Define these secrets as environment variables
# ---------------------------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------------------------------
# REQUIRED VARIABLES
# These variables must be set when using this module.
# ---------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------------------------------------
# OPTIONAL VARIABLES
# These variables have defaults but must be included when using this module.
# ---------------------------------------------------------------------------------------------------------------------

variable "google_region" {
  description = <<-EOT
    (Required) The Google region in which all resources will be created.

    ex:
    ```
    google_region = "us-central1"
    ```
  EOT
  type        = string
}

variable "google_project_id" {
  description = <<-EOT
    (Required) The Google Cloud Project ID

    This value can be found in the Google Cloud Console under "Project info".

    ex:
    ```
    google_project_id = "my-project-id"
    ```
  EOT
  type        = string
}

# ------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables have defaults, but may be overridden.
# ------------------------------------------------------------------------------
variable "anyscale_cloud_id" {
  description = <<-EOT
    (Optional) Anyscale Cloud ID

    This value can be found under "Cloud settings" in the Anyscale Console This will be used for labeling resources.

    ex:
    ```
    anyscale_cloud_id = "cld_12345abcdefghijklmnop67890"
    ```
  EOT
  type        = string
  default     = null
  validation {
    condition = (
      var.anyscale_cloud_id == null ? true : (
        length(var.anyscale_cloud_id) > 4 &&
        substr(var.anyscale_cloud_id, 0, 4) == "cld_"
      )
    )
    error_message = "The anyscale_cloud_id value must start with \"cld_\"."
  }
}

variable "labels" {
  description = <<-EOT
    (Optional) A map of labels to all resources that accept labels.

    ex:
    ```
    labels = {
      "example" = true
      "environment" = "example"
    }
    ```
  EOT
  type        = map(string)
  default = {
    "example" : true,
    "environment" : "example"
  }
}

variable "gke_cluster_name" {
  description = <<-EOF
    (Optional) GKE Cluster Name

    The name of the GKE cluster to create.

    ex:
    ```
    cluster_name = "anyscale-cluster"
    ```
  EOF
  type        = string
  default     = "anyscale-gke"
  validation {
    condition     = can(regex("^\\D", var.gke_cluster_name)) && length(var.gke_cluster_name) < 23
    error_message = "Cluster name must not start with a number and must be under 23 characters."
  }
}
variable "node_group_gpu_types" {
  description = <<-EOT
    (Optional) The GPU types of the GKE nodes.
    Possible values: ["V100", "P100", "T4", "L4", "A100-40G", "A100-80G", "H100", "H100-MEGA"]
  EOT
  type        = list(string)
  default     = ["T4"]
}


variable "ingress_cidr_ranges" {
  description = <<-EOT
    (Optional) The IPv4 CIDR blocks that allows access Anyscale clusters.

    These are added to the firewall and allows port 443 (https) and 22 (ssh) access.

    ex:
    ```
    ingress_cidr_ranges=["52.1.1.23/32","10.1.0.0/16"]
    ```
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}


variable "anyscale_k8s_namespace" {
  description = <<-EOT
    (Optional) The Anyscale namespace to deploy the workload

    ex:
    ```
    anyscale_k8s_namespace = "anyscale-operator"
    ```
  EOT
  type        = string
  default     = "anyscale-operator"
}

variable "enable_filestore" {
  description = <<-EOT
    (Optional) Enable the creation of a Google Filestore instance.

    This is optional for Anyscale deployments. Filestore is used for shared storage between nodes.

    ex:
    ```
    enable_filestore = true
    ```
  EOT
  type        = bool
  default     = false
}
