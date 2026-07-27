# Clean Up

> **Difficulty:** Intermediate | **Roles:** Platform Engineer, DevOps Engineer | **Time:** 10–15 min

By the end of this unit, you're able to:

- Drain the Anyscale cloud and destroy the lab resource group with one command.
- Verify the resource group and all local Terraform state are fully removed.

Cleanup is intentionally simple: the lab uses one Azure resource group and one
Terraform root. When you are done, tear down the whole lab.

## Tear Down the Lab

```bash
./scripts/anyscale-aks.sh module 3 teardown
```

The teardown drains the Anyscale cloud before destroying provider child
resources, then runs Terraform destroy for the lab resource group.

> If you ran browser validation, do it **before** teardown — once the workload
> resources are gone, the private `*.azure.anyscaleuserdata.com` hostnames no longer
> resolve.

### Non-interactive teardown

By default teardown prompts you to type the project name to confirm. For
scripted or CI runs, pass `--confirm-project <name>` to skip the prompt — the
name must match `TF_VAR_project` exactly:

```bash
./scripts/anyscale-aks.sh teardown --confirm-project <project>
```

The end-to-end (`e2e`) flow passes this flag automatically so teardown never
blocks on a prompt.

### Expect a slow destroy

Terraform destroy can run for a while. **Azure Key Vault purge** and **Azure
Firewall deallocation** are the typical long poles. The teardown prints a
progress line roughly every 60 seconds (with elapsed time) so a long-running
destroy is distinguishable from a hang — let it run rather than interrupting it.

### Audit the teardown

Each standard teardown writes `teardown-evidence.json` into its run directory
under `.cache/aks-anyscale-sample-harness/runs/`. It records the command,
timestamp, Terraform exit code, remaining Terraform state count, and whether the
resource group still exists — a compact audit trail for the cleanup.

### Validate teardown

- `terraform -chdir=infra/terraform state list` returns no resources.
- The lab resource group `rg-<project>-<environment>-<region_short>` is deleted.
- No Bastion, jump host, VNet, firewall, DNS resolver, or state storage remains.
- `az group exists --name rg-<project>-<environment>-<region_short>` returns `false`.

```output
$ terraform -chdir=infra/terraform state list
$ az group exists --name rg-<project>-<environment>-<region_short>
false
```

## Force Reset

If Terraform cannot complete cleanup, use the stronger reset path:

```bash
./scripts/anyscale-aks.sh teardown --force --yes
```

That path drains the Anyscale cloud, deletes the lab resource group directly with
Azure CLI, waits for deletion, and removes local Terraform state artifacts.

## Local Artifacts

Harness run artifacts live under `.cache/aks-anyscale-sample-harness/` and are
safe to delete. Generated files such as `terraform.auto.tfvars.json` and
`*_override.tf` are gitignored and recreated on the next run.

## Troubleshooting

- **Anyscale cloud will not delete** — a stale cluster or nested resource can
  block deletion. The teardown drains the cloud first; if it still fails, inspect
  the Anyscale console and remove lingering clusters before retrying.
- **Bastion-dependent destroy hangs** — keep Bastion alive until Kubernetes
  bootstrap resources are destroyed; the teardown ordering handles this for you.
  Do not manually delete Bastion before `module 3 teardown` completes.

## Lab complete

You've finished all five modules of the Anyscale Private AKS lab. Return to the
[README](../../README.md) for reference documentation, day-2 operations, and
architecture details.
