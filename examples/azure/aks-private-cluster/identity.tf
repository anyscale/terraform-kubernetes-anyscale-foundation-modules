###############################################################################
# MANAGED IDENTITY FOR THE ANYSCALE OPERATOR
#
# The Azure counterpart of the IAM roles in examples/aws/eks-private-cpu.
#
# On EKS the operator inherits permissions from the node group's instance role.
# On AKS it uses Microsoft Entra **workload identity**: a user-assigned managed
# identity federated to the cluster's OIDC issuer and bound to the operator's
# Kubernetes service account. The operator pod receives a projected service
# account token and exchanges it at login.microsoftonline.com for an Entra
# token.
#
# That exchange is why the NSG in main.tf must permit Entra egress - Entra has
# no Private Link, so it is the one dependency that cannot be made private no
# matter how the rest of the network is locked down.
###############################################################################
resource "azurerm_user_assigned_identity" "anyscale_operator" {
  name                = "${var.aks_cluster_name}-anyscale-operator-mi"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

###############################################################################
# FEDERATED IDENTITY CREDENTIAL (ServiceAccount -> User-Assigned Identity)
#
# The subject must match the namespace and service account the operator
# actually runs as. Changing var.anyscale_operator_namespace or
# var.anyscale_operator_serviceaccount without reinstalling the operator breaks
# the token exchange, and the failure surfaces as authentication errors from
# the operator rather than anything obviously identity-shaped.
###############################################################################
resource "azurerm_federated_identity_credential" "anyscale_operator" {
  name = "anyscale-operator-fic"

  # `user_assigned_identity_id` replaces the deprecated `parent_id` and
  # `resource_group_name` pair - the identity's resource ID already carries the
  # resource group. The sibling Azure examples in this repo still use the old
  # arguments because they pin older provider versions.
  user_assigned_identity_id = azurerm_user_assigned_identity.anyscale_operator.id

  issuer   = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject  = "system:serviceaccount:${var.anyscale_operator_namespace}:${var.anyscale_operator_serviceaccount}"
  audience = ["api://AzureADTokenExchange"] # fixed value for Entra token exchange
}

###############################################################################
# ROLE ASSIGNMENT (IDENTITY -> STORAGE ACCOUNT)
#
# Lets the operator read and write the Anyscale cloud storage container. The
# ACR role assignments for the same identity live in acr.tf, next to the
# registry they apply to.
###############################################################################
resource "azurerm_role_assignment" "anyscale_blob_contributor" {
  scope                            = azurerm_storage_account.sa.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.anyscale_operator.principal_id
  skip_service_principal_aad_check = true
}

###############################################################################
# HOW THE SERVICE ACCOUNT IS BOUND
#
# The Anyscale operator creates the service account; the annotation below is
# what ties it to this identity. The operator extension receives the client ID
# as `global.auth.iamIdentity` (see the anyscale_operator_extension_settings
# output), so you should not need to apply this by hand - it is here as a
# reference for debugging.
#
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: anyscale-operator
#   namespace: anyscale-operator
#   annotations:
#     azure.workload.identity/client-id: "<anyscale_operator_client_id output>"
#
# Pods using it must also carry the label:
#
# metadata:
#   labels:
#     azure.workload.identity/use: "true"
###############################################################################
