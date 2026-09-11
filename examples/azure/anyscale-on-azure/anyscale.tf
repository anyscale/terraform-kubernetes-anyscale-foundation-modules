###############################################################################
# Anyscale Azure-managed control plane.
#
# Two Azure Resource Provider integrations turn the AKS cluster into an
# Anyscale-managed cloud:
#
#   1. `Anyscale.Platform/clouds` (+ `clouds/cloudResources`) — registers the
#      cloud with the Azure-hosted Anyscale control plane at
#      https://console.azure.anyscale.com and produces a stable `cldrsrc_…` ID.
#      Created NATIVELY via azapi (the awesome-aks demo's approach) rather
#      than through an ARM-template deployment wrapper — the cloud is a
#      first-class object in Terraform state, so create/destroy ordering
#      falls out of the dependency graph.
#
#   2. `Microsoft.KubernetesConfiguration/extensions` with extension type
#      `Anyscale.AKS.Operator` — installs the operator marketplace extension
#      into the cluster and wires it to the cloud above. The operator
#      authenticates to the control plane via Microsoft Entra workload
#      identity, NOT a CLI token.
###############################################################################

locals {
  anyscale_cloud_name   = coalesce(var.anyscale_cloud_name, "${var.aks_cluster_name}-cloud")
  anyscale_cloud_arm_id = "${azurerm_resource_group.rg.id}/providers/Anyscale.Platform/clouds/${local.anyscale_cloud_name}"

  # Common operator-side extension settings. The toleration defaults match
  # the node taints set by aks.tf for the ON_DEMAND CPU pool and GPU pools.
  anyscale_extension_configuration_defaults = {
    "workloads.accelerator.tolerations.default[0].key"      = "node.anyscale.com/accelerator-type"
    "workloads.accelerator.tolerations.default[0].value"    = "GPU"
    "workloads.accelerator.tolerations.default[0].effect"   = "NoSchedule"
    "workloads.accelerator.tolerations.default[1].key"      = "nvidia.com/gpu"
    "workloads.accelerator.tolerations.default[1].operator" = "Exists"
    "workloads.accelerator.tolerations.default[1].effect"   = "NoSchedule"
    "workloads.instanceTypes.enableDefaults"                = "true"
  }

  anyscale_extension_configuration_settings = merge(
    local.anyscale_extension_configuration_defaults,
    var.anyscale_platform.extension_configuration_settings,
  )
}

###############################################################################
# Step 0: onboard the subscription to the Anyscale.Platform resource provider.
#
# A subscription that has never used Anyscale.Platform needs two one-time
# things before Step 1 below can create the Anyscale.Platform/clouds resource:
# the RP registered, and its marketplace-style subscription agreement
# accepted. This mirrors the manual bootstrap:
#   az provider register --namespace Anyscale.Platform --subscription <sub>
#   az provider show --namespace Anyscale.Platform --subscription <sub> \
#     --query registrationState -o tsv   # repeat until "Registered"
#   az rest --method GET  --url ".../Anyscale.Platform/agreements/default?api-version=..."
#   az rest --method POST --url ".../Anyscale.Platform/agreements/default/accept?api-version=..."
#
# azurerm_resource_provider_registration (below) already polls internally
# until the RP shows "Registered" (its own built-in timeout is 2h), so no
# extra wait logic is needed for that half.
#
# The agreement half needs its own poll: POSTing /accept does not guarantee
# the subscription is immediately Active afterward (same class of eventual-
# consistency lag as the Entra principal-replication retries in
# terraform_data.anyscale_platform_self_grant below), so this checks current
# status, accepts only if needed, then polls GET until Active or timeout.
#
# Both steps are gated behind their own variables so you can skip either if
# your org handles them centrally or requires human sign-off.
#
# Accepting the agreement (var.accept_anyscale_platform_agreement, default
# true) means Terraform gives this consent on your behalf, non-interactively
# — see that variable's description for the full text and links (terms of
# use, privacy policy, Azure Marketplace billing/consent terms).
###############################################################################
resource "azurerm_resource_provider_registration" "anyscale_platform" {
  count = var.register_anyscale_resource_provider ? 1 : 0

  name = "Anyscale.Platform"
}

locals {
  anyscale_platform_agreement_base_url   = "https://management.azure.com/subscriptions/${var.azure_subscription_id}/providers/Anyscale.Platform/agreements/default"
  anyscale_platform_agreement_url        = "${local.anyscale_platform_agreement_base_url}?api-version=${var.anyscale_platform.agreements_api_version}"
  anyscale_platform_agreement_accept_url = "${local.anyscale_platform_agreement_base_url}/accept?api-version=${var.anyscale_platform.agreements_api_version}"
}

resource "terraform_data" "anyscale_platform_agreement_accept" {
  count = var.accept_anyscale_platform_agreement ? 1 : 0

  triggers_replace = {
    url = local.anyscale_platform_agreement_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      GET_URL="${local.anyscale_platform_agreement_url}"
      ACCEPT_URL="${local.anyscale_platform_agreement_accept_url}"

      status="$(az rest --method GET --url "$GET_URL" --query properties.status -o tsv 2>/dev/null || echo "")"
      echo "[anyscale] Agreement status: $${status:-<none>}"

      if [ "$status" != "Active" ]; then
        echo "[anyscale] Accepting Anyscale.Platform subscription agreement..."
        az rest --method POST --url "$ACCEPT_URL" >/dev/null
      fi

      deadline=$(( $(date +%s) + 300 ))
      while :; do
        status="$(az rest --method GET --url "$GET_URL" --query properties.status -o tsv 2>/dev/null || echo "")"
        if [ "$status" = "Active" ]; then
          echo "[anyscale] Agreement is Active."
          break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "[anyscale] ERROR: agreement did not reach Active within timeout (last status: $${status:-<none>})" >&2
          exit 1
        fi
        echo "[anyscale] Waiting for agreement to reach Active (current: $${status:-<none>})..."
        sleep 10
      done
    EOT
  }

  depends_on = [azurerm_resource_provider_registration.anyscale_platform]
}

# Read the agreement's current status, for the output below and as the
# fail-fast backstop feeding the precondition on the cloud resource — which
# is what catches accept_anyscale_platform_agreement=false on a subscription
# where the agreement was never accepted out-of-band.
#
# This deliberately shells out instead of using a `data "azapi_resource"`:
# on a subscription that has never accepted the agreement, GET
# .../Anyscale.Platform/agreements/default returns
# `422 Unprocessable Entity / ResourceReadFailed` rather than 404, which a
# data source surfaces as a hard "Failed to retrieve resource" error and
# aborts the run before the accept step can do anything about it — and
# before the precondition can render its message. Here a failed read is
# simply reported as an empty status.
data "external" "anyscale_platform_agreement" {
  program = ["/bin/bash", "-c", <<-EOT
    status="$(az rest --method GET --url "${local.anyscale_platform_agreement_url}" --query properties.status -o tsv 2>/dev/null || true)"
    printf '{"status":"%s"}\n' "$${status:-}"
  EOT
  ]

  depends_on = [
    azurerm_resource_provider_registration.anyscale_platform,
    terraform_data.anyscale_platform_agreement_accept,
  ]
}

###############################################################################
# Step 1a: the Anyscale.Platform/clouds resource.
###############################################################################
resource "azapi_resource" "anyscale_cloud" {
  type      = "Anyscale.Platform/clouds@${var.anyscale_platform.clouds_api_version}"
  parent_id = azurerm_resource_group.rg.id
  location  = azurerm_resource_group.rg.location
  name      = local.anyscale_cloud_name

  # required while the azapi local schema catalog lags the preview API version
  schema_validation_enabled = false

  body = {
    properties = var.enable_acr ? {
      acrResourceId = azurerm_container_registry.acr[0].id
    } : {}
  }

  tags = merge(var.tags, { "anyscale-cloud" = local.anyscale_cloud_name })

  response_export_values = [
    "properties.ssoUrl",
  ]

  # Gate cloud registration on an accepted Anyscale agreement. Fails the apply
  # up front with an actionable message rather than letting the RP reject the
  # cloud PUT with an opaque error. Reached when the agreement was never
  # accepted and accept_anyscale_platform_agreement is false.
  lifecycle {
    precondition {
      condition     = try(data.external.anyscale_platform_agreement.result.status, "") == "Active"
      error_message = <<-EOT
        The Anyscale.Platform agreement for subscription ${var.azure_subscription_id} is not Active.

        Either set accept_anyscale_platform_agreement = true to have Terraform
        accept it, or accept it out-of-band first:
          az rest --method POST --url "${local.anyscale_platform_agreement_accept_url}"
      EOT
    }
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    data.external.anyscale_platform_agreement,
  ]
}

###############################################################################
# Step 1b: the cloudResources child — binds the cloud to this deployment's
# storage (as ADLS Gen2 via abfss://) and the operator's managed identity.
###############################################################################
resource "azapi_resource" "anyscale_cloud_resource" {
  type      = "Anyscale.Platform/clouds/cloudResources@${var.anyscale_platform.clouds_api_version}"
  parent_id = azapi_resource.anyscale_cloud.id
  location  = azurerm_resource_group.rg.location
  name      = "default"

  schema_validation_enabled = false

  body = {
    properties = {
      provider                    = "Azure"
      computeStack                = "K8S"
      cloudStorageBucketEndpoint  = azurerm_storage_account.sa.primary_blob_endpoint
      cloudStorageBucketName      = "abfss://${azurerm_storage_container.blob.name}@${azurerm_storage_account.sa.primary_dfs_host}"
      anyscaleOperatorIamIdentity = azurerm_user_assigned_identity.anyscale_operator.principal_id
    }
  }

  tags = merge(var.tags, { "anyscale-cloud" = local.anyscale_cloud_name })

  response_export_values = [
    "properties.cloudResourceId",
  ]

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_role_assignment.anyscale_blob_contrib,
    azurerm_federated_identity_credential.anyscale_operator_fic,
  ]
}

# The cloudResources child exports `cloudResourceId` (e.g. `cldrsrc_abcd…`).
# The Anyscale operator names its TLS Secret resources — and this stack names
# the gateway's public DNS label — using the hyphenated form of this ID.
locals {
  anyscale_cloud_resource_id            = azapi_resource.anyscale_cloud_resource.output.properties.cloudResourceId
  anyscale_cloud_resource_id_hyphenated = replace(local.anyscale_cloud_resource_id, "_", "-")

  anyscale_gateway_certificate_secret_name         = "anyscale-${local.anyscale_cloud_resource_id_hyphenated}-certificate"
  anyscale_gateway_service_certificate_secret_name = "anyscale-svc-${local.anyscale_cloud_resource_id_hyphenated}-certificate"
}

###############################################################################
# Team access: "Anyscale Platform Contributor" on the cloud resource.
#
# Azure subscription Owner/Contributor does NOT grant the ability to create
# Anyscale workspaces/jobs/services — that requires this Anyscale-provider
# role assigned ON the Anyscale.Platform/clouds resource itself. Optional:
# populate var.anyscale_platform_contributors to assign it from Terraform,
# or do it later via the portal (cloud resource > Access control (IAM)).
#
# NOTE: "Anyscale Platform Contributor" is a role definition published by the
# Anyscale.Platform RP and resolved by name at the cloud scope. If name
# resolution ever fails in your tenant, swap role_definition_name for
# role_definition_id with the role's full definition ID.
###############################################################################
resource "azurerm_role_assignment" "anyscale_platform_contributor" {
  for_each = { for c in var.anyscale_platform_contributors : c.principal_id => c }

  scope = azapi_resource.anyscale_cloud.id
  # Exact role definition name published by the Anyscale.Platform RP — note the
  # trailing "Role" (the portal label drops it, but the role definition keeps it).
  # Other options: "Anyscale Platform Administrator Role", "Anyscale Platform Reader Role".
  role_definition_name = "Anyscale Platform Contributor Role"
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
}

###############################################################################
# Self-grant: give the principal running Terraform (the signed-in `az` user)
# both the Contributor and Reader platform roles on the cloud resource.
#
# Subscription Owner/Contributor does NOT carry over to the Anyscale RP, so the
# operator running the deploy still can't open the cloud in the console or
# create workspaces/jobs/services until these are assigned.
#
# Implemented as a local-exec so "whoever is running the apply" gets access
# without having to look up their own object ID first. Trade-off: not tracked
# in state and not removed on destroy (the assignments disappear with the
# cloud resource anyway). Authentication reuses the same `az login` Terraform
# already depends on.
#
# `az role assignment create` is idempotent (re-running returns the existing
# assignment), and we retry briefly to ride out Entra principal-replication lag.
###############################################################################
resource "terraform_data" "anyscale_platform_self_grant" {
  count = var.assign_current_user_platform_roles ? 1 : 0

  triggers_replace = {
    cloud_arm_id = local.anyscale_cloud_arm_id
    subscription = var.azure_subscription_id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      az account set --subscription "${var.azure_subscription_id}"
      ASSIGNEE="$(az ad signed-in-user show --query id -o tsv)"
      SCOPE="${local.anyscale_cloud_arm_id}"
      for ROLE in "Anyscale Platform Contributor Role" "Anyscale Platform Reader Role"; do
        echo "[anyscale] Granting '$ROLE' to $ASSIGNEE on $SCOPE"
        for attempt in 1 2 3 4 5; do
          if az role assignment create \
              --assignee "$ASSIGNEE" \
              --role "$ROLE" \
              --scope "$SCOPE" \
              --only-show-errors >/dev/null; then
            break
          fi
          if [ "$attempt" -eq 5 ]; then
            echo "[anyscale] ERROR: failed to assign '$ROLE' after $attempt attempts" >&2
            exit 1
          fi
          echo "[anyscale] assign '$ROLE' attempt $attempt failed (principal replication?); retrying in 15s..."
          sleep 15
        done
      done
      echo "[anyscale] Platform role grants complete."
    EOT
  }

  depends_on = [azapi_resource.anyscale_cloud]
}

###############################################################################
# Step 2: install the Anyscale.AKS.Operator marketplace extension.
#
# The gateway hostname is DETERMINISTIC on the public path — a DNS label
# derived from the cloud resource ID is stamped onto the gateway LB service
# (see gateway.tf), so `networking.gateway.hostname` is computable at plan
# time and no `az k8s-extension update` follow-up (or LB polling) is needed.
#
# IMPORTANT: configuration_protected_settings explicitly sets the CLI token
# to the empty string. Omitting the key entirely is NOT enough — the AKS
# extension PATCH semantics treat a missing key as "leave previous value in
# place", so any earlier value would persist in the Helm release. With this
# field forced empty, the operator falls through to the Microsoft Entra
# workload-identity exchange (UAMI federated to the AKS OIDC issuer,
# registered as the cloud's operator principal by the cloudResources child).
###############################################################################
resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = var.install_operator_extension ? 1 : 0

  name              = var.anyscale_platform.extension_resource_name
  cluster_id        = azurerm_kubernetes_cluster.aks.id
  extension_type    = "Anyscale.AKS.Operator"
  release_train     = var.anyscale_platform.release_train
  release_namespace = var.anyscale_operator_namespace

  plan {
    name      = var.anyscale_platform.plan_name
    publisher = var.anyscale_platform.plan_publisher
    product   = var.anyscale_platform.plan_product
  }

  configuration_settings = merge(
    {
      "global.cloudDeploymentId"      = local.anyscale_cloud_resource_id
      "global.controlPlaneURL"        = var.anyscale_platform.control_plane_url
      "global.auth.iamIdentity"       = azurerm_user_assigned_identity.anyscale_operator.client_id
      "global.auth.audience"          = var.anyscale_platform.auth_audience
      "workloads.serviceAccount.name" = var.anyscale_operator_serviceaccount

      # Envoy Gateway integration — these come from gateway.tf.
      "networking.gateway.enabled"    = "true"
      "networking.gateway.name"       = var.envoy_gateway.gateway_name
      "networking.gateway.className"  = var.envoy_gateway.gateway_class_name
      "networking.gateway.namespace"  = var.anyscale_operator_namespace
      "networking.gateway.apiVersion" = "gateway.networking.k8s.io/v1"
      "networking.gateway.hostname"   = local.gateway_hostname
    },
    local.anyscale_extension_configuration_settings,
  )

  configuration_protected_settings = {
    "global.auth.anyscaleCliToken" = ""
  }

  depends_on = [
    azapi_resource.anyscale_cloud_resource,
    azurerm_federated_identity_credential.anyscale_operator_fic,
    kubectl_manifest.gateway,
  ]
}

###############################################################################
# Destroy ordering: delete the Anyscale cloud BEFORE the operator extension
# and the AKS cluster.
#
# WHY THIS EXISTS even with native azapi cloud resources: Terraform's destroy
# order is the reverse of the dependency graph, so the extension (which
# depends on the cloud) would be uninstalled FIRST — and with the operator
# gone, the Anyscale control plane rejects the cloud delete with a 409
# ("has N associated Clusters that are still active") until its bookkeeping
# drains, wedging the destroy.
#
# Because this resource depends_on the AKS cluster, the extension AND the
# cloud resources, Terraform destroys it before all of them (running the
# when=destroy provisioner). The operator is therefore still alive to drain
# its sessions while the cloud is deleted via the CLI. The subsequent azapi
# destroys of the already-deleted cloud resources are no-ops (ARM returns
# 204 for DELETE on a nonexistent resource).
#
# The provisioner deletes the cloudResources/default child first (the parent
# cannot be removed while nested resources exist), then the cloud itself,
# retrying until the control plane finishes draining or the timeout elapses.
# Authentication uses the same `az` login Terraform already relies on.
###############################################################################
resource "terraform_data" "anyscale_cloud_predelete" {
  input = {
    cloud_arm_id    = local.anyscale_cloud_arm_id
    timeout_seconds = 900
    poll_interval   = 20
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      CLOUD="${self.input.cloud_arm_id}"
      echo "[anyscale] Deleting Anyscale cloud before AKS teardown: $CLOUD"
      deadline=$(( $(date +%s) + ${self.input.timeout_seconds} ))
      err="$(mktemp)"
      while :; do
        # Child must go before the parent cloud resource.
        az resource delete --ids "$CLOUD/cloudResources/default" --only-show-errors >/dev/null 2>&1 || true
        if az resource delete --ids "$CLOUD" --only-show-errors >/dev/null 2>"$err"; then
          echo "[anyscale] Cloud deleted."
          break
        fi
        if grep -qiE "not.?found|does not exist|could not be found" "$err"; then
          echo "[anyscale] Cloud already gone."
          break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "[anyscale] ERROR: timed out deleting cloud after ${self.input.timeout_seconds}s" >&2
          cat "$err" >&2
          exit 1
        fi
        echo "[anyscale] Cloud delete pending (control plane draining sessions); retry in ${self.input.poll_interval}s..."
        sleep ${self.input.poll_interval}
      done
    EOT
  }

  # depends_on makes Terraform destroy THIS resource (running the hook) before
  # the extension, the cloud resources, and the cluster — keeping the operator
  # alive during the cloud delete.
  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_extension.anyscale_operator,
    azapi_resource.anyscale_cloud,
    azapi_resource.anyscale_cloud_resource,
  ]
}
