#!/usr/bin/env bash
# Where is this command running: the operator workstation or an in-VNet Azure VM?
#
# Probed from Azure IMDS, which only answers from inside an Azure VM. This is a
# fact about the machine, in the same spirit as the DNS probes in setup.sh
# (host_resolves_privately, private_aks_api_dns_ready): never gate capability on
# a declared mode, because the machine's actual position is what decides whether
# a private endpoint is reachable.
#
# Use this only for guidance and footgun guards — "should bootstrap install VM
# tooling here", "which az login to suggest". Reachability of a specific private
# endpoint still belongs to the per-endpoint DNS probes.

running_on_azure_vm() {
  curl -fsS -m 2 -H 'Metadata: true' \
    'http://169.254.169.254/metadata/instance/compute/vmId?api-version=2021-02-01&format=text' \
    >/dev/null 2>&1
}
