###############################################################################
# AKS Image Integrity (Preview) — server-side signature verification.
# Uses Ratify + Azure Policy + Gatekeeper. This module provisions:
#   - the Ratify workload identity (UAMI + federated credential) that Ratify
#     uses to read the signing certificate from Key Vault and pull from ACR;
#   - the built-in Azure Policy initiative assignment that deploys Ratify and
#     audits image signatures.
# Docs: https://learn.microsoft.com/azure/aks/image-integrity
#
# NOTE: AKS Image Integrity is AUDIT-only by design. Unsigned images are flagged
# non-compliant in Azure Policy but are NOT blocked from running.
###############################################################################

# Built-in policy set definition ID for the Image Integrity initiative.
# "[Preview]: Use Image Integrity to ensure only trusted images are deployed"
locals {
  image_integrity_policy_set_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/af28bf8b-c669-4dd3-9137-1e68fdc61bd6"
  # The AKS Image Integrity preview installs Ratify with this fixed service
  # account in the gatekeeper-system namespace.
  ratify_service_account_subject = "system:serviceaccount:gatekeeper-system:ratify-admin"
}

resource "azurerm_user_assigned_identity" "ratify" {
  name                = "id-ratify-${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "ratify" {
  name                      = "ratify-fic"
  user_assigned_identity_id = azurerm_user_assigned_identity.ratify.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.oidc_issuer_url
  subject                   = local.ratify_service_account_subject
}

###############################################################################
# Azure Policy initiative assignment — deploys and configures Image Integrity.
# The assignment's system-assigned identity needs Contributor on the resource
# group so the policy remediation can enable the feature on the cluster.
###############################################################################
resource "azurerm_resource_group_policy_assignment" "image_integrity" {
  name                 = "image-integrity-${var.name_suffix}"
  resource_group_id    = var.resource_group_id
  policy_definition_id = local.image_integrity_policy_set_definition_id
  display_name         = "[Preview] Use Image Integrity — ${var.name_suffix}"
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "policy_remediation_contributor" {
  scope                            = var.resource_group_id
  role_definition_name             = "Contributor"
  principal_id                     = azurerm_resource_group_policy_assignment.image_integrity.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
  description                      = "Lets the Image Integrity policy assignment remediate the cluster to deploy Ratify."
}

resource "azurerm_resource_group_policy_remediation" "image_integrity" {
  name                           = "remediate-image-integrity-${var.name_suffix}"
  resource_group_id              = var.resource_group_id
  policy_assignment_id           = azurerm_resource_group_policy_assignment.image_integrity.id
  policy_definition_reference_id = "deployAKSImageIntegrity"

  depends_on = [azurerm_role_assignment.policy_remediation_contributor]
}
