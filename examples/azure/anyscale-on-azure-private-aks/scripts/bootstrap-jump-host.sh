#!/usr/bin/env bash
# bootstrap-jump-host.sh — VM-local setup for the Linux automation jump host.
#
# Runs ON the Ubuntu 24.04 jump host (Module 2 bootstrap). Installs the operator
# toolchain, ensures the repo lives at the canonical path, and creates a repo
# local .venv with the Anyscale CLI. Idempotent: re-running only fills gaps.
#
# This script never stores tokens. Anyscale auth on the jump host is interactive
# OAuth — `ANYSCALE_HOST=https://console.azure.anyscale.com anyscale login` — which
# is sufficient here because the in-VNet jump host reaches private storage directly.
# `ANYSCALE_CLI_TOKEN` stays empty and is optional, used only for non-interactive
# in-pod or CI CLI flows.
set -euo pipefail

REPO_PATH="${ANYSCALE_AKS_REPO_PATH:-/opt/anyscale-aks-sample}"
REPO_URL="${ANYSCALE_AKS_REPO_URL:-}"

LOG_INFO_PREFIX="bootstrap"
LOG_WARN_PREFIX="bootstrap"
LOG_ERROR_PREFIX="bootstrap"

if [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh" ]]; then
  # shellcheck source=lib/log.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"
else
  log() { printf '[bootstrap] %s\n' "$*"; }
  warn() { printf '[bootstrap] WARN %s\n' "$*" >&2; }
  die() { printf '[bootstrap] ERROR %s\n' "$*" >&2; exit 1; }
fi

require_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "bootstrap-jump-host.sh must run on the Linux jump host."
}

apt_install() {
  log "Installing base packages via apt: $*"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

have() { command -v "$1" >/dev/null 2>&1; }

install_base_packages() {
  local pkgs=()
  have curl || pkgs+=(curl)
  have jq || pkgs+=(jq)
  have rsync || pkgs+=(rsync)
  have lsof || pkgs+=(lsof)
  have git || pkgs+=(git)
  have unzip || pkgs+=(unzip)
  have python3 || pkgs+=(python3)
  # python venv + pip support
  pkgs+=(python3-venv python3-pip ca-certificates gnupg)
  # gettext-base provides envsubst, used to render the Ratify (Image Integrity) CRDs.
  have envsubst || pkgs+=(gettext-base)
  apt_install "${pkgs[@]}"
}

install_azure_cli() {
  if have az; then
    log "Azure CLI present: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo unknown)"
    return 0
  fi
  log "Installing Azure CLI (Microsoft script)..."
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
}

ensure_azure_cli_identity_login() {
  if az account show --only-show-errors >/dev/null 2>&1; then
    log "Azure CLI already authenticated."
    return 0
  fi
  log "Logging Azure CLI in with the jump host managed identity..."
  az login --identity --only-show-errors >/dev/null
}

install_kubectl() {
  if have kubectl; then
    log "kubectl present."
    return 0
  fi
  log "Installing kubectl + kubelogin via Azure CLI (az aks install-cli)..."
  sudo az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin
}

install_kubelogin() {
  have kubelogin && { log "kubelogin present."; return 0; }
  warn "kubelogin not found after kubectl install; attempting az aks install-cli again."
  sudo az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin || true
}

install_helm() {
  have helm && { log "Helm present."; return 0; }
  log "Installing Helm (official script)..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
}

install_uv() {
  have uv && { log "uv present."; return 0; }
  log "Installing uv (Astral installer)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # uv installs to ~/.local/bin, which is only on PATH for interactive login
  # shells (~/.profile). The harness runs over non-login SSH sessions, so
  # symlink uv into /usr/local/bin to make it discoverable everywhere.
  export PATH="${HOME}/.local/bin:${PATH}"
  if [[ -x "${HOME}/.local/bin/uv" ]]; then
    sudo ln -sf "${HOME}/.local/bin/uv" /usr/local/bin/uv
    [[ -x "${HOME}/.local/bin/uvx" ]] && sudo ln -sf "${HOME}/.local/bin/uvx" /usr/local/bin/uvx
  fi
}

install_podman() {
  have podman && { log "Podman present."; return 0; }
  log "Installing Podman via apt..."
  apt_install podman
}

# Pinned Notation toolchain for image signing. Checksums are the official
# release sha256 values for the linux/amd64 artifacts.
NOTATION_VERSION="1.3.2"
NOTATION_LINUX_AMD64_SHA256="e1a0f060308086bf8020b2d31defb7c5348f133ca0dba6a1a7820ef3cbb6dfe5"
NOTATION_AZURE_KV_PLUGIN_VERSION="1.2.1"
NOTATION_AZURE_KV_PLUGIN_SHA256="67c5ccaaf28dd44d2b6572684d84e344a02c2258af1d65ead3910b3156d3eaf5"

install_notation_azure_kv_plugin() {
  if notation plugin ls 2>/dev/null | grep -q 'azure-kv'; then
    log "notation azure-kv plugin already installed."
    return 0
  fi
  log "Installing notation-azure-kv plugin v${NOTATION_AZURE_KV_PLUGIN_VERSION}..."
  notation plugin install \
    --url "https://github.com/Azure/notation-azure-kv/releases/download/v${NOTATION_AZURE_KV_PLUGIN_VERSION}/notation-azure-kv_${NOTATION_AZURE_KV_PLUGIN_VERSION}_linux_amd64.tar.gz" \
    --sha256sum "${NOTATION_AZURE_KV_PLUGIN_SHA256}"
}

install_notation() {
  if have notation; then
    log "notation present: $(notation version 2>/dev/null | awk '/Version/{print $2; exit}' || echo unknown)"
  else
    log "Installing notation v${NOTATION_VERSION} (linux amd64)..."
    local tmp
    tmp="$(mktemp -d)"
    curl -sSfL "https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_amd64.tar.gz" -o "${tmp}/notation.tar.gz"
    printf '%s  %s\n' "${NOTATION_LINUX_AMD64_SHA256}" "${tmp}/notation.tar.gz" | sha256sum -c -
    sudo tar -xzf "${tmp}/notation.tar.gz" -C /usr/local/bin notation
    rm -rf "${tmp}"
  fi
  install_notation_azure_kv_plugin
}

# Pinned ORAS CLI for OCI referrer attach/discover (SBOM workflow). Checksum is
# the official release sha256 for the linux/amd64 artifact.
ORAS_VERSION="1.3.2"
ORAS_LINUX_AMD64_SHA256="9229ccc6d17bb282039ad4a69abb16dcb887a5bce567c075d731d9b3c7ad8eaf"

install_oras() {
  if have oras; then
    log "oras present: $(oras version 2>/dev/null | awk '/Version/{print $2; exit}' || echo unknown)"
    return 0
  fi
  log "Installing oras v${ORAS_VERSION} (linux amd64)..."
  local tmp
  tmp="$(mktemp -d)"
  curl -sSfL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_amd64.tar.gz" -o "${tmp}/oras.tar.gz"
  printf '%s  %s\n' "${ORAS_LINUX_AMD64_SHA256}" "${tmp}/oras.tar.gz" | sha256sum -c -
  sudo tar -xzf "${tmp}/oras.tar.gz" -C /usr/local/bin oras
  rm -rf "${tmp}"
}

# Pinned Syft CLI for SPDX SBOM generation. Checksum is the official release
# sha256 for the linux/amd64 artifact.
SYFT_VERSION="1.45.1"
SYFT_LINUX_AMD64_SHA256="20c84195e24927f50a3b2269946be51f4c4abc9d2f145fee7388b4199149f716"

install_syft() {
  if have syft; then
    log "syft present: $(syft version 2>/dev/null | awk '/Version/{print $2; exit}' || echo unknown)"
    return 0
  fi
  log "Installing syft v${SYFT_VERSION} (linux amd64)..."
  local tmp
  tmp="$(mktemp -d)"
  curl -sSfL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_amd64.tar.gz" -o "${tmp}/syft.tar.gz"
  printf '%s  %s\n' "${SYFT_LINUX_AMD64_SHA256}" "${tmp}/syft.tar.gz" | sha256sum -c -
  sudo tar -xzf "${tmp}/syft.tar.gz" -C /usr/local/bin syft
  rm -rf "${tmp}"
}

ensure_repo() {
  if [[ -d "${REPO_PATH}/.git" || -f "${REPO_PATH}/scripts/anyscale-aks.sh" ]]; then
    log "Repo already present at ${REPO_PATH}."
    return 0
  fi
  if [[ -n "${REPO_URL}" ]]; then
    log "Cloning ${REPO_URL} -> ${REPO_PATH}..."
    sudo mkdir -p "${REPO_PATH}"
    sudo chown -R "$(id -un)" "${REPO_PATH}"
    git clone "${REPO_URL}" "${REPO_PATH}"
  else
    warn "Repo not found at ${REPO_PATH} and ANYSCALE_AKS_REPO_URL not set."
    warn "Run 'module 2 sync' from the workstation to push the repo, then re-run bootstrap."
  fi
}

ensure_venv() {
  local repo="${REPO_PATH}"
  [[ -d "${repo}" ]] || repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export PATH="${HOME}/.local/bin:${PATH}"
  if [[ -x "${repo}/.venv/bin/anyscale" ]]; then
    log "Anyscale CLI venv already present at ${repo}/.venv."
    return 0
  fi
  log "Creating repo-local .venv with the Anyscale CLI..."
  ( cd "${repo}" \
    && uv venv .venv \
    && UV_CACHE_DIR="${repo}/.cache/uv-cache" uv pip install --python .venv/bin/python anyscale )
}

main() {
  require_linux
  install_base_packages
  install_azure_cli
  ensure_azure_cli_identity_login
  install_kubectl
  install_kubelogin
  install_helm
  install_uv
  install_podman
  install_notation
  install_oras
  install_syft
  ensure_repo
  ensure_venv
  log "Bootstrap complete. Validate with: ./scripts/anyscale-aks.sh module 2 verify"
  log "Note: Podman on a fresh VM may need 'podman system migrate' or a rootless setup for AMD64 builds."
}

main "$@"
