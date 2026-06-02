#!/usr/bin/env bash
# Destroy and undefine a lab VM and remove its local disk overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <fqdn>

Example:
  $(basename "$0") member01.lab.test
EOF
}

main() {
  local fqdn="${1:-}"
  [[ -n "${fqdn}" ]] || { usage; exit 1; }
  require_cmd virsh

  local vm_name disk_path seed_dir
  vm_name="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_name")"
  disk_path="$(lab_vms_dir)/${vm_name}.qcow2"
  seed_dir="$(lab_seeds_dir)/${vm_name}"

  if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    log_info "Destroying VM ${vm_name}"
    virsh destroy "${vm_name}" 2>/dev/null || true
    virsh undefine "${vm_name}" --remove-all-storage 2>/dev/null || virsh undefine "${vm_name}" || true
  else
    log_info "VM ${vm_name} not defined"
  fi

  rm -f "${disk_path}"
  rm -rf "${seed_dir}"
  log_info "Removed local artifacts for ${vm_name}"
}

main "$@"
