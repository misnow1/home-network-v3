#!/usr/bin/env bash
# Smoke test for vm-create.sh --dry-run (no libvirt define).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

main() {
  vm_name="dry-run-test-$$"
  tmp_base="${ROOT}/.tmp-vm-create-dry-run-$$"
  trap 'rm -rf "${tmp_base}"' EXIT
  mkdir -p "${tmp_base}"

  export VM_DATA_BASE="${tmp_base}/vm-data"
  mkdir -p "${VM_DATA_BASE}/images" "${VM_DATA_BASE}/lab/vms" "${VM_DATA_BASE}/lab/seeds"
  qemu-img create -f qcow2 "${VM_DATA_BASE}/images/noble-server-cloudimg-amd64.img" 16M >/dev/null

  "${ROOT}/scripts/vm/keys-ensure.sh" -i lab >/dev/null
  "${ROOT}/scripts/vm/vm-create.sh" -i lab --dry-run \
    --name "${vm_name}" \
    --fqdn "${vm_name}.lab.test" \
    --ip 192.168.122.50 \
    --disk-gb 2

  seed_dir="$(vm_seeds_dir lab)/${vm_name}"
  disk_path="$(vm_vms_dir lab)/${vm_name}.qcow2"

  [[ -f "${disk_path}" ]] || die "missing disk ${disk_path}"
  [[ -f "${seed_dir}/seed.iso" ]] || die "missing seed ISO"
  [[ -f "${seed_dir}/install.sh" ]] || die "missing install.sh"
  [[ -x "${seed_dir}/install.sh" ]] || die "install.sh not executable"
  [[ -f "${seed_dir}/manifest.txt" ]] || die "missing manifest.txt"
  grep -q "vm_name=${vm_name}" "${seed_dir}/manifest.txt"

  "${ROOT}/scripts/vm/vm-create.sh" -i lab --dry-run \
    --name "${vm_name}-dhcp" \
    --fqdn "${vm_name}-dhcp.lab.test" \
    --dhcp \
    --disk-gb 2

  dhcp_seed_dir="$(vm_seeds_dir lab)/${vm_name}-dhcp"
  grep -q '^vm_mac=' "${dhcp_seed_dir}/manifest.txt" \
    || die "missing vm_mac in DHCP dry-run manifest"
  grep -q 'network_mode=dhcp' "${dhcp_seed_dir}/manifest.txt"

  log_info "test-vm-create-dry-run.sh passed"
}

main "$@"
