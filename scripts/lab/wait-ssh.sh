#!/usr/bin/env bash
# Wait until cloud-init finishes and SSH accepts connections for the ansible user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

SSH_USER="${LAB_SSH_USER:-ansible}"
SSH_KEY="${ROOT}/scripts/lab/keys/lab_id_ed25519"
TIMEOUT_SECS="${LAB_SSH_TIMEOUT_SECS:-600}"
SLEEP_SECS="${LAB_SSH_POLL_SECS:-10}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <fqdn>

Waits for SSH on the lab VM IP from inventory.
EOF
}

main() {
  local fqdn="${1:-}"
  [[ -n "${fqdn}" ]] || { usage; exit 1; }
  require_cmd ssh

  local vm_ip
  vm_ip="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_ip")"
  [[ -f "${SSH_KEY}" ]] || die "Missing SSH key ${SSH_KEY} — run keys-ensure.sh"

  local elapsed=0
  while (( elapsed < TIMEOUT_SECS )); do
    if ssh -i "${SSH_KEY}" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${SSH_USER}@${vm_ip}" 'cloud-init status --wait >/dev/null 2>&1 || true; echo ok' \
      2>/dev/null | grep -q ok; then
      log_info "SSH ready on ${fqdn} (${vm_ip})"
      return 0
    fi
    log_info "Waiting for SSH on ${vm_ip} (${elapsed}s / ${TIMEOUT_SECS}s)"
    sleep "${SLEEP_SECS}"
    elapsed=$((elapsed + SLEEP_SECS))
  done

  die "Timed out waiting for SSH on ${fqdn} (${vm_ip})"
}

main "$@"
