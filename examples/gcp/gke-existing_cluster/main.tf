# ---------------------------------------------------------------------------------------------------------------------# Example Anyscale K8s Resources - Public Networking
#   This template cretes resources for Anyscale.
#
#   It creates:
#     - Storage Bucket
#     - Filestore
#     - GKE Node Service Account
#     - Firewall Rules
# ---------------------------------------------------------------------------------------------------------------------
locals {
  gke_nodes_service_account_name  = "anyscale-gke-nodes"
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

  anyscale_bucket_name = "anyscale-demo"

  bucket_iam_members = [
    "serviceAccount:${google_service_account.gke_nodes.email}"
  ]

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

  filestore_vpc_name = var.existing_vpc_name
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

# Allow common external ingress traffic (HTTPS, SSH, ICMP)
#trivy:ignore:avd-gcp-0027
resource "google_compute_firewall" "allow-common-ingress" {
  #checkov:skip=CKV_GCP_2: "Ensure Google compute firewall ingress does not allow unrestricted ssh access"

  name    = "anyscale-gke-allow-common-ingress"
  network = var.existing_vpc_name

  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22", "443"] # SSH, HTTP, HTTPS
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = var.ingress_cidr_ranges
}

resource "google_service_account_iam_binding" "workload_identity_bindings" {
  role               = "roles/iam.workloadIdentityUser"
  service_account_id = google_service_account.gke_nodes.id
  members            = ["serviceAccount:${var.google_project_id}.svc.id.goog[${var.anyscale_k8s_namespace}/anyscale-operator]"]
}
