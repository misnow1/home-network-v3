#!/usr/bin/env bash
# Create local VM storage directories (not on NFS home — QEMU cannot use rootsquashed paths).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROFILE="lab"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i PROFILE]

Options:
  -i, --inventory PROFILE   Storage profile subdirectory (default: lab)
  -h, --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  local data_dir images_dir vms_dir seeds_dir qemu_group
  data_dir="$(vm_data_dir "${PROFILE}")"
  images_dir="$(vm_images_dir)"
  vms_dir="$(vm_vms_dir "${PROFILE}")"
  seeds_dir="$(vm_seeds_dir "${PROFILE}")"

  if [[ "${data_dir}" == "${HOME}"* ]]; then
    die "VM data dir must not be under NFS home (${data_dir}). Use /var/lib/libvirt/images/home-network-v3"
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "${images_dir}" "${vms_dir}" "${seeds_dir}"
    if getent group qemu >/dev/null 2>&1; then
      qemu_group=qemu
    elif getent group libvirt >/dev/null 2>&1; then
      qemu_group=libvirt
    else
      die "Neither qemu nor libvirt group found"
    fi
    local owner="${SUDO_USER:-${VM_DIR_OWNER:-}}"
    [[ -n "${owner}" ]] || die "Cannot determine target owner. Run via sudo, or set VM_DIR_OWNER=<user>."
    chown "${owner}:${qemu_group}" "$(vm_data_base)" "${images_dir}" "${data_dir}" "${vms_dir}" "${seeds_dir}"
    chmod 775 "$(vm_data_base)" "${images_dir}" "${data_dir}" "${vms_dir}" "${seeds_dir}"
    log_info "Created ${data_dir} (owner ${owner}:${qemu_group}, mode 775)"
    return 0
  fi

  if [[ ! -d "${vms_dir}" ]]; then
    die "Missing ${vms_dir}. Run once: sudo $0 -i ${PROFILE}"
  fi

  mkdir -p "${images_dir}" "${vms_dir}" "${seeds_dir}"
  if [[ ! -w "${vms_dir}" ]]; then
    die "Cannot write to ${vms_dir}. Run: sudo $0 -i ${PROFILE}"
  fi
  log_info "VM storage ready at ${data_dir}"
}

main "$@"
