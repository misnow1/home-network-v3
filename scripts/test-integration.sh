#!/usr/bin/env bash
# Tier 3 integration tests: libvirt lab network and VM lifecycle on kvm01.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

LAB_HOST="${LAB_HOST:-member01.lab.test}"
SKIP_VM_TESTS="${SKIP_VM_TESTS:-0}"

main() {
  if [[ -x "${ROOT}/.venv/bin/ansible-playbook" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi

  require_cmd virsh
  require_cmd virt-install

  log_info "Ensuring lab storage directories (local disk, not NFS home)"
  "${ROOT}/scripts/lab/dirs-ensure.sh"

  log_info "Ensuring lab libvirt network"
  "${ROOT}/scripts/lab/network-ensure.sh"

  log_info "Ensuring lab SSH keypair"
  "${ROOT}/scripts/lab/keys-ensure.sh"

  if [[ "${SKIP_VM_TESTS}" == "1" ]]; then
    log_warn "SKIP_VM_TESTS=1 — skipping VM create/destroy cycle"
    log_info "test-integration.sh passed (network and keys only)"
    return 0
  fi

  log_info "Ensuring Ubuntu cloud image"
  "${ROOT}/scripts/lab/image-ensure.sh"

  log_info "Integration VM lifecycle for ${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"

  log_info "Waiting for SSH on ${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Destroying integration test VM ${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"

  log_info "test-integration.sh passed"
}

main "$@"
