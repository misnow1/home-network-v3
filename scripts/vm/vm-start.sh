#!/usr/bin/env bash
# Start a VM previously prepared with vm-create.sh --prepare.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

PROFILE="lab"
INVENTORY_FQDN=""
VM_NAME=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [-i PROFILE] <inventory-fqdn>   Start inventory VM by FQDN
  $(basename "$0") [-i PROFILE] --name <vm-name>     Start ad-hoc VM by libvirt name

Examples:
  $(basename "$0") -i production bastion.home.2123studios.com
  $(basename "$0") --name cka-cp1
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      --name)
        VM_NAME="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        [[ -z "${INVENTORY_FQDN}" ]] || die "Unexpected argument: $1"
        INVENTORY_FQDN="$1"
        shift
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ -n "${INVENTORY_FQDN}" && -n "${VM_NAME}" ]]; then
    die "Use either --name or an inventory FQDN, not both"
  fi
  if [[ -z "${INVENTORY_FQDN}" && -z "${VM_NAME}" ]]; then
    usage
    exit 1
  fi

  require_cmd virsh

  if [[ -n "${INVENTORY_FQDN}" ]]; then
    VM_NAME="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_name")"
  fi

  virsh dominfo "${VM_NAME}" >/dev/null 2>&1 \
    || die "VM ${VM_NAME} is not defined — run vm-create.sh --prepare first"

  local state
  state="$(virsh domstate "${VM_NAME}" 2>/dev/null || true)"
  if [[ "${state}" == "running" ]]; then
    log_info "VM ${VM_NAME} is already running"
    exit 0
  fi

  log_info "Starting VM ${VM_NAME}"
  virsh start "${VM_NAME}" >/dev/null
  log_info "VM ${VM_NAME} started"
}

main "$@"
