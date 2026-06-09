#!/usr/bin/env bash
# Destroy and undefine a lab VM and remove its local disk overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/lab/vm-lib.sh"

VM_NAME=""
INVENTORY_FQDN=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <fqdn>              Destroy VM by inventory FQDN
  $(basename "$0") --name <vm-name>    Destroy VM by libvirt domain name

Examples:
  $(basename "$0") member01.lab.test
  $(basename "$0") --name cka-cp1
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
    VM_NAME="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_vm_name")"
  fi

  vm_destroy_artifacts "${VM_NAME}"
}

main "$@"
