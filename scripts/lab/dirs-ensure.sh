#!/usr/bin/env bash
# Create local lab storage directories (not on NFS home — QEMU cannot use rootsquashed paths).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

main() {
  local data_dir images_dir vms_dir seeds_dir qemu_group
  data_dir="$(lab_data_dir)"
  images_dir="$(lab_images_dir)"
  vms_dir="$(lab_vms_dir)"
  seeds_dir="$(lab_seeds_dir)"

  if [[ "${data_dir}" == "${HOME}"* ]]; then
    die "LAB_DATA_DIR must not be under NFS home (${data_dir}). Use /var/lib/libvirt/images/home-network-v3"
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
    # Owner = the invoking admin (SUDO_USER when run via sudo) or an explicit
    # LAB_DIR_OWNER override. Avoid a hardcoded username so this is portable.
    local owner="${SUDO_USER:-${LAB_DIR_OWNER:-}}"
    [[ -n "${owner}" ]] || die "Cannot determine target owner. Run via sudo, or set LAB_DIR_OWNER=<user>."
    chown "${owner}:${qemu_group}" "${data_dir}" "${images_dir}" "${vms_dir}" "${seeds_dir}"
    chmod 775 "${data_dir}" "${images_dir}" "${vms_dir}" "${seeds_dir}"
    log_info "Created ${data_dir} (owner ${owner}:${qemu_group}, mode 775)"
    return 0
  fi

  if [[ ! -d "${data_dir}" ]]; then
    die "Missing ${data_dir}. Run once: sudo ./scripts/lab/dirs-ensure.sh"
  fi

  mkdir -p "${images_dir}" "${vms_dir}" "${seeds_dir}"
  if [[ ! -w "${vms_dir}" ]]; then
    die "Cannot write to ${vms_dir}. Run: sudo ./scripts/lab/dirs-ensure.sh"
  fi
  log_info "Lab storage ready at ${data_dir}"
}

main "$@"
