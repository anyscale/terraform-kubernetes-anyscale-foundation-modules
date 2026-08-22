# Implementation Notes

This file keeps the implementation facts behind the main [README](../../README.md). It combines the current-state notes and the local Anyscale on Azure public-preview knowledge base used to build this sample.

## Validated Reference State

- The Azure side of the deployment creates the private network, private AKS cluster, Bastion path, storage, registry, routing, identity, observability resources, and Azure-native Anyscale platform resources from Terraform.
- The deployment runs in two phases: foundation first, then a Bastion-backed pass that gives Terraform live Kubernetes access for the bootstrap layer and Anyscale platform resources.
- The AKS cluster defaults to an enterprise posture: local cluster admin accounts are disabled, Microsoft Defender for Containers is enabled, and the Key Vault Secrets Provider add-on is enabled. Operators should use Entra-backed admin access and only opt out for a documented break-glass requirement.
- The Terraform-managed bootstrap layer prepares namespaces, service-account adoption metadata, workload identity wiring, private Anyscale Gateway resources using `gatewayClassName: approuting-istio`, and the NVIDIA device plugin before the extension-managed operator path is exercised.
- The Anyscale AKS extension must receive `networking.gateway.*` settings that point at the `approuting-istio` Gateway. Without those settings, the operator can emit legacy `Ingress` objects instead of Gateway API `HTTPRoute` resources, leaving workspaces stuck in `STARTING` even when Ray pods are healthy.
- The deployment baseline verifies the Azure cloud endpoint certificate during deploy, so the docs should center on the current Gateway API and TLS lifecycle.
- Private workspace and service URLs surface under `*.azure.anyscaleuserdata.com`; use the in-VNet jump host or the Bastion-backed browser helpers when testing those hostnames.
- A complete workload proof should emit the CPU Ray, GPU Ray, CPU build-job, GPU train-job, and GPU Serve service proof markers from the private AKS path.

## Operational Assumptions

- Treat local access to the private cluster as Bastion-first for `kubectl`, Helm, validation helpers, and post-deploy Anyscale tasks.
- Treat private workspace and service HTTP(S) access as Gateway-backed data-plane traffic. Use the in-VNet jump host or the Bastion-backed browser helpers when testing private hostnames.
- The bootstrap path now labels the operator and GPU namespaces with Pod Security Admission baseline labels so the sample starts from a more restrictive runtime posture without requiring a custom privileged workload profile.
- The bootstrap path now also applies a conservative NetworkPolicy baseline to those namespaces: ingress is denied by default, same-namespace ingress is allowed, and egress to DNS and same-namespace pods is allowed. Add workload-specific allow-rules as new services or dependencies are introduced.
- The bootstrap path now applies namespace-level resource guardrails as well: a default LimitRange sets sane CPU and memory defaults, and a ResourceQuota caps aggregate namespace consumption so accidental oversubscription is easier to detect and contain.
- When troubleshooting pod startup or admission failures, inspect the namespace labels and the pod events together: `kubectl get ns <namespace> --show-labels` and `kubectl describe pod <name> -n <namespace>` are the first checks after a failed schedule or admission event. Baseline enforcement can block privileged or host-exposed workloads even when the image itself is otherwise healthy.
- Prefer Entra-backed AKS administration over local cluster accounts. If a temporary exception is required, set the AKS Terraform inputs for local accounts, Defender, and Key Vault Secrets Provider explicitly before apply.
- In private mode, local direct curls to `*.s.azure.anyscaleuserdata.com` can time out from an unrouted workstation while the same service succeeds from an AKS pod. Keep the harness's in-cluster service probe fallback as the source of truth unless the request originates from inside the VNet (jump host) with private DNS.
- Keep the CPU pool schedulable for operator components and supporting system workloads.
- Keep GPU pools tainted and rely on explicit selectors and tolerations for GPU workloads.
- Allow the documented Microsoft, marketplace, container registry, NVIDIA, and Anyscale egress endpoints through Azure Firewall so cluster bootstrap and notebook workloads can succeed.
- Remember that local `anyscale job submit --working-dir` uploads through the submitter machine first; private Blob and DFS storage require private DNS and network reachability from that machine, not only from AKS workloads.

## Supporting Notes

- The primary Anyscale TLS secret is expected after cloud and operator setup; the service TLS secret is expected only after an Anyscale service is deployed. Normalize underscores in the cloud deployment ID to hyphens for both Kubernetes secret names.
- The service HTTPS Gateway listener should be enabled only after the service TLS secret exists. The default Gateway listeners are `http` and `https`.
- When a workload pod reaches `Pending` or `CrashLoopBackOff`, check the namespace baseline first, then the pod's `securityContext`, `seccompProfile`, and required capabilities. The current sample intentionally uses the baseline profile rather than a privileged profile so pod admission failures will surface as policy violations rather than silent runtime drift.
- Private Anyscale job logs may need workspace-side retrieval because Blob-backed log URLs are private to the workspace network.
- If you capture local validation transcripts while iterating, keep them under `.cache/` so they remain local-only artifacts instead of repository content.

## Public Preview Source Docs

Reference links used by the sample:

- [Overview](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/overview)
- [Quickstart with Envoy Gateway](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/quickstart-azure-cli-gateway-envoy)
- [Quickstart with ingress-nginx](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/quickstart-azure-cli-ingress-nginx)
- [Architecture](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/architecture)
- [Networking](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/networking)
- [Identity and access](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/identity-access)
- [Configure container image builds](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/configure-container-image-builds)
- [Support model](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/support-model)
- [Supported regions](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/supported-regions)
- [FAQ](https://learn.microsoft.com/en-us/azure/anyscale-on-azure/faq)

## Public Preview Status

- Anyscale on Azure is an Azure Native Integration for running Ray workloads on AKS.
- The control plane is hosted and operated by Anyscale in Azure; the data plane runs in the customer's Azure subscription on AKS.
- Preview has no Azure preview SLA and may have constrained features.
- During preview, Anyscale on Azure is available only in selected regions.
- Cloud creation and deletion are managed through the Azure portal and the Anyscale Clouds Resource Provider, not the Anyscale CLI cloud setup/register/delete flows.
- Public preview limitations include AKS-only deployments, no VM-stack or Anyscale-hosted clouds, limited multi-resource cloud support, and unsupported workload CLI commands such as `anyscale workspace_v2 ssh`, `anyscale workspace_v2 pull`, and `anyscale image archive`.
- Unsupported Anyscale features during preview include machine pools, Global Resource Scheduler, lineage tracking, job queues, and several console org settings such as billing, budgets, resource notifications, and cost analysis.
- The preview docs list Services as an unsupported console feature, but Ray Serve services deployed through the Anyscale CLI do work on this sample's Gateway API path; the `GPU_SERVE_SERVICE_PROOF_OK` marker exercises exactly that. Treat Services as functional-but-unsupported during preview, and expect console-side service management to be limited.

## Anyscale On Azure Architecture

- Control plane: Anyscale console at `console.azure.anyscale.com`, scheduling/job APIs, monitoring/log aggregation, metrics dashboard, and cloud/cluster lifecycle management.
- Data plane: customer-owned AKS cluster, Anyscale Kubernetes operator, Ray clusters, Azure Blob Storage or ADLS, optional ACR, and Azure Load Balancer.
- The control plane does not directly access AKS nodes or customer data. The operator polls outbound for instructions and reports health/telemetry back to the control plane.
- The Azure portal installs the Anyscale operator into AKS during cloud creation.
- Anyscale cloud resources represent AKS clusters. Multi-resource clouds are possible, but preview guidance recommends using the default cloud resource for each cloud.

## Required Setup Prerequisites

- Azure subscription with Owner, or Contributor plus User Access Administrator, for setup.
- Permission to create service principals from external Microsoft Entra tenants.
- Enrollment in the Anyscale on Azure Public Preview through Anyscale support with subscription ID and requested regions.
- Local tools: Azure CLI, `kubectl`, Helm, and Anyscale CLI.
- Create the Anyscale service principal once per tenant with app ID `086bc555-6989-4362-ba30-fded273e432b`.
- Register resource providers: `Microsoft.Storage`, `Microsoft.ManagedIdentity`, `Microsoft.Authorization`, `Microsoft.Resources`, `Microsoft.Network`, and `Microsoft.ContainerService`.
- AKS clusters must enable OIDC issuer and Workload Identity.
- Confirm vCPU and GPU quota in the target region before creating node pools.

## Identity And Access

- Users sign in at `console.azure.anyscale.com` with Microsoft Entra ID SSO. No separate Anyscale identity provider is required.
- A user must hold at least `Anyscale Platform Reader` on the Anyscale cloud resource to sign in and access Anyscale resources.
- Azure subscription Owner/Contributor on the underlying resources does not automatically grant Anyscale workload permissions.
- Day-to-day workload operations require Anyscale platform Azure RBAC roles assigned through the Azure portal or Azure CLI.
- Built-in Anyscale roles:
  - `Anyscale Platform Administrator`: full access to Anyscale resources within assigned scope, including `Anyscale.Platform/admin/action`; currently only effective at subscription scope.
  - `Anyscale Platform Contributor`: read/write access to Anyscale clouds, projects, workspaces, jobs, services, compute configs, and images; excludes administrative data actions.
  - `Anyscale Platform Reader`: read-only access; required for console sign-in.
- Role assignments can be scoped at subscription, resource group, cloud, project, or individual resource level, with inheritance to child resources.
- Quickstart docs tell users to assign `Anyscale Platform Contributor` after cloud creation; otherwise workspace, job, or service creation can fail with ARM `404` because the caller lacks read permission on the parent cloud resource.
- The user request for default organization-owner behavior maps best to assigning `Anyscale Platform Administrator` at subscription scope, because the docs say that role is currently only effective at subscription scope and includes admin data actions.
- The portal-created operator managed identity performs Azure actions for the operator, including provisioning Ray cluster resources.
- A default cluster managed identity is used by workloads unless additional user-assigned identities are mapped to users, projects, or workload types through Anyscale Cloud IAM settings.

## Networking

- Anyscale on Azure uses an egress-only network model from the AKS cluster to the control plane and external services. No inbound firewall rules are required for Anyscale to reach AKS nodes.
- Primary flows:
  - Client to control plane for console, CLI, and SDK calls through `console.azure.anyscale.com`.
  - Client to AKS through Azure Load Balancer for Ray dashboard, job submission, and service requests.
  - AKS to control plane for operator polling, telemetry, and health reporting.
  - AKS to Azure resources such as Blob Storage, ADLS, and ACR.
- Required outbound HTTPS domains for Anyscale control plane:
  - `console.azure.anyscale.com`
  - `*.azure.anyscale-cloud.dev`
  - `grafana-*.azure.anyscale-cloud.dev`
  - `registry-*.azure.anyscale-cloud.dev`
- Required routing domains for Ray access:
  - `*.i.azure.anyscaleuserdata.com`
  - `vscode-*.i.azure.anyscaleuserdata.com`
  - `*.s.azure.anyscaleuserdata.com`
- Strict egress environments can replace `*.azure.anyscale-cloud.dev` with cloud-ID-specific entries, but then each Anyscale cloud needs its own entries.
- Client access to Ray head nodes and Anyscale Services is fronted by an Azure Load Balancer in front of an ingress or gateway controller.
- Anyscale on Azure requires a Layer 4 TCP load balancer; Azure Load Balancer Standard satisfies this requirement. Application Gateway is not supported as the primary ingress load balancer.
- Private AKS clusters are supported. Configure the ingress or gateway controller load balancer as internal and use private DNS plus VPN or ExpressRoute for client access.
- TLS certificates are managed and rotated by Anyscale at least every three months; the ingress or gateway controller must be able to read the generated certificate secrets.

## Gateway API And Ingress Controllers

- The Anyscale Gateway API quickstart uses Envoy Gateway as one supported Gateway implementation, but this sample targets the AKS Application Routing Gateway API implementation backed by app-routing Istio.
- AKS App Routing Gateway API uses the `approuting-istio` GatewayClass and is Microsoft's like-for-like managed successor path for Application Routing users moving away from managed NGINX.
- The AKS App Routing Gateway API implementation is ingress-only and does not provide managed Istio egress.
- The Gateway is created in `anyscale-operator` and defines HTTP port 80 plus an HTTPS listener for `*.i.azure.anyscaleuserdata.com` by default.
- In this sample, the `*.s.azure.anyscaleuserdata.com` listener is optional and should be enabled only after an Anyscale service has created the service TLS secret; before that, the Gateway can be valid with only the session HTTPS listener.
- TLS certificate secret names use the Anyscale cloud resource ID with underscores converted to hyphens:
  - `anyscale-<cloud-resource-id>-certificate`
  - `anyscale-svc-<cloud-resource-id>-certificate`
- Gateway settings are applied to the AKS extension with `az k8s-extension update --configuration-settings`, not with direct Helm changes to the Anyscale operator.
- Required extension gateway settings for the Anyscale operator include:
  - `networking.gateway.enabled=true`
  - `networking.gateway.name=<gateway-name>`
  - `networking.gateway.className=approuting-istio`
  - `networking.gateway.namespace=anyscale-operator`
  - `networking.gateway.apiVersion=gateway.networking.k8s.io/v1`
  - `networking.gateway.hostname=<gateway-lb-address>`
- The ingress-nginx quickstart is retained for legacy scenarios, but Microsoft and upstream Kubernetes are moving customers away from NGINX Ingress toward Gateway API. This sample should not rely on NGINX for Anyscale workspace or service ingress. A reference values file for the legacy path is kept at `docs/reference/sample-values_nginx.yaml`.

## Container Image Builds And ACR

- Portal-created clouds can configure a dedicated ACR for Anyscale container image builds.
- ACR modes are create new ACR, use existing ACR, or no ACR. The ACR is exclusively for Anyscale image builds; separate custom image registry configuration is still governed by Anyscale docs.
- To enable ACR later, set `properties.acrResourceId` on the `Anyscale.Platform/clouds` resource with API version `2026-02-01-preview` or newer.
- Required ACR RBAC mirrors portal-created assignments:
  - `AcrPull` for the AKS kubelet identity.
  - `AcrPush` for the Anyscale operator workload identity.
  - `Container Registry Tasks Contributor` for the Anyscale operator workload identity.
- The Anyscale operator must be version `1.5.1` or greater and must restart after the cloud has an `acrResourceId`.
- If cloud image builds are attempted without ACR configuration, Anyscale reports: `Cloud does not have ACR configuration. Please configure ACR for the cloud before creating a cluster environment.`

## Supported Regions And Quota

- Public preview regions listed in the docs:
  - `westcentralus`
  - `eastus`
  - `eastus2`
  - `westus2`
  - `westus3`
  - `southcentralus`
- Anyscale clouds are region-specific. A cloud in one region can only run workloads on AKS node pools in that same region.
- Public Preview does not support cross-region replication or multi-region clusters.
- GPU and high-performance compute availability varies by Azure region and quota; consult Azure VM size, products-by-region, and AKS quota/SKU docs.
- GPU SKUs often require explicit quota approval before node pool creation.

## Support Model

- Azure Support handles Anyscale on Azure support requests through the Azure portal and routes cases appropriately.
- Customers with direct Anyscale support channels can contact Anyscale for platform issues.
- Public Preview support is best effort, and users should check preview limitations before opening cases.
- Anyscale on Azure launch support references Enterprise tier SLAs in the support model article, while the preview articles also state preview terms apply.

## Sample Guidance

- Use Azure Native Integration and Anyscale Clouds Resource Provider framing instead of marketplace/operator-first language.
- Keep AKS private cluster, outbound-only control plane communication, managed identities, Azure Firewall egress, and Standard Load Balancer design.
- Add Microsoft Learn docs domain to locked-down egress if AKS-side automation or diagnostics need to reach the docs.
- Update Anyscale egress domains to include Azure-specific control plane, registry, Grafana, and user data routing domains from the Learn networking doc.
- Treat AKS Application Routing Gateway API with `approuting-istio` as the primary ingress path for this sample; do not add NGINX as a workaround for Anyscale workspace or service ingress.
- Add first-class role assignment variables for built-in Anyscale roles, especially subscription-scoped `Anyscale Platform Administrator` for org-owner-style default access.
- Preserve `Anyscale Platform Contributor` cloud-scoped assignment for workload users when administrator scope is not desired.
- Add support for ACR image build configuration, including `acrResourceId`, kubelet `AcrPull`, operator `AcrPush`, and operator `Container Registry Tasks Contributor`.
