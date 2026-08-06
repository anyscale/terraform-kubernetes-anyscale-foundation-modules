###############################################################################
# SHARED FILE STORAGE FOR RAY PODS (blobfuse2 CSI + ReadWriteMany PVC)
#
# Anyscale on AWS/GCP gets shared POSIX storage from EFS/Filestore, mounted by
# ID. Azure has no equivalent "mount by ID" path — the supported mechanism is a
# ReadWriteMany PersistentVolumeClaim backed by the Azure Blob CSI driver
# (blobfuse2), which the Anyscale cloud then attaches to every workload.
#
# This file provisions the Kubernetes half of that setup plus the extra Azure
# role assignments the CSI driver needs. Registering the PVC with the Anyscale
# cloud is a separate step — see the note at the bottom of this file.
#
# Mount authentication uses Microsoft Entra workload identity
# (`mountWithWorkloadIdentityToken`), reusing the operator's user-assigned
# identity from identity.tf. No storage account keys are handed to pods.
###############################################################################

locals {
  shared_pvc_container_name = coalesce(
    var.shared_pvc_container_name,
    "${var.aks_cluster_name}-shared",
  )

  # The blob CSI driver components do not all run under the same identity: the
  # controller (provisioning, container access) uses the cluster's
  # system-assigned identity, while the node plugin runs under the kubelet
  # identity. AKS creates these as two distinct principals, so grant both
  # rather than guessing which one services a given mount.
  shared_pvc_csi_principal_ids = var.enable_shared_pvc ? toset([
    azurerm_kubernetes_cluster.aks.identity[0].principal_id,
    azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id,
  ]) : toset([])
}

###############################################################################
# Dedicated container backing the shared volume.
#
# Deliberately separate from the artifact/log container in main.tf: that one is
# the Anyscale cloud's object store and is written through the control plane,
# whereas this one is a POSIX-ish filesystem written directly by user code.
# Naming it here (rather than letting the CSI driver dynamically provision one)
# keeps the container's lifecycle in Terraform and gives it a stable name.
###############################################################################
resource "azurerm_storage_container" "shared_pvc" {
  count = var.enable_shared_pvc ? 1 : 0

  #checkov:skip=CKV2_AZURE_21: "Ensure Storage logging is enabled for Blob service for read requests"

  name                  = local.shared_pvc_container_name
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

###############################################################################
# ROLE ASSIGNMENTS FOR THE CSI DRIVER
#
# identity.tf already grants "Storage Blob Data Contributor" to the *operator*
# identity, which is what workload-identity mounts authenticate as. The CSI
# driver itself is a separate principal and needs its own grants:
#
#   - Storage Blob Data Contributor      — read/write and container access
#   - Storage Account Key Operator Service Role — read account keys, which the
#     driver still requires for some mount and provisioning paths even when
#     pods authenticate via workload identity
###############################################################################
resource "azurerm_role_assignment" "shared_pvc_csi_blob_contrib" {
  for_each = local.shared_pvc_csi_principal_ids

  scope                            = azurerm_storage_account.sa.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = each.value
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "shared_pvc_csi_key_operator" {
  for_each = local.shared_pvc_csi_principal_ids

  scope                            = azurerm_storage_account.sa.id
  role_definition_name             = "Storage Account Key Operator Service Role"
  principal_id                     = each.value
  skip_service_principal_aad_check = true
}

###############################################################################
# StorageClass
#
# `protocol: fuse2` selects blobfuse2. `mountWithWorkloadIdentityToken` makes
# the mount exchange the pod's service-account token for an Entra token
# instead of using an account key — this is why the federated identity
# credential in identity.tf must be bound to the operator service account.
#
# reclaimPolicy Retain: the backing container is Terraform-managed, so a
# deleted PVC must not take the data with it.
###############################################################################
resource "kubernetes_storage_class_v1" "shared_pvc" {
  count = var.enable_shared_pvc ? 1 : 0

  metadata {
    name = var.shared_pvc_storage_class_name
  }

  storage_provisioner    = "blob.csi.azure.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  parameters = {
    protocol                       = "fuse2"
    storageAccount                 = azurerm_storage_account.sa.name
    resourceGroup                  = azurerm_resource_group.rg.name
    containerName                  = azurerm_storage_container.shared_pvc[0].name
    mountWithWorkloadIdentityToken = "true"

    # REQUIRED, despite being absent from the Anyscale Azure PVC doc's example
    # StorageClass. The CSI *node plugin* performs the mount, and it cannot see
    # the pod service account's `azure.workload.identity/client-id` annotation
    # (that annotation only drives the pod's own SDK calls). Without clientID
    # the driver falls back to the kubelet identity and the mount fails with:
    #
    #   AADSTS70025: The client '<cluster>-agentpool' has no configured
    #   federated identity credentials
    #
    # Verified against a live AKS cluster 2026-07-21.
    clientID = azurerm_user_assigned_identity.anyscale_operator.client_id
  }

  # allow_other lets the ray container's non-root user read the mount.
  #
  # The block cache is what makes large sequential reads (datasets,
  # checkpoints) perform acceptably over blob, but a bare `--block-cache`
  # (as in the Anyscale doc) fails to mount:
  #   "config error in block_cache [memory limit too low for configured prefetch]"
  # because the defaults size the prefetch pool against node memory. The three
  # explicit values below are a verified-working combination. Note that
  # prefetch has a floor — values below ~11 fail with "invalid prefetch count".
  mount_options = [
    "-o allow_other",
    "--block-cache",
    "--block-cache-block-size=${var.shared_pvc_block_cache.block_size_mb}",
    "--block-cache-pool-size=${var.shared_pvc_block_cache.pool_size_mb}",
    "--block-cache-prefetch=${var.shared_pvc_block_cache.prefetch_blocks}",
  ]

  lifecycle {
    precondition {
      condition     = var.enable_blob_driver
      error_message = "enable_shared_pvc requires enable_blob_driver = true so the AKS cluster runs the Azure Blob CSI driver."
    }
  }

  depends_on = [
    azurerm_role_assignment.shared_pvc_csi_blob_contrib,
    azurerm_role_assignment.shared_pvc_csi_key_operator,
  ]
}

###############################################################################
# PersistentVolumeClaim
#
# Must live in the operator's namespace (that is where Ray pods are scheduled)
# and must be ReadWriteMany so head and workers can hold it simultaneously.
#
# OPERATIONAL NOTE: the CSI driver mounts with `--cancel-list-on-mount-seconds=10`,
# so for the first 10 seconds after a pod mounts this volume, directory listings
# (`ls`, `find`, glob) return EMPTY while reads by explicit path work normally.
# This is intentional upstream behaviour, not a misconfiguration — but workload
# code that enumerates the mount at startup can see a spuriously empty directory.
#
# The namespace is created by the operator extension, hence the depends_on.
# `storage` is a required field on a PVC but is not a hard quota here — blob
# containers grow on demand — so it functions as a declared ceiling only.
###############################################################################
resource "kubernetes_persistent_volume_claim_v1" "shared_pvc" {
  count = var.enable_shared_pvc ? 1 : 0

  metadata {
    name      = var.shared_pvc_name
    namespace = var.anyscale_operator_namespace
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = kubernetes_storage_class_v1.shared_pvc[0].metadata[0].name

    resources {
      requests = {
        storage = "${var.shared_pvc_size_gi}Gi"
      }
    }
  }

  # Immediate binding means the CSI driver provisions on create; block until it
  # succeeds so a misconfigured mount surfaces during apply rather than as a
  # pending pod later.
  wait_until_bound = true

  depends_on = [
    azurerm_kubernetes_cluster_extension.anyscale_operator,
  ]
}

###############################################################################
# REGISTERING THE PVC WITH THE ANYSCALE CLOUD
#
# The resources above give the cluster a mountable RWX volume. For Anyscale to
# attach it to every workload automatically, the cloud must also record:
#
#   file_storage:
#     persistent_volume_claim: <var.shared_pvc_name>
#
# That property is NOT set here. The documented path is `anyscale cloud update
# --resources-file`, which takes a complete cloud resource spec — there is no
# single-field flag for it — and the equivalent property name on the
# Anyscale.Platform/clouds/cloudResources ARM surface (anyscale.tf) is not
# documented. Wiring either one blind risks clobbering the cloud's storage
# config, so this last step is left manual; see the
# `shared_pvc_registration_instructions` output.
#
# Per-workload mounts do not need this at all — a compute config can reference
# the PVC directly via advanced_instance_config.
###############################################################################
