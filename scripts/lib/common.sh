#!/usr/bin/env bash
# Shared helpers for all test and lab scripts.
set -euo pipefail

# Lab VM scripts target the system libvirt instance on kvm01 (not qemu:///session).
export LIBVIRT_DEFAULT_URI="${LIBVIRT_DEFAULT_URI:-qemu:///system}"

# VM disks and cloud images must live on local disk — NFS home (rootsquash) breaks QEMU access.
lab_data_dir() {
  printf '%s' "${LAB_DATA_DIR:-/var/lib/libvirt/images/home-network-v3}"
}

lab_images_dir() {
  printf '%s/images' "$(lab_data_dir)"
}

lab_vms_dir() {
  printf '%s/vms' "$(lab_data_dir)"
}

lab_seeds_dir() {
  printf '%s/seeds' "$(lab_data_dir)"
}

lab_cloud_image_path() {
  printf '%s/noble-server-cloudimg-amd64.img' "$(lab_images_dir)"
}

repo_root() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  cd "$(dirname "${src}")/../.." && pwd
}

log_info() {
  printf '[INFO] %s\n' "$*" >&2
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  log_error "$@"
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

require_repo_root() {
  local root
  root="$(repo_root)"
  [[ -f "${root}/ansible.cfg" ]] || die "ansible.cfg not found — run from the repository checkout"
  printf '%s' "${root}"
}

vault_password_file() {
  local root="$1"
  if [[ -f "${root}/.vault_pass_lab" ]]; then
    printf '%s/.vault_pass_lab' "${root}"
  elif [[ -n "${VAULT_PASS_LAB:-}" ]]; then
    printf '%s/.vault_pass_lab' "${root}"
  else
    die "Missing lab vault password. Create ${root}/.vault_pass_lab or set VAULT_PASS_LAB"
  fi
}

ensure_vault_password_file() {
  local root="$1"
  local vault_file
  vault_file="$(vault_password_file "${root}")"
  if [[ ! -f "${vault_file}" && -n "${VAULT_PASS_LAB:-}" ]]; then
    printf '%s' "${VAULT_PASS_LAB}" > "${vault_file}"
    chmod 600 "${vault_file}"
  fi
  [[ -f "${vault_file}" ]] || die "Missing ${vault_file} — see docs/vault-schema.md"
  printf '%s' "${vault_file}"
}

inventory_is_lab() {
  local inventory_path="$1"
  [[ "${inventory_path}" == *"/lab/"* || "${inventory_path}" == *"/lab" ]]
}

inventory_is_production() {
  local inventory_path="$1"
  [[ "${inventory_path}" == *"/production/"* || "${inventory_path}" == *"/production" ]]
}
