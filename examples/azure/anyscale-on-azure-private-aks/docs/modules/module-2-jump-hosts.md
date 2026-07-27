# Module 2: Prepare the Jump Hosts

> **Difficulty:** Advanced | **Roles:** Platform Engineer, DevOps Engineer | **Time:** 20–30 min

By the end of this module, you're able to:

- Turn the Linux jump host into a repeatable operator workstation inside the VNet.
- Install the required tooling and sync the repository and `.env` to the host.
- Confirm managed-identity authentication works end to end, with no stored secrets.
- Optionally verify the Windows browser jump host is ready for Entra ID login.

Once this module completes, the Linux jump host has Azure CLI, `kubectl`,
`kubelogin`, Helm, `jq`, Podman, and the Anyscale CLI in a repo-local `.venv`. It
authenticates to Azure with its managed identity and carries a copy of your
`.env`. Terraform is not installed or run on the jump host — it stays on your
workstation/client.

## What You Will Build

- A fully provisioned Linux jump host with Azure CLI, `kubectl`,
  `kubelogin`, Helm, `jq`, `rsync`, `curl`, `lsof`, Git, Python, `uv`, and
  Podman.
- The repository checked out at the canonical path `/opt/anyscale-aks-sample`.
- A repo-local `.venv` containing the Anyscale CLI.
- A copy of your `.env` on the VM at the canonical repo path.

## Why This Matters

The Linux jump host must be boring and repeatable. If every operator installs
tools a little differently, the sample becomes hard to teach and harder to
debug. Module 2 makes the host deterministic.

That repeatability matters for security as well. The jump host is the only place
that reaches the private AKS control plane from inside the VNet, so it stays
minimal, identity-based, and separated from the workload namespaces. The cluster
bootstrap that follows applies the current hardening baseline for workload
runtime: Pod Security Admission baseline labels, a default-deny ingress
NetworkPolicy, and namespace resource guardrails. That keeps the operator path
and the workload path aligned with the same enterprise posture.

The same boundary applies to private data-plane artifacts. Your workstation can
run Azure control-plane deploy and verify steps through Bastion-assisted helper
commands, but private ACR pushes, private Storage uploads for Anyscale working
directories, Key Vault signing operations, and the full Anyscale job/service
proofs belong on the Linux jump host where private DNS resolves inside the VNet.

The optional Windows browser host is equally constrained: it is a **browser
desktop only**. It never owns Terraform state, never runs Podman, and never runs
Anyscale CLI automation.

## Prerequisites

- Module 1 applied successfully (`module 1 verify` passes).
- You can open a Bastion SSH session to the Linux jump host
  (`module 1 connect`).

## Exercise 1: Sync the repository and environment

```bash
./scripts/anyscale-aks.sh module 2 sync
```

This `rsync`s the repository content and your `.env` to the canonical VM path
over a Bastion tunnel.

Nothing in that `.env` grants the VM its private-network access; being inside the
VNet does. The harness probes DNS on each run and uses the AKS API directly when
the private FQDN resolves privately from wherever it is running. The mode value
on the VM affects presentation and guidance messages, and marks the box as the
place where the private-endpoint steps are meant to run.

> Secrets are never committed. If you need a token for non-interactive Anyscale
> CLI work, fetch it at runtime from Key Vault or set it up on the VM directly —
> do not place it in a tracked file.

### Alternative: clone from a fork instead of rsyncing the code

If this repository is hosted at a URL the jump host can reach (for example a
public GitHub fork), you can have the host **clone itself** during bootstrap
instead of rsyncing the source tree. Set `ANYSCALE_AKS_REPO_URL` in your
**workstation** `.env`:

```ini
ANYSCALE_AKS_REPO_URL=https://github.com/<your-org>/<your-fork>
```

When `scripts/bootstrap-jump-host.sh` runs and the repo is not already present,
`ensure_repo()` sees `ANYSCALE_AKS_REPO_URL` is set and runs `git clone` instead
of waiting for an rsync. `github.com` and `*.githubusercontent.com` are already in
the default firewall allow-list (`TF_VAR_tool_bootstrap_fqdns`), so the clone
succeeds from inside the VNet.

This does **not** replace `module 2 sync`:

| | `module 2 sync` (default) | `ANYSCALE_AKS_REPO_URL` git clone |
| --- | --- | --- |
| Copies your gitignored `.env` | Yes | No — `.env` is never in git |
| Copies local uncommitted edits | Yes | No — only committed state |
| Needs a reachable repo URL | No | Yes |

Because `.env` is never in git, you still run `module 2 sync` at least once to
place `.env` on the VM (the clone only saves copying the source tree). Use the
git-clone path when you track a committed fork and don't need local edits;
otherwise `module 2 sync` remains the simplest one-command path.

## Exercise 2: Bootstrap the Linux jump host

Open a Bastion SSH session:

```bash
./scripts/anyscale-aks.sh module 1 connect
```

### Review what you're about to install

`scripts/bootstrap-jump-host.sh` runs on the VM and installs the operator toolchain
(idempotent — it skips anything already present):

- System packages: `git`, `curl`, `jq`, `rsync`, `lsof`.
- Azure CLI, plus `kubectl` and `kubelogin`.
- Helm.
- Python via `uv`, and Podman for custom-image builds.
- The Anyscale CLI into a repo-local `.venv/bin/anyscale`.

Then run the bootstrap **inside the VM**:

```bash
cd /opt/anyscale-aks-sample
./scripts/anyscale-aks.sh module 2 bootstrap
```

## Exercise 3: Run doctor on the jump host

```bash
./scripts/anyscale-aks.sh module 2 doctor
```

On the jump host, `doctor` reports that it is running on an Azure VM and checks:

- Required tools on PATH and that `.env` exists.
- Azure CLI managed-identity auth (`az login --identity`).
- Anyscale CLI OAuth / API-key auth.
- Podman readiness and the custom-image preflight.

## Validate Your Work

```bash
./scripts/anyscale-aks.sh module 2 verify
```

This confirms:

- `az account show` works on the VM with the managed identity.
- `kubectl version --client`, `kubelogin --version`,
  `helm version`, `podman version`, and `.venv/bin/anyscale --help` all succeed.
- The repo exists at `/opt/anyscale-aks-sample`.
- `.env` exists on the VM.

It does not run a DNS probe; no workstation private-DNS path is required because
the private endpoints resolve from inside the VNet.

```output
[module2] PASS: az account show (managed identity)
[module2] PASS: kubectl version --client
[module2] PASS: kubelogin version
[module2] PASS: helm version
[module2] PASS: podman version
[module2] PASS: anyscale --help
[module2] PASS: repo present at /opt/anyscale-aks-sample
[module2] PASS: .env present on the VM
[module2] Module 2 verify passed. The jump host reaches private endpoints directly from inside the VNet.
```

If you enabled the browser host:

```bash
./scripts/anyscale-aks.sh module 2 browser verify
```

confirms the Windows VM accepts Entra-backed Bastion portal RDP for the
configured user or group — again, without any local proxy.

## Troubleshooting

- **`az login --identity` fails** — confirm the Linux jump host has its
  system-assigned managed identity enabled (Module 1) and that the identity has
  the roles it needs in the subscription.
- **Tool missing** — re-run `module 2 bootstrap`; it is idempotent.
- **`.env` missing on the VM** — re-run `module 2 sync` from the workstation.

## Clean Up Or Continue

Nothing to clean up here — the jump host is part of the foundation.

When you are ready for Module 3, exit the jump-host SSH session and return to
your workstation:

```bash
exit
```

Module 3 `deploy` runs **from your workstation**, not the jump host.

## Summary

The Linux jump host is now a repeatable, secret-free operator workstation inside
the VNet, authenticating with a managed identity and ready to deploy the
lab workload. The optional Windows browser host is verified for interactive
browser validation later.

## Next unit

Continue to [Module 3: Deploy and Prove the Lab Workload](module-3-lab-workload.md).
