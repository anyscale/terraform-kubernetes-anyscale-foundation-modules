# Agent instructions

This project is the **Anyscale Private AKS Reference Architecture on Azure** — a
Terraform + bash harness that builds, proves, and tears down a private Anyscale on
AKS environment (private AKS, private storage/ACR, Azure Firewall egress, Bastion +
in-VNet jump hosts, Azure-native Anyscale platform resources).

This file is loaded on **every** request and is the single source of truth for
**governance, the agent team, and the non-negotiable rules**. Build/validate
commands and environment specifics live in
[`.github/copilot-instructions.md`](.github/copilot-instructions.md) and are **not**
duplicated here.

## Environment bootstrap

- Supported on macOS and Linux operator workstations, and on the in-VNet Ubuntu
  Linux jump host (`scripts/bootstrap-jump-host.sh`).
- Local setup: `az login`, `./scripts/anyscale-aks.sh init` (writes `.env` from
  `.env-template` and fills the Azure ids), create the repo venv
  (`uv venv .venv`), install the Anyscale CLI into `.venv`.
- There is **no** package-manager bootstrap to run for the harness itself; the
  toolchain (Terraform, Azure CLI, kubectl/kubelogin, Helm, jq, Podman, Python/uv)
  is checked by `./scripts/anyscale-aks.sh doctor`.

Per-task flow: **planner → implementer (or a specialist) → reviewer**. When the
*plan* (not the code) is wrong, route back to the planner.

### Running in the Copilot CLI (handoffs do not apply)

The agents are `target: vscode`, so handoffs are realized only in VS Code Agent
Mode. In the Copilot CLI (or any programmatic dispatch) the chain is
**operator-driven**: run the planner, dispatch the implementer/specialist as a
separate task, then dispatch the reviewer as a **separate** invocation. Never let
one agent both make and bless a change. The high-privilege `anyscale-aks-infra`
agent is reached only by explicit named dispatch.

## Git / commits

Never `git commit` or `git push` unless the user explicitly says so. Read-only git
(status, diff, log) is fine.

## Operational safety (this repo deploys real Azure infrastructure)

- Local, reversible edits (files, `terraform fmt`, `bash -n`, `py_compile`) are
  free. **Never** run `deploy`, `apply`, `e2e`, `teardown`, `nuke`, `az group
  delete`, or any Anyscale mutating command without explicit user instruction.
- Treat `--force`/`nuke` teardown and `terraform apply/destroy` as destructive:
  confirm first. Do not bypass safety prompts (`--yes`) on the user's behalf.
- Never delete or overwrite cached Anyscale/Azure CLI credentials.

## Paths & portability — no machine-specific config

Use repo-relative paths or `${workspaceFolder}` / `$HOME` / `$PWD` / `$TMPDIR`.
No personal checkout paths in committed files.

## Secrets — never committed, never printed

No tokens, subscription/tenant/object ids, ACR/storage keys, bearer values, or
SSH private keys in committed files, logs, or summaries. `.env` and
`terraform.auto.tfvars.json` are git-ignored and hold real values; keep it that
way. When recovering Anyscale auth, use `anyscale login` (cached OAuth), never a
fabricated `ANYSCALE_CLI_TOKEN`.

## User-facing language — no internal jargon

Anything an end user reads (README, module docs, `RESULTS.md`, console output)
must be plain. No internal work-package ids or pipeline jargon. The reviewer
enforces this.