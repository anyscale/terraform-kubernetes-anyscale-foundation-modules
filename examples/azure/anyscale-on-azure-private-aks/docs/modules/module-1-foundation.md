# Module 1: Build the Foundation

> **Difficulty:** Advanced | **Roles:** Platform Engineer, DevOps Engineer | **Time:** 30–45 min

By the end of this module, you're able to:

- Create the network and access foundation for a private AKS lab.
- Stand up the shared network boundary, Azure Bastion, and a Linux automation jump host with a managed identity.
- Optionally add a private Windows 11 browser jump host with Entra ID login.
- Select VM sizes that are actually available and in quota for your region.

Once this module completes, your subscription contains a resource group with a private
VNet, Azure Bastion, Azure Firewall with UDR routing, DNS Private Resolver, a Linux jump
host with a system-assigned managed identity, and an optional Windows 11 browser jump
host — all with **no public IPs** on the VMs.

## What You Will Build

- The lab resource group (`rg-<project>-<environment>-<region_short>`).
- A **shared VNet** with subnets for the jump hosts, Bastion, firewall, DNS
  resolver, and the future AKS data plane.
- **Azure Bastion** for SSH (Linux) and portal RDP (Windows) access.
- A **Linux automation jump host** with a system-assigned managed identity and
  no public IP.
- An optional **Windows 11 browser jump host** with the `AADLoginForWindows`
  extension and no public IP.
- **Azure Firewall**, route tables, **DNS Private Resolver**, and the private
  DNS zones the lab uses.

These resources live in `infra/terraform` and are exposed through Terraform
outputs for the later bootstrap stages.

## Why This Matters

The AKS cluster is private, and the lab needs a stable way to reach it without
putting every operator laptop on the VNet. Module 1 creates the network,
Bastion, jump hosts, DNS, routing, and firewall pieces that later stages use.

Keeping the jump hosts **private** (no public IP, Bastion-only access) is the
core security posture of this lab. The managed identity on the Linux host means
automation never needs a stored secret. The AKS cluster created in later modules
uses a hardened default posture as well: local cluster admin accounts are
disabled, Microsoft Defender for Containers is enabled, and the Key Vault
Secrets Provider add-on is enabled for workload secret delivery.

## Prerequisites

- Azure CLI signed in (`az login`) with rights to create networking, VMs,
  storage, and role assignments in the target subscription.
- Azure CLI `ssh` extension installed for Bastion SSH:
  `az extension add -n ssh`.
- A populated `.env`. Run `./scripts/anyscale-aks.sh init` after `az login`: it
  writes `.env` from the template with `TF_VAR_project`, `TF_VAR_environment`,
  `TF_VAR_region_short`, `TF_VAR_azure_location`,
  `TF_VAR_azure_subscription_id`, and `TF_VAR_azure_tenant_id` filled in.
- An SSH key pair for the Linux jump host. `init` generates an ed25519 key if
  `SSH_PRIVATE_KEY_PATH` does not point at one; the harness reads the `.pub`
  half when `TF_VAR_linux_jump_host_admin_ssh_public_key` is empty.

## Exercise 1: Select VM sizes

Terraform should receive concrete VM sizes, not discover them at apply time.
Run the size selector first:

```bash
./scripts/anyscale-aks.sh module 1 sizes
```

This checks regional availability with `az vm list-skus`, picks the first viable
candidate
(`Standard_D4s_v5` → `Standard_D4as_v5` → `Standard_D2s_v5` → `Standard_D2as_v5`),
and writes the result to
`.cache/aks-anyscale-sample-harness/admin/vm-size-selection.json` plus the
`TF_VAR_linux_jump_host_vm_size` (and, when the browser host is enabled,
`TF_VAR_windows_browser_jump_host_vm_size`) variables.

If no candidate works, the command fails **before** Terraform with the list of
candidates it checked and the `az` command you can run to inspect or request
quota.

On success it logs the chosen size (and the browser-host size when enabled):

```output
[module1] Selecting Linux automation jump-host VM size in westus3...
[module1] Selected Linux jump-host VM size: Standard_D4s_v5
```

## Exercise 2: Plan and apply the foundation

### Review what you're about to apply

The harness renders `infra/terraform/terraform.auto.tfvars.json` from `.env` before every
apply. The keys that matter for Module 1 are:

- `project`, `environment`, `azure_location`, `region_short` — resource-group naming and region.
- `linux_jump_host_vm_size` — written by `module 1 sizes`.
- `windows_browser_jump_host_vm_size` — written by `module 1 sizes` when the browser host is enabled.
- `linux_jump_host_admin_ssh_public_key` — your public key for Bastion SSH.

Regenerate and inspect the file at any time with `./scripts/anyscale-aks.sh render`.

```bash
./scripts/anyscale-aks.sh module 1 plan
./scripts/anyscale-aks.sh module 1 apply
```

To also create the optional Windows browser jump host:

```bash
./scripts/anyscale-aks.sh module 1 apply --enable-browser-host
```

The apply provisions the network, Bastion, Linux jump host, firewall, DNS
resolver, and the private DNS zones the lab uses.

## Exercise 3: Connect to the jump hosts

Open a Bastion SSH session to the Linux automation host:

```bash
./scripts/anyscale-aks.sh module 1 connect
```

If you enabled the Windows browser host, print the Azure portal Bastion RDP path:

```bash
./scripts/anyscale-aks.sh module 1 browser connect
```

## Validate Your Work

```bash
./scripts/anyscale-aks.sh module 1 verify
```

This confirms:

- The Linux jump host exists in the foundation outputs (the apply completed).
- The Linux jump host has **no public IP**.
- A Bastion is present for jump-host access.

It does not open a tunnel; the private DNS resolver targets only resolve from the
VM after Module 3 deploys the lab workload.

```output
[module1] PASS: Linux jump host has no public IP.
[module1] PASS: Bastion 'bas-<project>-<env>-<region>' present for jump-host access.
```

When the browser host is enabled, also run:

```bash
./scripts/anyscale-aks.sh module 1 browser verify
```

which checks the `AADLoginForWindows` extension, the `Virtual Machine User
Login` / `Virtual Machine Administrator Login` RBAC assignments, and that the
Windows VM has no public IP.

```output
[module1] PASS: Windows browser jump host has no public IP.
[module1] PASS: AADLoginForWindows extension Succeeded.
[module1] PASS: 1 VM login role assignment(s) present.
```

## Troubleshooting

- **`module 1 sizes` fails with quota** — the message lists the candidates and
  the `az vm list-usage` command. Request a quota increase or pass an explicit
  `TF_VAR_linux_jump_host_vm_size` that you know is available.
- **Bastion SSH cannot connect** — confirm the apply finished and that the VM has
  no public IP (that is expected); Bastion is the only path in.
- **Terraform not initialized** — Module 1 runs `terraform init` in
  `infra/terraform` for you; if you ran Terraform manually, re-run
  `module 1 plan`.

## Clean Up Or Continue

Leave the foundation running — Module 2 and Module 3 depend on it. It is removed
when you tear down the lab (see [cleanup.md](cleanup.md)).

## Summary

You built the foundation: a private network boundary, Bastion, a Linux
automation jump host with managed identity, and an optional Windows browser
host. Module 2 will turn the Linux host into a repeatable operator workstation.

## Next unit

Continue to [Module 2: Prepare the Jump Hosts](module-2-jump-hosts.md).
