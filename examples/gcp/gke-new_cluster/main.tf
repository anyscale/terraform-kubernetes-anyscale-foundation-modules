# ---------------------------------------------------------------------------------------------------------------------# Example Anyscale K8s Resources - Public Networking
#   This template cretes resources for Anyscale.
#
#   It creates:
#     - IAM Service Accounts
#     - Storage Bucket
#     - Filestore
# ---------------------------------------------------------------------------------------------------------------------
locals {
  gke_nodes_service_account_name  = "${var.gke_cluster_name}-nodes"
  gke_nodes_service_account_email = "${local.gke_nodes_service_account_name}@${var.google_project_id}.iam.gserviceaccount.com"

  full_labels = merge(tomap({
    anyscale-cloud-id = var.anyscale_cloud_id,
    }),
    var.labels
  )
}

module "anyscale_cloudstorage" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-cloudstorage"
  module_enabled = true

  bucket_iam_members = [
    "serviceAccount:${google_service_account.gke_nodes.email}"
  ]

  anyscale_bucket_name = "${var.gke_cluster_name}-bucket"

  bucket_force_destroy = false # Set to true to delete non-empty bucket
  anyscale_project_id  = var.google_project_id
  labels               = local.full_labels
}

# Get available zones in the region
data "google_compute_zones" "available" {
  project = var.google_project_id
  region  = var.google_region
  status  = "UP"
}

module "anyscale_filestore" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-filestore"
  module_enabled = var.enable_filestore

  filestore_vpc_name = google_compute_network.anyscale.name
  filestore_tier     = "STANDARD"
  filestore_location = data.google_compute_zones.available.names[0]

  anyscale_project_id = var.google_project_id
  labels              = local.full_labels
}

# Create GKE node service account
resource "google_service_account" "gke_nodes" {
  account_id   = local.gke_nodes_service_account_name
  display_name = "Service Account for GKE nodes"
  project      = var.google_project_id
}

# Grant necessary roles to the service account
#trivy:ignore:avd-gcp-0011
resource "google_project_iam_member" "gke_nodes_roles" {
  #checkov:skip=CKV_GCP_41: "assigned the Service Account User or Service Account Token Creator roles at project level"
  #checkov:skip=CKV_GCP_49: "impersonate or manage Service Accounts used at project level"

  for_each = toset([
    "roles/storage.admin",                  # Access to GCS buckets
    "roles/file.editor",                    # Access to Filestore
    "roles/iam.serviceAccountTokenCreator", # Generate presigned URL for Google Cloud Storage
    "roles/logging.logWriter",              # Write logs
    "roles/monitoring.metricWriter",        # Write metrics
    "roles/monitoring.viewer",              # Read metrics
    "roles/artifactregistry.reader"         # Pull container images
  ])

  project = var.google_project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_service_account_iam_binding" "workload_identity_bindings" {
  role               = "roles/iam.workloadIdentityUser"
  service_account_id = google_service_account.gke_nodes.id
  members            = ["serviceAccount:${var.google_project_id}.svc.id.goog[${var.anyscale_k8s_namespace}/anyscale-operator]"]

  depends_on = [module.gke]
}
