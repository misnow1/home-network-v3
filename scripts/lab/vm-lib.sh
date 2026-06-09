#!/usr/bin/env bash
# Shared helpers for lab VM create/destroy/wait scripts.
# Sourced after ROOT and scripts/lib/common.sh are loaded.
set -euo pipefail

vm_render_cloud_init() {
  local mode="$1"
  local fqdn="$2"
  local vm_name="$3"
  local vm_ip="${4:-}"
  local pubkey seed_dir user_data meta_data template

  pubkey="$(cat "${ROOT}/scripts/lab/keys/lab_id_ed25519.pub")"
  seed_dir="$(lab_seeds_dir)/${vm_name}"
  mkdir -p "${seed_dir}"

  export LAB_FQDN="${fqdn}"
  export LAB_HOST_SHORT="${fqdn%%.*}"
  export LAB_VM_NAME="${vm_name}"
  export LAB_VM_IP="${vm_ip}"
  export LAB_SSH_PUBKEY="${pubkey}"
  export LAB_NIC="${LAB_NIC:-enp1s0}"

  if [[ "${mode}" == "dhcp" ]]; then
    template="${ROOT}/scripts/lab/cloud-init/user-data-dhcp.tmpl"
    if [[ -n "${LAB_DNS_SEARCH:-}" ]]; then
      export LAB_DNS_SEARCH_YAML="            nameservers:
              search:
                - ${LAB_DNS_SEARCH}"
    else
      export LAB_DNS_SEARCH_YAML=""
    fi
  else
    template="${ROOT}/scripts/lab/cloud-init/user-data.tmpl"
  fi

  user_data="${seed_dir}/user-data"
  meta_data="${seed_dir}/meta-data"
  envsubst < "${template}" > "${user_data}"
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

vm_validate_bridge() {
  local bridge="$1"
  require_cmd ip
  ip link show "${bridge}" >/dev/null 2>&1 \
    || die "Host bridge ${bridge} not found — create it on the hypervisor first"
}

vm_ensure_libvirt_network() {
  local net_name="$1"
  require_cmd virsh
  virsh net-info "${net_name}" >/dev/null 2>&1 \
    || die "Libvirt network ${net_name} not found — define it with virsh net-define first"

  local active
  active="$(virsh net-info "${net_name}" | awk '/^Active:/ { print $NF }')"
  if [[ "${active}" != "yes" ]]; then
    log_info "Starting libvirt network ${net_name}"
    virsh net-start "${net_name}" >/dev/null \
      || die "Failed to start libvirt network ${net_name}"
  fi
}

vm_build_network_arg() {
  local bridge="${1:-}"
  local net_name="${2:-home-dc-lab}"
  if [[ -n "${bridge}" ]]; then
    printf 'bridge=%s,model=virtio' "${bridge}"
  else
    printf 'network=%s,model=virtio' "${net_name}"
  fi
}

vm_discover_ip() {
  local vm_name="$1"
  require_cmd virsh
  virsh domifaddr "${vm_name}" --source agent 2>/dev/null \
    | awk '/ipv4/ { print $4 }' \
    | cut -d/ -f1 \
    | head -1
}

vm_wait_for_ip() {
  local vm_name="$1"
  local timeout_secs="${2:-300}"
  local sleep_secs="${3:-5}"
  local elapsed=0 ip=""

  while (( elapsed < timeout_secs )); do
    ip="$(vm_discover_ip "${vm_name}" || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    log_info "Waiting for guest-agent IP on ${vm_name} (${elapsed}s / ${timeout_secs}s)"
    sleep "${sleep_secs}"
    elapsed=$((elapsed + sleep_secs))
  done

  die "Timed out waiting for IP on ${vm_name} (is qemu-guest-agent running?)"
}

vm_create_disk() {
  local disk_path="$1"
  local base_image="$2"
  local disk_gb="${3:-}"

  mkdir -p "$(lab_vms_dir)"
  if [[ -f "${disk_path}" ]]; then
    return 0
  fi
  if [[ -n "${disk_gb}" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_path}" "${disk_gb}G"
  else
    qemu-img create -f qcow2 -F qcow2 -b "${base_image}" "${disk_path}"
  fi
  chmod 660 "${disk_path}" 2>/dev/null || true
}

vm_destroy_artifacts() {
  local vm_name="$1"
  local disk_path seed_dir
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
