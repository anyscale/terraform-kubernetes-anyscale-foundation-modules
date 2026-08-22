# Browser Access to Private Anyscale URLs

> **Difficulty:** Intermediate | **Roles:** Platform Engineer, DevOps Engineer | **Time:** ~10 min

By the end of this lesson, you're able to:

- Explain why private `*.azure.anyscaleuserdata.com` URLs do not resolve from a normal workstation browser.
- Reach private workspace, dashboard, and service URLs from a browser running inside the VNet.
- Choose the right access path (Windows browser host, SOCKS5 over Bastion, or in-VNet desktop) for your scenario.

Once you complete this lesson, you can open private workspace and service URLs from a
browser inside the VNet through Bastion portal RDP, with valid TLS and no proxy required.

## Why This Is a Separate Lesson

The Linux jump host solves **API** access: `kubectl`, Helm, and
private ACR build/push all work from inside the VNet. It does **not**
automatically make a workstation browser able to reach private Anyscale
workspace or service hostnames launched from the public console.

Here is the flow that trips people up:

1. The public console at `https://console.azure.anyscale.com` is reachable from
   your workstation.
2. Workspace, Ray dashboard, VS Code, and service links redirect the browser to
   private `*.azure.anyscaleuserdata.com` hostnames.
3. Those hostnames require private DNS resolution and routing to the internal
   app-routing Gateway load balancer — which a normal workstation does not have.

## Preferred Path: Windows Browser Jump Host

The simplest workshop path is the optional **Windows 11 browser jump host** from
Module 1, reached through **Azure Bastion portal RDP** with Entra ID login
enabled for your user or group. Because the browser itself runs inside the VNet,
the private hostnames resolve and route natively — no proxy, no PAC file, no
hostname rewriting.

Enable it during Module 1:

```bash
./scripts/anyscale-aks.sh module 1 apply --enable-browser-host
./scripts/anyscale-aks.sh module 1 browser verify
```

`browser verify` confirms the host is ready for interactive login:

```output
[module1] PASS: Windows browser jump host has no public IP.
[module1] PASS: AADLoginForWindows extension Succeeded.
[module1] PASS: 1 VM login role assignment(s) present.
```

Then validate interactively after Module 3 deploys the workload:

```bash
./scripts/anyscale-aks.sh module 3 browser validate
```

This guides you to: open the Azure portal, connect to the Windows VM through
Bastion, sign in with Entra ID, open `https://console.azure.anyscale.com`, launch
a workspace or service URL, and confirm it resolves privately with valid TLS.

## Lightweight Developer Path

A dedicated Firefox or Chrome profile with a scoped PAC file or proxy extension,
using **SOCKS5 over Bastion SSH** to the Linux jump host with remote DNS enabled.
Keep it in a separate browser profile so it does not affect your normal browsing.

## Optional Demo Path

A browser running directly on the Linux jump host through a desktop session.

## Guardrails

- The Windows browser host is **never** used for Terraform, Podman, Anyscale CLI
  automation, or workload state ownership. It is browser-only.
- Do **not** use localhost hostname rewriting for TLS-sensitive Anyscale
  user-data hostnames — it breaks certificate validation.

## Why Browser Validation Is Not in Default Unattended e2e

Default unattended e2e stays non-interactive. It must not block on Azure portal
RDP, Windows desktop login, browser login, extension prompts, or manual console
navigation. So:

- Interactive browser validation is **skipped** by default.
- When `--teardown` is supplied, the summary notes that browser validation was
  skipped before cleanup.
- An optional non-interactive precheck is available:

  ```bash
  ./scripts/anyscale-aks.sh e2e --custom-image --include-browser-precheck
  ```

  The precheck validates only non-interactive prerequisites: the Windows VM
  exists and has no public IP, the `AADLoginForWindows` extension succeeded, the
  configured users/groups have VM login RBAC, Bastion is associated with the
  correct VNet, and the private DNS / Gateway dependencies exist after deploy.

## Clean up resources

Run browser validation **before** teardown — once Module 3 resources are gone, the
private hostnames no longer resolve. When you're finished, follow [Clean Up](cleanup.md).

## Return to

[Module 3: Deploy and Prove the Lab Workload](module-3-lab-workload.md)

## What to Validate Before Teardown

If you want to see the private URLs render, run `module 3 browser validate`
**before** `module 3 teardown`. Once the lab workload is gone, the private
hostnames no longer resolve.
