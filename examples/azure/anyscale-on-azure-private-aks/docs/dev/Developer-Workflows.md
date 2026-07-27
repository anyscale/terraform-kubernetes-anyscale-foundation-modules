# Developer Workflows

> **Maintainer appendix.** This file is not part of the primary hands-on lab.
> New operators should follow the learning path starting at
> [docs/modules/intro.md](../modules/intro.md). This appendix holds maintainer and
> developer-focused details that the module docs intentionally leave out.

This file holds maintainer and developer-focused details for the private Anyscale on AKS sample. The main [README](../../README.md) stays focused on the operator path: build the environment, run the Anyscale proofs, and clean up safely.

## Dependency Reference

Run a local readiness report with:

```bash
./scripts/anyscale-aks.sh doctor
```

| Tool | Required for | Where to get it |
| --- | --- | --- |
| Git | Source checkout and local workflow | <https://git-scm.com/downloads> or `brew install git` |
| Azure CLI `az` | Azure deploy, verify, teardown, and status | <https://learn.microsoft.com/cli/azure/install-azure-cli> or `brew install azure-cli` |
| Terraform `>= 1.9.0` | Infrastructure plan/apply/destroy/tests | <https://developer.hashicorp.com/terraform/install> |
| `kubectl` | Private AKS bootstrap, validation, and proofs | <https://kubernetes.io/docs/tasks/tools/> or `az aks install-cli` |
| `kubelogin` | Entra-backed AKS authentication | <https://azure.github.io/kubelogin/> or `brew install Azure/kubelogin/kubelogin` |
| Helm | Kubernetes bootstrap charts | <https://helm.sh/docs/intro/install/> or `brew install helm` |
| `jq` | JSON parsing for Terraform, Azure, Kubernetes, and Anyscale output | <https://jqlang.github.io/jq/download/> or `brew install jq` |
| `rsync` | Copying workload proof files into workspace pods | <https://rsync.samba.org/> or `brew install rsync` |
| Python `3.9+` | Local helper scripts and inline data transforms | <https://www.python.org/downloads/> or `brew install python` |
| `uv` | Repo-local virtual environment and Anyscale CLI install | <https://docs.astral.sh/uv/getting-started/installation/> or `brew install uv` |
| `curl` | HTTP probes for validation and service proof checks | <https://curl.se/download.html> or system package manager |
| `lsof` | Local Bastion/browser tunnel port checks | Included with macOS, or install from your system package manager |

Optional tools:

| Tool | Used by | Where to get it |
| --- | --- | --- |
| ShellCheck | Bash linting | <https://www.shellcheck.net/> or `brew install shellcheck` |
| Firefox | Isolated workspace browser helper flows | <https://www.mozilla.org/firefox/> |
| diagrams.net/draw.io CLI | `./scripts/anyscale-aks.sh diagrams export` | <https://www.diagrams.net/> |

Install the repo-local Anyscale CLI with:

```bash
uv venv .venv
UV_CACHE_DIR="$PWD/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale
```

## Deploy Stage Breakdown

`./scripts/anyscale-aks.sh deploy` is phase-based so a private AKS cluster can be created first, then reached through Bastion for the Kubernetes bootstrap layer.

| Stage | What it does |
| --- | --- |
| `prepare` | Loads `.env`, checks required CLIs, validates Azure login, and selects the target subscription. |
| `reset-or-state` | Reconciles or resets local state. `--from-scratch --yes` deletes the target resource group and purges local Terraform state first. |
| `terraform-init-validate` | Runs `terraform init`, `terraform fmt -check`, and `terraform validate`. |
| `foundation` | Applies the private Azure foundation: network, Firewall, Bastion, AKS, storage, ACR, identity, and observability. |
| `bootstrap-a` | Opens Bastion-backed AKS access and applies the first in-cluster bootstrap phase on the jump host (namespaces, service accounts, gateway prerequisites). |
| `platform` | Deploys the Azure-native Anyscale cloud and AKS extension, and reconciles Anyscale Platform built-in role assignments. |
| `bootstrap-b` | Applies the second in-cluster bootstrap phase on the jump host (the Anyscale gateway and remaining Kubernetes resources). |
| `workspaces` | Registers or reconciles `aks-cpu` and `aks-gpu`, then creates or updates the durable workspaces. |
| `health` | Runs the live post-deploy health checks. |

Every run writes local logs under `.cache/aks-anyscale-sample-harness/runs/<timestamp>-<command>/`, including `summary.md`, `stages.tsv`, and per-stage logs.

The plan-time Terraform tests (`infra/terraform/tests/*.tftest.hcl`) do **not** run inside `deploy`. They are a standalone gate, and a bare `terraform -chdir=infra/terraform test` does **not** work: `azure_subscription_id` and `azure_tenant_id` are required with no default, no suite sets them, and the `azurerm` provider resolves the subscription through the Azure CLI authorizer even for plan-only runs — so a placeholder GUID fails too. Supply real IDs and filter to the three plan suites:

```bash
terraform -chdir=infra/terraform init

export TF_VAR_azure_subscription_id="$(az account show --query id -o tsv)"
export TF_VAR_azure_tenant_id="$(az account show --query tenantId -o tsv)"
terraform -chdir=infra/terraform test \
  -filter=tests/plan.tftest.hcl \
  -filter=tests/private_mode.tftest.hcl \
  -filter=tests/identity_contract.tftest.hcl
```

`tests/apply.tftest.hcl` provisions billable resources (Azure Firewall, AKS, jump-host VM) and is excluded above. It takes its region and naming from the environment so you can aim it at a region where you hold quota, and so the derived storage account name stays globally unique:

```bash
TF_VAR_project="tftest$(openssl rand -hex 2)" TF_VAR_environment=ci \
TF_VAR_azure_location=westus2 TF_VAR_region_short=wus2 \
  terraform -chdir=infra/terraform test -filter=tests/apply.tftest.hcl -verbose
```

It needs `Microsoft.Authorization/policyAssignments/write` at the target scope — Owner or Resource Policy Contributor. Plain Contributor fails at `module.image_integrity`, which creates a policy assignment and has no enable toggle.

**Two footguns.** `terraform test` auto-loads `infra/terraform/terraform.auto.tfvars.json` when a `deploy` or `verify --static` has rendered one, which silently supplies a real subscription and lets the billable apply suite run when you meant to run only the plan gate — always pass `-filter`, or move the rendered tfvars aside. And when the apply suite fails mid-create, its automatic teardown can fail too (the AMPLS private DNS zone group is a known offender), leaving `rg-<project>-<environment>-<region_short>` behind; check for and delete that resource group after any failed apply run.

| Path | What you use it for |
| --- | --- |
| `infra/terraform/terraform.auto.tfvars.json` | Generated Terraform inputs rendered from `.env`. |
| `.cache/aks-anyscale-sample-harness/kubeconfig.bastion` | Bastion-backed kubeconfig used by live validation and workload proof commands. |
| `.cache/aks-anyscale-sample-harness/runs/` | Timestamped run directories with `summary.md`, `stages.tsv`, logs, and diagnostics. |

Keep one-off local operator notes in a repo-root `ISSUES.md`; that file is gitignored.

Useful Terraform inspection commands:

```bash
terraform -chdir=infra/terraform output
terraform -chdir=infra/terraform test -filter=tests/private_mode.tftest.hcl -verbose
```

(For the billable apply suite, see the env-prefixed form under the standalone gate above.)

## Job and Service Proofs (manual jump-host login)

The CPU and GPU **Ray** proofs (`proof cpu`, `proof gpu`) run from the workstation:
they exec into the already-running workspace pod over the Bastion-backed kubeconfig
and need no working-directory upload.

The **job and service** proofs (`proof pipeline`, and the job/service stages of
`proof all`) and the **custom-image** proofs are different — they submit Anyscale
jobs/services, which upload the working directory to the **private** storage
account. That upload only resolves through private DNS from **inside the VNet**, so
the recommended path is to run them from the in-VNet Linux jump host after logging
in to the Anyscale CLI there:

```bash
# 1. Connect to the Linux jump host through Azure Bastion (from your workstation):
./scripts/anyscale-aks.sh module 1 connect

# 2. On the jump host, authenticate the Anyscale CLI once (interactive OAuth):
ANYSCALE_HOST=https://console.azure.anyscale.com .venv/bin/anyscale login

# 3. Run the job/service proofs from the jump host (no flag needed — the harness
#    detects that the private Storage endpoints resolve from here):
./scripts/anyscale-aks.sh module 3 proof pipeline
```

The harness fails fast with this guidance if the Anyscale CLI is not logged in, and
`./scripts/anyscale-aks.sh doctor` reports the same login command when auth is
missing. `ANYSCALE_CLI_TOKEN` in `.env` remains supported, but only as a
**non-interactive / CI** fallback (it lets the harness submit from inside the
workspace pod); for normal manual use prefer the jump-host `anyscale login` above
rather than placing a long-lived token in `.env`.

## Custom Ray Images

The private ACR is only reachable through Private Link. For this harness, local custom-image prepare uses Podman to build a `linux/amd64` image and push it to ACR, so run these commands from the in-VNet Linux jump host where both the registry endpoint and regional data endpoint resolve privately.

The harness derives the private ACR name from `.env` naming (`TF_VAR_project` / `TF_VAR_environment` / `TF_VAR_region_short`), so it needs no Terraform state on the jump host.

```bash
./scripts/anyscale-aks.sh custom-image preflight
./scripts/anyscale-aks.sh custom-image prepare
```

`az acr import` is still useful when you are mirroring an already-built external image into the private ACR and the source registry is reachable by Azure. It is not a replacement for building the sample's custom dependency image from `workloads/custom-image/`.

```bash
source .env
ACR_NAME="cr${TF_VAR_project}${TF_VAR_environment}${TF_VAR_region_short}"
RG="rg-${TF_VAR_project}-${TF_VAR_environment}-${TF_VAR_region_short}"
az acr import \
  --name "$ACR_NAME" \
  --resource-group "$RG" \
  --source docker.io/anyscale/ray:2.55.1-slim-py312-cu129 \
  --image anyscale/ray:2.55.1-slim-py312-cu129
```

If the source registry rate-limits you, retry with authenticated source-registry credentials. Once imported, point the Anyscale workspace or compute-config image setting at `<acr_login_server>/anyscale/ray:<tag>`.

## Optional Operator Tooling

AKS MCP example config for VS Code-style clients:

```json
{
  "servers": {
    "aks": {
      "type": "stdio",
      "command": "aks-mcp",
      "args": ["--transport", "stdio"]
    }
  }
}
```

AKS Agent CLI:

```bash
az extension add --name aks-agent --upgrade
az aks agent --help
```

Inspektor Gadget:

```bash
kubectl krew install gadget
kubectl-gadget deploy --timeout 4m
```

## Idempotency and Repeatability

Use the built-in idempotency harness to prove the sample reconciles cleanly:

```bash
./scripts/anyscale-aks.sh self-test idempotency
```

By default it runs deploy, verify, and workload proofs twice, then requires a Terraform no-op plan. Destructive cleanup is opt-in:

```bash
./scripts/anyscale-aks.sh self-test idempotency --include-teardown
./scripts/anyscale-aks.sh self-test idempotency --include-force-teardown --i-understand-this-deletes-azure-resources
```

## Diagram Export

The editable overview source is [Architecture-Diagram.drawio](../Architecture-Diagram.drawio). Regenerate the checked-in SVG preview with:

```bash
./scripts/anyscale-aks.sh diagrams export
```

The diagrams.net/draw.io CLI must be installed for this export command.

## Agent Skill Provenance

This repository does not track local agent skill bundles. Local copies under `.agents/skills/` and `.claude/` are machine-local assistant context.

HashiCorp Terraform skills from `hashicorp/agent-skills` were used for Terraform style guidance, module boundary review, AVM comparison, and Terraform test planning:

- `azure-verified-modules`
- `refactor-module`
- `terraform-style-guide`
- `terraform-test`

Terraform provider implementation skills were inspected but not used because this repository is Terraform configuration and workflow code, not a Terraform provider:

- `new-terraform-provider`
- `provider-actions`
- `provider-docs`
- `provider-resources`
- `provider-test-patterns`
- `run-acceptance-tests`
- `terraform-search-import`
- `terraform-stacks`

Local Anyscale skills under `.claude/skills/` were used for Anyscale-on-Kubernetes infrastructure guidance, live workload execution planning, diagnostics planning, and Ray workload proof design:

- `anyscale-infra-kubernetes`
- `anyscale-platform-ask`
- `anyscale-platform-inspect`
- `anyscale-platform-run`
- `anyscale-platform-fix`
- `anyscale-workload-ray-data`
- `anyscale-workload-ray-serve`

Other Anyscale skills were inspected but not used for implementation:

- `anyscale-infra-aws-vm`
- `anyscale-infra-gcp-vm`
- `anyscale-workload-batch-embedding`
- `anyscale-workload-llm-post-training`
- `anyscale-workload-llm-serving`
- `anyscale-workload-ray-train`

Do not commit local skill bundle directories or generated lock files. This section is the tracked record of which assistant skills informed repository work and why.
