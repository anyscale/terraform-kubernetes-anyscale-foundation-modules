locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--provider gcp",
    "--region ${var.google_region}",
    "--compute-stack k8s",
    "--kubernetes-zones ${join(",", module.gke.zones)}",
    "--anyscale-operator-iam-identity ${google_service_account.gke_nodes.email}",
    "--cloud-storage-bucket-name ${module.anyscale_cloudstorage.cloudstorage_bucket_name}",
    "--project-id ${var.google_project_id}",
    "--vpc-name ${google_compute_network.anyscale.name}",
    var.enable_filestore ? "--file-storage-id ${module.anyscale_filestore.anyscale_filestore_name}" : "",
    var.enable_filestore ? "--filestore-location ${module.anyscale_filestore.anyscale_filestore_location}" : ""
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
