# ---------------------------------------------------------------------------------------------------------------------# Example Anyscale K8s Resources - Public Networking
#   This template cretes resources for Anyscale with existing GKE Cluster
#   It creates:
#     - Storage Bucket
#     - Filestore
#     - IAM Service Accounts
#     - Firewall Policy
#     - Helm Charts
#   It expects the following to be already created:
#     - GCP Project
#     - GKE Cluster
#     - GKE Node Pool
#     - VPC
# ---------------------------------------------------------------------------------------------------------------------
locals {
  full_labels = merge(tomap({
    anyscale-cloud-id           = var.anyscale_cloud_id,
    anyscale-deploy-environment = var.anyscale_deploy_env
    }),
    var.labels
  )
}

module "anyscale_iam" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-iam"
  module_enabled = true

  anyscale_org_id                           = var.anyscale_org_id
  create_anyscale_access_role               = true
  create_anyscale_cluster_node_service_acct = true # Set to true to bind to a GKE Service Account
  anyscale_cluster_node_service_acct_name   = "anyscale-cluster-node"

  anyscale_project_id = var.google_project_id
}

module "anyscale_cloudstorage" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-cloudstorage"
  module_enabled = true

  bucket_iam_members = [
    module.anyscale_iam.iam_anyscale_access_service_acct_member,
    module.anyscale_iam.iam_anyscale_cluster_node_service_acct_member
  ]

  anyscale_project_id = var.google_project_id
  labels              = local.full_labels
}

module "anyscale_filestore" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-filestore"
  module_enabled = true

  filestore_vpc_name = var.existing_vpc_name
  filestore_tier     = "STANDARD"
  filestore_location = "us-central1-b"

  anyscale_project_id = var.google_project_id
  labels              = local.full_labels
}

module "anyscale_firewall" {
  #checkov:skip=CKV_TF_1: Example code should use the latest version of the module
  #checkov:skip=CKV_TF_2: Example code should use the latest version of the module
  source         = "github.com/anyscale/terraform-google-anyscale-cloudfoundation-modules//modules/google-anyscale-vpc-firewall"
  module_enabled = true

  vpc_name = var.existing_vpc_name
  vpc_id   = data.google_compute_network.existing_vpc.id

  ingress_with_self_cidr_range = [var.existing_subnet_cidr]
  ingress_from_cidr_map = [
    {
      rule        = "https-443-tcp"
      cidr_blocks = var.customer_ingress_cidr_ranges
    },
    {
      rule        = "ssh-tcp"
      cidr_blocks = var.customer_ingress_cidr_ranges
    }
  ]

  anyscale_project_id = var.google_project_id
}


module "anyscale_k8s_namespace" {
  source = "../../../modules/anyscale-k8s-namespace"

  module_enabled = true
  cloud_provider = "gcp"

  kubernetes_cluster_name       = var.existing_gke_cluster_name
  anyscale_kubernetes_namespace = var.anyscale_k8s_namespace
}

// Optional for managing Kupernetes service account bindings to GCP IAM roles
resource "kubernetes_service_account" "anyscale" {
  metadata {
    name      = "anyscale-service-account"
    namespace = var.anyscale_k8s_namespace

    annotations = {
      "iam.gke.io/gcp-service-account" = module.anyscale_iam.iam_anyscale_cluster_node_service_acct_email
    }
  }

  depends_on = [module.anyscale_k8s_namespace]
}

resource "google_service_account_iam_binding" "workload_identity_bindings" {
  role               = "roles/iam.workloadIdentityUser"
  service_account_id = module.anyscale_iam.iam_anyscale_cluster_node_service_acct_name
  members            = ["serviceAccount:${var.google_project_id}.svc.id.goog[${var.anyscale_k8s_namespace}/anyscale-operator]"]
}

module "anyscale_k8s_helm" {
  source = "../../../modules/anyscale-k8s-helm"

  module_enabled = true
  cloud_provider = "gcp"

  kubernetes_cluster_name = data.google_container_cluster.anyscale.name

  anyscale_cluster_autoscaler_chart = { enabled = false }
  anyscale_metrics_server_chart     = { enabled = false }
}
