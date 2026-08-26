###############################################################################
# Anyscale Azure-managed control plane.
#
# This file is the only thing that materially distinguishes this example from
# `examples/azure/aks-new_cluster` — it adds the two Azure Resource Providers
# that turn the underlying AKS cluster into an Anyscale-managed cloud:
#
#   1. `Anyscale.Platform/clouds` (via AzAPI) — registers the cloud with the
#      Azure-hosted Anyscale control plane at https://console.azure.anyscale.com
#      and produces a stable `cldrsrc_…` resource ID.
#
#   2. `Microsoft.KubernetesConfiguration/extensions` with extension type
#      `Anyscale.AKS.Operator` — installs the operator marketplace extension
#      into the AKS cluster's `anyscale-operator` namespace and wires it to
#      the cloud above. The operator authenticates to the control plane via
#      Microsoft Entra workload identity, NOT a CLI token.
###############################################################################

locals {
  anyscale_cloud_name = coalesce(var.anyscale_cloud_name, "${var.aks_cluster_name}-cloud")

  # ARM resource ID of the Anyscale.Platform/clouds resource the deployment
  # below creates. Used by the destroy-ordering hook so the cloud is removed
  # before the AKS cluster (see terraform_data.anyscale_cloud_predelete).
  anyscale_cloud_arm_id = "${local.rg_id}/providers/Anyscale.Platform/clouds/${local.anyscale_cloud_name}"

  anyscale_deployments = {
    top_level    = "dep-anyscale-${var.aks_cluster_name}"
    blob         = "dep-anyblob-${var.aks_cluster_name}"
    fic          = "dep-anyfic-${var.aks_cluster_name}"
    storage_rbac = "dep-anystoragerbac-${var.aks_cluster_name}"
    acr_rbac     = "dep-anyacrrbac-${var.aks_cluster_name}"
  }

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

  anyscale_extension_release_train = contains(["stable", "preview"], lower(var.anyscale_platform.release_train)) ? title(lower(var.anyscale_platform.release_train)) : var.anyscale_platform.release_train
}

###############################################################################
# Step 0: onboard the subscription to the Anyscale.Platform resource provider.
#
# A subscription that has never used Anyscale.Platform needs two one-time
# things before Step 1 below can deploy the Anyscale.Platform/clouds ARM
# resource: the RP registered, and its marketplace-style subscription
# agreement accepted. This mirrors the manual bootstrap:
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
# status, accepts only if needed, then polls GET until Active or timeout —
# mirroring the manual steps exactly:
#   az rest --method GET  --url ".../Anyscale.Platform/agreements/default?api-version=..."
#   az rest --method POST --url ".../Anyscale.Platform/agreements/default/accept?api-version=..."
#   az rest --method GET  --url ".../Anyscale.Platform/agreements/default?api-version=..." # repeat until status: Active
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
  anyscale_platform_agreement_url        = "${local.anyscale_platform_agreement_base_url}?api-version=${var.anyscale_platform.agreement_api_version}"
  anyscale_platform_agreement_accept_url = "${local.anyscale_platform_agreement_base_url}/accept?api-version=${var.anyscale_platform.agreement_api_version}"
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

# Read the agreement's current status for the output below and as a
# fail-fast backstop (lifecycle.precondition on the cloud resource) in case
# accept_anyscale_platform_agreement=false and the agreement was never
# accepted out-of-band, or the poll above somehow didn't run.
#
# This deliberately shells out instead of using a `data "azapi_resource"`:
# on a subscription that has never accepted the agreement, GET
# .../Anyscale.Platform/agreements/default returns
# `422 Unprocessable Entity / ResourceReadFailed` rather than 404, which a
# data source surfaces as a hard "Failed to retrieve resource" error and
# aborts the run before the accept step can do anything about it. Here a
# failed read is simply reported as an empty status.
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
# Step 1: deploy the Anyscale.Platform/clouds ARM resource.
# The body of the template is the exact JSON the Azure portal exports for the
# managed cloud onboarding flow — see `templates/anyscale-platform-cloud.template.json`.
# Storage and identity are passed as `existing` so the template binds to the
# resources aks.tf created rather than provisioning new ones.
###############################################################################
resource "azapi_resource" "anyscale_platform" {
  type                      = "Microsoft.Resources/deployments@2022-09-01"
  name                      = local.anyscale_deployments.top_level
  parent_id                 = local.rg_id
  schema_validation_enabled = false
  response_export_values = {
    cloud_deployment_id = "properties.outputs.cloudResourceId.value"
    provisioning_state  = "properties.provisioningState"
  }
  body = {
    properties = {
      mode     = "Incremental"
      template = jsondecode(file("${path.module}/templates/anyscale-platform-cloud.template.json"))
      parameters = {
        location                 = { value = local.rg_location }
        cloudName                = { value = local.anyscale_cloud_name }
        storageAccountName       = { value = azurerm_storage_account.sa[0].name }
        storageMode              = { value = "existing" }
        storageAccountResourceId = { value = azurerm_storage_account.sa[0].id }
        storageContainerName     = { value = azurerm_storage_container.blob[0].name }
        workloadIdentityName     = { value = azurerm_user_assigned_identity.anyscale_operator[0].name }
        identityMode             = { value = "existing" }
        identityResourceId       = { value = azurerm_user_assigned_identity.anyscale_operator[0].id }
        tagsByResource           = { value = var.anyscale_platform.tags_by_resource }
        acrMode                  = { value = var.enable_acr ? "existing" : "none" }
        acrName                  = { value = var.enable_acr ? azurerm_container_registry.acr[0].name : "" }
        acrResourceId            = { value = var.enable_acr ? azurerm_container_registry.acr[0].id : "" }
        aksKubeletPrincipalId    = { value = local.aks_kubelet_object_id }
        # Terraform owns the kubelet AcrPull assignment (acr.tf). Tell the
        # ARM template not to create a duplicate one.
        manageAksKubeletAcrPullRoleAssignment = { value = false }
        storageBlobServiceDeploymentName      = { value = local.anyscale_deployments.blob }
        federatedIdentityDeploymentName       = { value = local.anyscale_deployments.fic }
        storageRoleAssignmentDeploymentName   = { value = local.anyscale_deployments.storage_rbac }
        acrRoleAssignmentsDeploymentName      = { value = local.anyscale_deployments.acr_rbac }
      }
    }
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_storage_container.blob,
    azurerm_user_assigned_identity.anyscale_operator,
    azurerm_federated_identity_credential.anyscale_operator_fic,
    azurerm_role_assignment.anyscale_blob_contrib,
    azurerm_container_registry.acr,
    azurerm_role_assignment.kubelet_acr_pull,
    azurerm_resource_provider_registration.anyscale_platform,
    terraform_data.anyscale_platform_agreement_accept,
    data.external.anyscale_platform_agreement,
  ]

  lifecycle {
    precondition {
      # When accept_anyscale_platform_agreement=true the accept-and-poll step
      # above is authoritative: it fails the apply unless the agreement
      # reached Active. This check is the backstop for the opt-out path, and
      # tolerates an unreadable status only in that authoritative case.
      condition     = var.accept_anyscale_platform_agreement || try(data.external.anyscale_platform_agreement.result.status, "") == "Active"
      error_message = "The Anyscale.Platform subscription agreement is not Active (or its status could not be read with the Azure CLI). Accept it (az rest --method POST --url \"${local.anyscale_platform_agreement_accept_url}\") or set accept_anyscale_platform_agreement=true, then re-apply."
    }
  }
}

# The ARM template exports `cloudResourceId` (e.g. `cldrsrc_abcd…`). The
# Anyscale operator names its TLS Secret resources using the hyphenated form
# of this ID, so we keep both available for downstream use.
locals {
  anyscale_cloud_resource_id            = azapi_resource.anyscale_platform.output.cloud_deployment_id
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

  scope = local.anyscale_cloud_arm_id
  # Exact role definition name published by the Anyscale.Platform RP — note the
  # trailing "Role" (the portal label drops it, but the role definition keeps it).
  # Other options: "Anyscale Platform Administrator Role", "Anyscale Platform Reader Role".
  role_definition_name = "Anyscale Platform Contributor Role"
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type

  depends_on = [azapi_resource.anyscale_platform]
}

###############################################################################
# Self-grant: give the principal running Terraform (the signed-in `az` user)
# both the Contributor and Reader platform roles on the cloud resource.
#
# Subscription Owner/Contributor does NOT carry over to the Anyscale RP, so the
# operator running the deploy still can't open the cloud in the console or
# create workspaces/jobs/services until these are assigned. The native
# azurerm_role_assignment above covers explicitly-listed principals; this hook
# covers "whoever is running the apply" without them having to look up their own
# object ID first.
#
# Implemented as a local-exec (rather than azurerm_role_assignment) at the
# user's request — it runs the exact `az role assignment create` calls during
# apply. Trade-off: not tracked in state and not removed on destroy (the
# assignments disappear with the cloud resource anyway). Authentication reuses
# the same `az login` Terraform already depends on.
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

  depends_on = [azapi_resource.anyscale_platform]
}

###############################################################################
# Step 2: install the Anyscale.AKS.Operator marketplace extension.
#
# Gated by var.install_operator_extension (default true). Set it to false to
# skip this and install the Anyscale operator manually via `helm install`
# instead — see the example README for the manual Helm values, which need to
# set networking.gateway explicitly since that config normally comes from
# this resource's configuration_settings below.
#
# The extension is installed AFTER the Envoy Gateway has an LB address
# (see envoy-gateway.tf) so we can bake the gateway hostname directly into
# the operator's configuration_settings. This avoids the
# `az k8s-extension update ...` step the Anyscale quickstart documents.
#
# IMPORTANT: configuration_protected_settings explicitly sets the CLI token
# to the empty string. Omitting the key entirely is NOT enough — the AKS
# extension PATCH semantics treat a missing key as "leave previous value in
# place", so any earlier value would persist in the Helm release. With this
# field forced empty, the operator falls through to the Microsoft Entra
# workload-identity exchange (UAMI federated to the AKS OIDC issuer,
# registered as the cloud's operator principal by the ARM template above).
###############################################################################
resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  count = var.install_operator_extension ? 1 : 0

  name              = var.anyscale_platform.extension_resource_name
  cluster_id        = local.aks_id
  extension_type    = "Anyscale.AKS.Operator"
  release_train     = local.anyscale_extension_release_train
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
      "global.auth.iamIdentity"       = azurerm_user_assigned_identity.anyscale_operator[0].client_id
      "global.auth.audience"          = var.anyscale_platform.auth_audience
      "workloads.serviceAccount.name" = var.anyscale_operator_serviceaccount

      # Envoy Gateway integration — these come from envoy-gateway.tf.
      "networking.gateway.enabled"    = "true"
      "networking.gateway.name"       = var.envoy_gateway.gateway_name
      "networking.gateway.className"  = var.envoy_gateway.gateway_class_name
      "networking.gateway.namespace"  = var.anyscale_operator_namespace
      "networking.gateway.apiVersion" = "gateway.networking.k8s.io/v1"
      "networking.gateway.hostname"   = data.external.gateway_lb.result.address
    },
    local.anyscale_extension_configuration_settings,
  )

  configuration_protected_settings = {
    "global.auth.anyscaleCliToken" = ""
  }

  depends_on = [
    azapi_resource.anyscale_platform,
    data.external.gateway_lb,
    kubectl_manifest.gateway,
  ]
}

###############################################################################
# Destroy ordering: delete the Anyscale cloud BEFORE the AKS cluster.
#
# WHY THIS EXISTS
# azapi_resource.anyscale_platform is a Microsoft.Resources/deployments record.
# Destroying it removes the deployment bookkeeping but NOT the
# Anyscale.Platform/clouds resource it created. Left to its own devices,
# Terraform would tear down AKS + the operator extension while the cloud
# resource still lives, and the cloud would only be removed later by the
# resource-group cascade — at which point the operator is already gone and the
# Anyscale control plane rejects the cloud delete with a 409 ("has N
# associated Clusters that are still active"), wedging the whole resource
# group in a Deleting state.
#
# This resource forces the correct order. Because it depends_on the AKS
# cluster AND the operator extension, Terraform destroys it FIRST (running the
# when=destroy provisioner) and only then tears down the extension and the
# cluster. The operator is therefore still alive to drain its sessions while
# the cloud is being deleted.
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
  # the extension and the cluster — keeping the operator alive during the
  # cloud delete.
  depends_on = [
    azurerm_kubernetes_cluster.aks,
    azurerm_kubernetes_cluster_extension.anyscale_operator,
    azapi_resource.anyscale_platform,
  ]
}

###############################################################################
# Manual Helm install support (install_operator_extension = false).
#
# When Terraform does not install the marketplace extension, the operator has
# to be installed by hand — and every value it needs is something this apply
# just produced (the cloud's cldrsrc_ ID, the workload identity's client ID,
# the Envoy Gateway LB address). Transcribing those into a values.yaml by hand
# is the step people get wrong, so write the file out instead.
#
# The nested structure below mirrors the flat dotted configuration_settings on
# azurerm_kubernetes_cluster_extension.anyscale_operator above. Keep the two in
# sync: anything added there that the operator needs at install time has to be
# added here as well.
#
# Two values are easy to miss when hand-writing this file, and both are here:
#
#   global.auth.anyscaleCliToken   Must be present and empty so the operator
#                                  uses the Microsoft Entra workload-identity
#                                  exchange rather than CLI-token auth.
#   networking.gateway             Normally baked in by the extension from the
#                                  gateway LB address; nothing else tells the
#                                  operator where the Gateway is.
#
# Note: overrides supplied through anyscale_platform.extension_configuration_
# settings apply to the EXTENSION path only — they are flat dotted keys and are
# not merged into this file. Edit the generated file if you need them here.
###############################################################################
locals {
  anyscale_operator_helm_values = {
    global = {
      cloudDeploymentId = local.anyscale_cloud_resource_id
      cloudProvider     = "azure"
      controlPlaneURL   = var.anyscale_platform.control_plane_url
      auth = {
        iamIdentity      = azurerm_user_assigned_identity.anyscale_operator[0].client_id
        audience         = var.anyscale_platform.auth_audience
        anyscaleCliToken = ""
      }
    }
    workloads = {
      serviceAccount = { name = var.anyscale_operator_serviceaccount }
      instanceTypes  = { enableDefaults = true }
      accelerator = {
        # Matches the taints aks.tf puts on the GPU pools.
        tolerations = {
          default = [
            { key = "node.anyscale.com/accelerator-type", value = "GPU", effect = "NoSchedule" },
            { key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule" },
          ]
        }
      }
    }
    networking = {
      gateway = {
        enabled    = true
        name       = var.envoy_gateway.gateway_name
        className  = var.envoy_gateway.gateway_class_name
        namespace  = var.anyscale_operator_namespace
        apiVersion = "gateway.networking.k8s.io/v1"
        hostname   = data.external.gateway_lb.result.address
      }
    }
  }

  # Terraform already created the namespace unless create_operator_namespace
  # is false, so only ask Helm to create it when it actually has to.
  anyscale_operator_helm_command = join(" ", compact([
    "helm install ${local.anyscale_cloud_name} anyscale/anyscale-operator",
    "--namespace ${var.anyscale_operator_namespace}",
    var.create_operator_namespace ? "" : "--create-namespace",
    "--values anyscale-operator-values.yaml",
    "--wait",
  ]))
}

resource "local_file" "anyscale_operator_values" {
  count = var.install_operator_extension ? 0 : 1

  filename        = "${path.module}/anyscale-operator-values.yaml"
  file_permission = "0600"
  content         = yamlencode(local.anyscale_operator_helm_values)
}
