###############################################################################
# AZURE BLOB CSI DRIVER - PVC SUPPORT FOR WORKLOADS
###############################################################################
# When enable_blob_driver = true, the AKS cluster has the Azure Blob CSI driver
# enabled (see aks.tf storage_profile.blob_driver_enabled). The CSI driver runs
# in two halves that authenticate via DIFFERENT AKS identities, and BOTH need
# roles on the storage account for dynamic-provisioning PVCs to work end to end:
#
#   - csi-blob-CONTROLLER runs as the AKS control-plane SystemAssigned
#     identity. At PVC-create time it provisions a new blob container under the
#     storage account — needs container-write rights on the storage account.
#   - csi-blob-NODE runs as the AKS kubelet identity (the auto-created
#     `<cluster>-agentpool` user-assigned MI). At pod-mount time it mounts the
#     blob container via blobfuse, fetching keys via MSI.
#
# Two role assignments are required on each of the two identities:
#   1. Storage Blob Data Contributor       - read/write on blob data
#   2. Storage Account Key Operator        - fetch shared keys for fuse mount
#
# Granting only one identity (which Anyscale docs do, suggesting the control
# plane only) leaves the other half unauthorized:
#   - Control plane only -> mount-time failure (kubelet AADSTS70025)
#   - Kubelet only       -> provisioning-time failure (controller 403 on
#                            Microsoft.Storage/storageAccounts/blobServices/containers/write)
#
# These resources are scoped to the Anyscale-managed storage account already
# created in main.tf, so they only get added when both enable_blob_driver = true
# AND enable_operator_infrastructure = true.
###############################################################################

# --- AKS control plane (SystemAssigned) identity -----------------------------
# Needed by csi-blob-controller for dynamic container provisioning.

resource "azurerm_role_assignment" "aks_cp_blob_data_contributor" {
  count                = var.enable_blob_driver && var.enable_operator_infrastructure ? 1 : 0
  scope                = azurerm_storage_account.sa[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

resource "azurerm_role_assignment" "aks_cp_blob_key_operator" {
  count                = var.enable_blob_driver && var.enable_operator_infrastructure ? 1 : 0
  scope                = azurerm_storage_account.sa[0].id
  role_definition_name = "Storage Account Key Operator Service Role"
  principal_id         = azurerm_kubernetes_cluster.aks.identity[0].principal_id
}

# --- AKS kubelet (UserAssigned, agentpool) identity --------------------------
# Needed by csi-blob-node for pod-runtime mount + MSI key fetch.

resource "azurerm_role_assignment" "aks_kubelet_blob_data_contributor" {
  count                = var.enable_blob_driver && var.enable_operator_infrastructure ? 1 : 0
  scope                = azurerm_storage_account.sa[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}

resource "azurerm_role_assignment" "aks_kubelet_blob_key_operator" {
  count                = var.enable_blob_driver && var.enable_operator_infrastructure ? 1 : 0
  scope                = azurerm_storage_account.sa[0].id
  role_definition_name = "Storage Account Key Operator Service Role"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
}
