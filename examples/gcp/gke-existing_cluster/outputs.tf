data "google_container_cluster" "existing_gke_cluster" {
  name     = var.existing_gke_cluster_name
  location = var.existing_gke_cluster_location
  project  = var.google_project_id
}

locals {
  # If node_locations is empty (zonal cluster), use the cluster's location
  cluster_zones = length(data.google_container_cluster.existing_gke_cluster.node_locations) > 0 ? data.google_container_cluster.existing_gke_cluster.node_locations : [var.existing_gke_cluster_location]

  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--provider gcp",
    "--region ${var.google_region}",
    "--compute-stack k8s",
    "--kubernetes-zones ${join(",", local.cluster_zones)}",
    "--anyscale-operator-iam-identity ${google_service_account.gke_nodes.email}",
    "--cloud-storage-bucket-name ${module.anyscale_cloudstorage.cloudstorage_bucket_name}",
    "--project-id ${var.google_project_id}",
    "--vpc-name ${var.existing_vpc_name}",
    var.enable_filestore ? "--file-storage-id ${module.anyscale_filestore.anyscale_filestore_name}" : null,
    var.enable_filestore ? "--filestore-location ${module.anyscale_filestore.anyscale_filestore_location}" : null
  ])

  helm_upgrade_command_parts = compact([
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string global.cloudDeploymentId=<cloud-deployment-id>",
    "--set-string global.cloudProvider=gcp",
    "--set-string global.gcp.region=${var.google_region}",
    "--set-string global.auth.iamIdentity=${google_service_account.gke_nodes.email}",
    "--set-string workloads.serviceAccount.name=anyscale-operator",
    "--namespace ${var.anyscale_k8s_namespace}",
    "--create-namespace",
    "-i"
  ])
}

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = join(" \\\n", local.registration_command_parts)
}

output "anyscale_operator_service_account_email" {
  description = "The Anyscale operator service account email."
  value       = google_service_account.gke_nodes.email
}

output "helm_upgrade_command" {
  description = "The helm upgrade command."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}
