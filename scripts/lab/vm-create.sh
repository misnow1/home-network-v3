#!/usr/bin/env bash
# Create a lab VM from the Ubuntu 24.04 cloud image with cloud-init.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

LAB_NIC="${LAB_NIC:-enp1s0}"
NET_NAME="${LAB_NET_NAME:-home-dc-lab}"
MEMORY_MB="${LAB_VM_MEMORY_MB:-3072}"
VCPUS="${LAB_VM_VCPUS:-2}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <fqdn>

Example:
  $(basename "$0") member01.lab.test
EOF
}

render_cloud_init() {
  local fqdn="$1"
  local vm_name="$2"
  local vm_ip="$3"
  local host_short="${fqdn%%.*}"
  local pubkey seed_dir user_data meta_data

  pubkey="$(cat "${ROOT}/scripts/lab/keys/lab_id_ed25519.pub")"
  seed_dir="$(lab_seeds_dir)/${vm_name}"
  mkdir -p "${seed_dir}"

  export LAB_FQDN="${fqdn}"
  export LAB_HOST_SHORT="${host_short}"
  export LAB_VM_NAME="${vm_name}"
  export LAB_VM_IP="${vm_ip}"
  export LAB_SSH_PUBKEY="${pubkey}"
  export LAB_NIC="${LAB_NIC}"

  user_data="${seed_dir}/user-data"
  meta_data="${seed_dir}/meta-data"
  envsubst < "${ROOT}/scripts/lab/cloud-init/user-data.tmpl" > "${user_data}"
  envsubst < "${ROOT}/scripts/lab/cloud-init/meta-data.tmpl" > "${meta_data}"

  if command -v cloud-localds >/dev/null 2>&1; then
    cloud-localds "${seed_dir}/seed.iso" "${user_data}" "${meta_data}"
    printf '%s' "${seed_dir}/seed.iso"
    return 0
  fi

  require_cmd genisoimage
  genisoimage -output "${seed_dir}/seed.iso" -volid cidata -joliet -rock \
    "${user_data}" "${meta_data}" >/dev/null
  printf '%s' "${seed_dir}/seed.iso"
}

main() {
  local fqdn="${1:-}"
  [[ -n "${fqdn}" ]] || { usage; exit 1; }

  require_cmd virsh
  require_cmd virt-install
  require_cmd qemu-img
  require_cmd envsubst

  "${ROOT}/scripts/lab/network-ensure.sh" >/dev/null
  "${ROOT}/scripts/lab/keys-ensure.sh" >/dev/null
  "${ROOT}/scripts/lab/dirs-ensure.sh" >/dev/null
  "${ROOT}/scripts/lab/image-ensure.sh" >/dev/null

  local vm_name vm_ip base_image disk_path seed_iso
  vm_name="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_name")"
  vm_ip="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_ip")"
  local host_memory host_disk_gb
  host_memory="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_memory_mb" 2>/dev/null || true)"
  if [[ -n "${host_memory}" ]]; then
    MEMORY_MB="${host_memory}"
  fi
  host_disk_gb="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_vm_disk_gb" 2>/dev/null || true)"
  base_image="$(lab_cloud_image_path)"
  disk_path="$(lab_vms_dir)/${vm_name}.qcow2"

  if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    die "VM ${vm_name} already exists — run vm-destroy.sh first"
  fi

  mkdir -p "$(lab_vms_dir)"
  if [[ ! -f "${disk_path}" ]]; then
    if [[ -n "${host_disk_gb}" ]]; then
      qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_path}" "${host_disk_gb}G"
    else
      qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_path}"
    fi
    chmod 660 "${disk_path}" 2>/dev/null || true
  fi

  seed_iso="$(render_cloud_init "${fqdn}" "${vm_name}" "${vm_ip}")"
  chmod 644 "${seed_iso}" 2>/dev/null || true

  local virt_args=(
    --name "${vm_name}"
    --memory "${MEMORY_MB}"
    --vcpus "${VCPUS}"
    --disk "path=${disk_path},format=qcow2,bus=virtio"
    --disk "path=${seed_iso},device=cdrom"
    --os-variant ubuntu24.04
    --network "network=${NET_NAME},model=virtio"
    --graphics none
    --console pty,target.type=serial
    --import
    --noautoconsole
  )

  local nested_virt
  nested_virt="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${fqdn}" "lab_nested_virt" 2>/dev/null || true)"
  if [[ "${nested_virt,,}" == "true" ]]; then
    virt_args+=(--cpu host-passthrough)
  fi

  log_info "Creating VM ${vm_name} (${fqdn} @ ${vm_ip})"
  virt-install "${virt_args[@]}"
  log_info "VM ${vm_name} created"
}

main "$@"
