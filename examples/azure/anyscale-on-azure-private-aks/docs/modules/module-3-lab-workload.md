# Module 3: Deploy and Prove the Lab Workload

> **Difficulty:** Advanced | **Roles:** Platform Engineer, DevOps Engineer | **Time:** 60–90 min

By the end of this module, you're able to:

- Deploy a private AKS cluster and the Anyscale on Azure control plane from inside the VNet.
- Verify the deployment with static Terraform checks and live readiness checks.
- Run deterministic CPU, GPU, build, train, and serve proofs and read their success markers.
- Understand why custom images are required in a private data plane (the full walk-through is [Module 4](module-4-custom-image.md)).

Once this module completes, your lab resource group contains a private AKS cluster with
system, CPU, and GPU node pools; a private ACR (the custom image is built in Module 4); the
Anyscale cloud ARM resource and AKS extension; and the durable workspaces `aks-cpu-workspace`
and `aks-gpu-workspace` in `RUNNING` state — all confirmed by passing proof markers.

> **No T4 quota?** This module works without it. When `TF_VAR_gpu_pool_configs`
> is `{}` — which `init` sets automatically if it finds no quota in your region —
> there is no GPU node pool, no `aks-gpu-workspace`, and the GPU, train, and
> serve proofs are skipped with a logged reason. Everything else in this module
> is unchanged. See [expected proof
> markers](../expected-proof-markers.md#cpu-only-deploys).

## What You Will Build

- Workload resources added to the lab resource group
  (`rg-<project>-<environment>-<region_short>`).
- A **private AKS** cluster with system, CPU, and GPU pools.
- A **private ACR** with Private Link.
- Storage, observability, workload identity, and platform identities.
- The Anyscale **cloud** ARM resource and AKS extension.
- CPU and GPU compute configs and durable workspaces.

The lab workload lives in `infra/terraform` with the foundation resources.

## Why This Matters

This is the real Anyscale-on-private-AKS scenario. The module proves the sample
works **without** giving a laptop private network reach. [Module 4](module-4-custom-image.md)
builds on it to show why custom images matter: in a locked-down private data
plane, runtime package download is blocked, so dependencies must be baked into an
image pushed to your private registry.

The deploy runs **from your workstation**: all Terraform is Azure control-plane
only (ARM/AzAPI) and uses **local state** on your machine. The in-cluster
bootstrap (operator namespace and service account, the NVIDIA device plugin, and
the Anyscale gateway) runs **on the Linux jump host** as idempotent kubectl/helm
steps via `scripts/bootstrap-k8s.sh`, invoked over a Bastion tunnel — **Terraform
never runs on the jump box**. The AKS cluster also applies the current hardening
baseline by default: local cluster admin accounts are disabled, Microsoft
Defender for Containers is enabled, the Key Vault Secrets Provider add-on is
enabled, the bootstrap path labels the operator and GPU namespaces with Pod
Security Admission baseline controls, the bootstrap path applies a
conservative NetworkPolicy baseline that denies ingress by default while
preserving same-namespace and DNS traffic, and the bootstrap path applies
resource guardrails so the namespaces have sensible default requests/limits and
aggregate quotas. Use Entra-backed access for day-to-day operations; opt out
only for a temporary break-glass exception.

## Prerequisites

- Module 1 applied and Module 2 verified (the jump host is reachable over Bastion
  and has `kubectl` and `helm`).
- You run `module 3` commands **from your workstation**, not the jump host.
- Anyscale CLI auth is available
  (`ANYSCALE_HOST=https://console.azure.anyscale.com anyscale login`).

## Exercise 1: Deploy

### Review the nine deploy stages

`module 3 deploy` runs nine sequential stages. Each writes its own log under
`.cache/aks-anyscale-sample-harness/runs/<timestamp>-deploy/`. The
`bootstrap-a`/`bootstrap-b` stages are the only ones that touch the jump host, and they
run `kubectl`/`helm` over a Bastion tunnel — **Terraform never runs on the jump box**.

| Stage | What it does |
| --- | --- |
| `prepare` | Renders `terraform.auto.tfvars.json` from `.env` and validates required inputs. |
| `reset-or-state` | Reconciles existing Terraform state, or resets it with `--from-scratch`. |
| `terraform-init-validate` | Runs `terraform init`, `fmt -check`, and `validate` on the rendered config. |
| `foundation` | Applies the Azure foundation: VNet, Firewall, Bastion, AKS, ACR, storage, observability. |
| `bootstrap-a` | Jump-host `kubectl`/`helm`: namespaces, workload identity, NVIDIA device plugin. |
| `platform` | Applies the Anyscale cloud ARM resource and AKS extension from your workstation. |
| `bootstrap-b` | Jump-host `kubectl`/`helm`: installs the Anyscale gateway and finishes TLS bootstrap. |
| `workspaces` | Creates or reconciles the `aks-cpu` and `aks-gpu` durable workspaces. |
| `health` | Confirms AKS, the extension, the cloud, operator/Istio/gateway rollout, and workspace state. |

### Run the deploy

```bash
./scripts/anyscale-aks.sh module 3 deploy
```

All Terraform is Azure control-plane only (ARM/AzAPI) and uses **local state** on your
workstation. The in-cluster bootstrap runs on the jump host in two phases, with the
Anyscale cloud and AKS extension applied from your workstation in between.

The run streams each stage and ends with the health summary (`<n>s` is the measured
stage duration):

```output
[setup] [1/9] prepare started
[setup] [1/9] prepare ok (<n>s)
[setup] [4/9] foundation started
[setup] [4/9] foundation ok (<n>s)
[setup] [9/9] health started
[setup] Azure AKS cluster aks-<project>-<env>-<region> is Succeeded/Running.
[setup] Anyscale AKS extension anyscale-operator provisioningState=Succeeded.
[setup] Anyscale cloud resource provisioningState=Succeeded.
[setup] Anyscale operator, app-routing Istio control plane, and Anyscale Gateway are Available.
[setup] CPU workspace aks-cpu-workspace API status=RUNNING.
[setup] GPU workspace aks-gpu-workspace API status=RUNNING.
[setup] [9/9] health ok (<n>s)
[setup] Deployment complete. Run ./scripts/anyscale-aks.sh verify --full, then ./scripts/anyscale-aks.sh proof all.
```

## Exercise 2: Verify

```bash
./scripts/anyscale-aks.sh module 3 verify --full
```

Runs both static Terraform validation and live infrastructure/readiness checks
from inside the VNet.

## Module 4: Custom images

The custom-image steps (prove-failure, preflight, prepare, apply, proof) are their
own module. Continue to [Module 4: Custom Images for a Private Data
Plane](module-4-custom-image.md) after this module's proofs pass.

## Exercise 3: Run the workload proofs

Run the full proof from the Linux jump host after Module 2 is synced and
bootstrapped. The CPU/GPU Ray probes can be inspected from either side, but the
Anyscale build, train, and serve proofs upload a working directory to private
storage and are meant to execute from inside the VNet.

```bash
./scripts/anyscale-aks.sh module 3 proof all
```

Each proof prints a deterministic JSON payload followed by its success marker. A full
run emits the CPU and GPU Ray markers, the build and train job markers, and the serve
service marker:

```output
{"marker": "CPU_RAY_PROOF_OK", "row_count": 16, "square_sum": 1240}
CPU_RAY_PROOF_OK
[setup] aks-cpu-workspace printed CPU_RAY_PROOF_OK.
{"cube_sum": 784, "gpu_capacity": 1.0, "marker": "GPU_RAY_PROOF_OK", "row_count": 8}
GPU_RAY_PROOF_OK
[setup] aks-gpu-workspace printed GPU_RAY_PROOF_OK.
CPU_BUILD_JOB_PROOF_OK
GPU_TRAIN_JOB_PROOF_OK
service_state=STARTING primary_version_state=RUNNING
GPU_SERVE_SERVICE_PROOF_OK
```

On a cold GPU pool, the train and serve stages can spend several minutes in
startup while AKS scales the T4 node pool, pulls images, and initializes the
NVIDIA device plugin. For services, the Anyscale top-level service state can
briefly lag the running version and endpoint: the harness treats a running
primary version plus successful endpoint proof as the meaningful readiness
signal.

## Validate Your Work

- Deploy stages pass from the VM.
- `verify --full` passes static and live validation.
- The CPU, GPU, build-job, train-job, and serve proof stages pass.

As you observe these stages, notice the Anyscale differentiators at work:
managed workspaces and fast cluster launch (deploy), intelligent autoscaling
(job startup), and workload observability (proof review).

## Exercise 4 (optional): Browser validation before teardown

Console-launched workspace, dashboard, and service URLs are private. To inspect
them in a browser, use the Windows browser jump host:

```bash
./scripts/anyscale-aks.sh module 3 browser validate
```

See [browser-access.md](browser-access.md) for the full lesson. Browser
validation is **not** part of the default unattended run.

## Unattended Equivalence

The step-by-step path above is exactly what the unattended command runs:

```bash
./scripts/anyscale-aks.sh e2e --custom-image --teardown
```

To also run the non-interactive browser-host prerequisite checks (without portal
RDP or interactive login):

```bash
./scripts/anyscale-aks.sh e2e --custom-image --include-browser-precheck
```

When `--teardown` is supplied, the e2e summary states that interactive browser
validation was skipped and points you to `module 3 browser validate`.

## Troubleshooting

- **`bootstrap-a`/`bootstrap-b` fails** — these run `kubectl`/`helm` on the jump
  host over a Bastion tunnel; confirm Module 2 installed `kubectl`/`helm` and the
  jump-host managed identity has cluster-admin (granted via the explicit
  principal map in shared mode).
- **Terraform init/apply fails on the workstation** — the lab uses
  **local state** and Azure control-plane (ARM/AzAPI) only; confirm your `az`
  login can reach `management.azure.com`.
- **Job proof upload fails from the workstation** — rerun the proof from the
  Linux jump host. In the private lab, Anyscale working directories are uploaded
  to private Storage Blob/DFS endpoints that resolve and route only inside the
  VNet.
- **GPU train or serve appears slow** — check whether the GPU node pool is
  scaling from zero or pulling images. This is expected on a cold run; wait for
  the proof marker before treating `STARTING` as a failure.

## Summary

You deployed and proved the private Anyscale-on-AKS lab workload by running the
Azure control-plane Terraform from your workstation and the in-cluster bootstrap
as `kubectl`/`helm` scripts on the jump host. [Module 4](module-4-custom-image.md)
builds on this by demonstrating the custom-image requirement.

## Next unit

Continue to [Module 4: Custom Images for a Private Data Plane](module-4-custom-image.md).
