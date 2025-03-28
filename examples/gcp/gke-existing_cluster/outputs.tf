output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = <<-EOT
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --provider gcp \
  --region ${var.google_region} \
  --compute-stack k8s \
  --kubernetes-zones <zones> \
  --anyscale-operator-iam-identity ${google_service_account.gke_nodes.email} \
  --cloud-storage-bucket-name ${module.anyscale_cloudstorage.cloudstorage_bucket_name} \
  --project-id ${var.google_project_id} \
  --vpc-name ${var.existing_vpc_name} \
  --file-storage-id ${module.anyscale_filestore.anyscale_filestore_name} \
  --filestore-location ${module.anyscale_filestore.anyscale_filestore_location}
  EOT
}

output "anyscale_operator_service_account_email" {
  description = "The Anyscale operator service account email."
  value       = google_service_account.gke_nodes.email
}
