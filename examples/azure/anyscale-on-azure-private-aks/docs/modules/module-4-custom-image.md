# Module 4: Custom Images for a Private Data Plane

> **Difficulty:** Advanced | **Roles:** Platform Engineer, DevOps Engineer | **Time:** 30–45 min

By the end of this module, you're able to:

- Explain why runtime `pip install` fails on a standard image in a locked-down private data plane.
- Build a custom Ray image with Podman and push it to a private ACR from inside the VNet.
- Sign the custom image with Notation and a Key Vault-backed signing key.
- Apply the custom image to the durable Anyscale workspaces.
- Prove that a packaged dependency loads correctly from the private registry.

Once this module completes, your private ACR holds a custom Ray image
(`cr<project><env><region>.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129`)
and your durable workspaces run with that image — confirmed by
`CUSTOM_IMAGE_DEPENDENCY_PROOF_OK`.

## What You Will Build

- A custom Ray image built with Podman on the Linux jump host and pushed to the
  private ACR (`cr<project><env><region>.azurecr.io`).
- A Notation signature attached to the image in ACR as an OCI referrer.
- A Syft SPDX SBOM attached to the image in ACR as a signed OCI referrer.
- An updated `aks-cpu-workspace` and `aks-gpu-workspace` using the custom image.
- A passing dependency proof: `CUSTOM_IMAGE_DEPENDENCY_PROOF_OK`.
- A passing SBOM proof: `CUSTOM_IMAGE_SBOM_PROOF_OK`.

## Why This Matters

In a locked-down private data plane, Azure Firewall blocks outbound PyPI traffic.
A worker on a standard Ray image that tries to `pip install onnxruntime` at
runtime fails. The fix is to bake the dependency into an image and store it in
your private ACR, which the AKS kubelet identity pulls over the Private Link
endpoint. Module 3 deploys that ACR; Module 4 uses it.

This is also a hardening choice. The cluster already denies broad runtime
freedom with pod-security and namespace isolation controls, so the image path is
where we make the workload dependency model explicit: package the dependency once
in a signed, private image and keep the runtime environment predictable.

Because the registry, storage account, and Key Vault are private-only, run the
custom-image build, SBOM, signing, apply, and proof steps from the Linux jump
host. A workstation can orchestrate Azure control-plane resources, but it should
not be expected to resolve private ACR data endpoints or upload Anyscale working
directories to private storage.

## Prerequisites

- Module 3 applied and its proofs passing.
- The Linux jump host has Podman and `AcrPush` on the private ACR
  (`module 2 doctor` confirms both).
- Anyscale CLI auth is cached on the jump host
  (`ANYSCALE_HOST=https://console.azure.anyscale.com anyscale login`).

## Review what you're about to build

The custom-image flow is seven steps:

1. `prove-failure` — submit a job on the standard image and confirm the runtime
   install is blocked (the intentional, expected failure).
2. `preflight` — confirm Podman, private ACR DNS, and `AcrPush` are in place.
3. `prepare` — build and push the image with Podman.
4. `sign` + `verify` — attach a Notation signature and verify it from the jump host.
5. `sbom` + `sbom-proof` — generate a Syft SPDX SBOM, attach it as a signed OCI
   referrer, and prove the packaged dependency is recorded in it.
6. `apply` — point the
   durable workspaces at the new image URI.
7. `proof` — load the packaged dependency inside the workspace and confirm it
   imports.

The representative dependency is `onnxruntime==1.22.0`, defined in
`workloads/custom-image/requirements-custom-image.txt` and built from
`workloads/custom-image/Dockerfile`.

## Exercise 1: Prove standard-image failure

```bash
./scripts/anyscale-aks.sh module 4 prove-failure
```

The harness submits a job on the standard image and confirms the install is
blocked. The expected-failure marker shows the private data plane is locked down
correctly:

```output
CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK requirement=onnxruntime==1.22.0
```

> This failure is **intentional**. A passing standard-image install would mean the
> data plane is not properly locked down.

## Exercise 2: Build and apply the custom image

First verify that Podman, private ACR DNS, and `AcrPush` are all in place:

```bash
./scripts/anyscale-aks.sh module 4 preflight
```

```output
CUSTOM_IMAGE_PREFLIGHT_OK image_uri=cr<project><env><region>.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129
```

Then build and push the image, and update the durable workspaces:

```bash
./scripts/anyscale-aks.sh module 4 prepare
./scripts/anyscale-aks.sh module 4 apply
```

`prepare` runs Podman on the jump host to build `workloads/custom-image/Dockerfile`
with `onnxruntime==1.22.0` and push the result to the private ACR:

```output
CUSTOM_IMAGE_BUILD_OK image_uri=cr<project><env><region>.azurecr.io/anyscale/proof-custom:onnxruntime-1.22.0-ray-2.55.1-py312-cu129
```

`apply` updates `aks-cpu-workspace` and `aks-gpu-workspace` to use the custom
image URI.

> `preflight` is managed-identity safe: it detects user, service-principal, and
> managed-identity contexts and uses the correct credential path for each.

## Exercise 3: Sign and verify the image

Signing the image lets [Module 5](module-5-image-integrity.md) verify its
provenance with AKS Image Integrity. Signing runs on the jump host, which reaches
the private Key Vault and ACR endpoints. It uses the Notation CLI, the
`notation-azure-kv` plugin, and a signing certificate stored in the
Terraform-managed Key Vault.

```bash
./scripts/anyscale-aks.sh module 4 sign
./scripts/anyscale-aks.sh module 4 verify
```

- `sign` resolves the pushed image digest, creates the self-signed Notation
  certificate in the private Key Vault if it is missing, signs with the
  jump-host managed identity, and attaches a COSE signature to the image as an
  OCI referrer in ACR. It prints `CUSTOM_IMAGE_SIGN_OK`.
- `verify` downloads the public certificate, imports a local Notation trust
  policy scoped to the ACR repository and certificate subject, and confirms the
  signature. It prints `CUSTOM_IMAGE_VERIFY_OK`.

The Key Vault (private endpoint only) and RBAC the jump host needs (`Key Vault
Certificates Officer`, `Key Vault Crypto User`, and `Key Vault Secrets User`) are
created by Terraform. The certificate itself is bootstrapped from the jump host
because the workstation cannot reach the private-only Key Vault data plane.

## Exercise 4: Attach and prove the SBOM

A Software Bill of Materials (SBOM) records every package baked into the image so
auditors can confirm what shipped without pulling the image. This step runs on
the jump host, which reaches the private ACR endpoint. It uses Syft to generate
the SBOM and ORAS to attach it as an OCI referrer.

```bash
./scripts/anyscale-aks.sh module 4 sbom
./scripts/anyscale-aks.sh module 4 sbom-proof
```

- `sbom` resolves the pushed image digest, generates a Syft SPDX JSON SBOM for
  that digest, attaches it to the image in ACR as an OCI referrer with artifact
  type `application/spdx+json`, and — when the `notation-azure-kv` plugin is
  available — signs the SBOM referrer with the same Key Vault certificate used in
  Exercise 3. It prints `CUSTOM_IMAGE_SBOM_OK`.
- `sbom-proof` discovers the SBOM referrer, pulls it from ACR with ORAS, and
  confirms the SPDX document records `onnxruntime==1.22.0`. It prints
  `CUSTOM_IMAGE_SBOM_PROOF_OK`.

ORAS authenticates to the private ACR with a short-lived `az acr login` token
passed over stdin, so no registry credential is ever printed. Syft and ORAS are
installed on the jump host by `scripts/bootstrap-jump-host.sh`.

## Exercise 5: Prove the custom image

```bash
./scripts/anyscale-aks.sh module 4 proof
```

The proof job loads `onnxruntime` inside the workspace and prints:

```output
{"available_providers": ["AzureExecutionProvider", "CPUExecutionProvider"], "marker": "CUSTOM_IMAGE_DEPENDENCY_PROOF_OK", "onnxruntime_version": "1.22.0"}
CUSTOM_IMAGE_DEPENDENCY_PROOF_OK
```

## Validate Your Work

- `prove-failure` prints `CUSTOM_IMAGE_STANDARD_IMAGE_EXPECTED_FAILURE_OK`.
- `preflight` prints `CUSTOM_IMAGE_PREFLIGHT_OK`.
- `prepare` prints `CUSTOM_IMAGE_BUILD_OK`.
- `sbom` prints `CUSTOM_IMAGE_SBOM_OK` and `sbom-proof` prints `CUSTOM_IMAGE_SBOM_PROOF_OK`.
- `proof` prints `CUSTOM_IMAGE_DEPENDENCY_PROOF_OK`.

## Unattended Equivalence

All of these exercises map to the `--custom-image` stage of the e2e command run from
Module 3:

```bash
./scripts/anyscale-aks.sh e2e --custom-image --teardown
```

The `--custom-image` flag runs `prove-failure`, `preflight`, `prepare`, `apply`,
and `proof` in order. When Syft and ORAS are installed, the custom-image stage
also runs `sbom` and `sbom-proof` after `prepare`. SBOM attachment does not
require Key Vault; SBOM signing is skipped unless the Notation Azure Key Vault
plugin is available. Image signing and signature admission checks remain separate
Module 4 and Module 5 exercises. The same custom-image steps are also available
under the backward-compat alias `module 3 custom-image <action>`.

## Troubleshooting

- **Custom-image push denied** — `preflight` checks `AcrPush`; grant it on the
  registry to the jump-host managed identity.
- **`preflight` fails DNS** — run `prepare` from the Linux jump host; the private
  ACR data endpoint must resolve via the private DNS zone inside the VNet.
- **ACR name not found on jump host** — the harness derives the ACR name directly
  from `.env` variables (`cr${TF_VAR_project}${TF_VAR_environment}${TF_VAR_region_short}`).
  No local Terraform state is required on the jump host for `preflight`, `prepare`,
  or `proof`.
- **Standard-image proof passes unexpectedly** — check firewall egress rules; a
  permissive rule may be allowing PyPI.

## Summary

You proved the private-data-plane constraint with a deliberate expected failure,
then resolved it by building a custom Ray image with Podman, pushing it to the
private ACR, and confirming the dependency loads from inside the workspace.

## Clean up resources

The Module 4 artifacts (the custom image in ACR and the workspace update) are
removed as part of `module 3 teardown`. See [Clean Up](cleanup.md).

## Next unit

- [Module 5: AKS Image Integrity](module-5-image-integrity.md) — verify the image
  signature you just created before workloads deploy.
- Optional: [Browser access](browser-access.md) — reach private workspace and
  service URLs from a browser inside the VNet.
- [Clean up](cleanup.md) — tear down the lab when you are finished.
