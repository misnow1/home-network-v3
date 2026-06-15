#!/usr/bin/env bash
# Shared helpers for VM create/destroy/wait scripts.
# Sourced after ROOT and scripts/lib/common.sh are loaded.
set -euo pipefail

vm_ssh_key_path() {
  local profile="${1:-lab}"
  printf '%s/scripts/vm/keys/%s' "${ROOT}" "$(vm_profile_key_basename "${profile}")"
}

vm_ssh_pub_key_path() {
  printf '%s.pub' "$(vm_ssh_key_path "${1:-lab}")"
}

vm_inventory_host_json() {
  local profile="$1"
  local fqdn="$2"
  require_cmd ansible-inventory
  require_cmd python3
  if [[ -x "${ROOT}/.venv/bin/ansible-inventory" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi
  local inventory
  inventory="$(vm_profile_inventory "${profile}")"
  ANSIBLE_CONFIG="${ROOT}/ansible.cfg" ansible-inventory \
    -i "${inventory}" \
    --host "${fqdn}"
}

vm_build_static_dns_yaml() {
  local dns_servers_json="${1:-[]}"
  local dns_search="${2:-}"
  python3 - "${dns_servers_json}" "${dns_search}" <<'PY'
import json, sys

servers = json.loads(sys.argv[1] or "[]")
search = sys.argv[2]
if not servers and not search:
    print("")
    sys.exit(0)
lines = ["            nameservers:"]
if servers:
    lines.append("              addresses:")
    for addr in servers:
        lines.append(f"                - {addr}")
if search:
    lines.append("              search:")
    lines.append(f"                - {search}")
print("\n".join(lines))
PY
}

vm_build_dhcp_dns_search_yaml() {
  local dns_search="${1:-}"
  if [[ -z "${dns_search}" ]]; then
    export VM_DNS_SEARCH_YAML=""
    return 0
  fi
  export VM_DNS_SEARCH_YAML="            nameservers:
              search:
                - ${dns_search}"
}

vm_render_cloud_init() {
  local profile="$1"
  local mode="$2"
  local fqdn="$3"
  local vm_name="$4"
  local vm_ip="${5:-}"
  local pubkey seed_dir user_data meta_data template

  pubkey="$(cat "$(vm_ssh_pub_key_path "${profile}")")"
  seed_dir="$(vm_seeds_dir "${profile}")/${vm_name}"
  mkdir -p "${seed_dir}"

  export VM_FQDN="${fqdn}"
  export VM_HOST_SHORT="${fqdn%%.*}"
  export VM_INSTANCE_ID="${vm_name}"
  export VM_IP="${vm_ip}"
  export VM_SSH_PUBKEY="${pubkey}"
  export VM_NIC="${VM_NIC:-enp1s0}"

  if [[ "${mode}" == "dhcp" ]]; then
    template="${ROOT}/scripts/vm/cloud-init/user-data-dhcp.tmpl"
    vm_build_dhcp_dns_search_yaml "${VM_DNS_SEARCH:-}"
  else
    template="${ROOT}/scripts/vm/cloud-init/user-data.tmpl"
    export VM_GATEWAY="${VM_GATEWAY:?VM_GATEWAY required for static cloud-init}"
    export VM_SUBNET_PREFIX="${VM_SUBNET_PREFIX:-24}"
    export VM_DNS_SERVERS_YAML="$(vm_build_static_dns_yaml "${VM_DNS_SERVERS_JSON:-[]}" "${VM_DNS_SEARCH:-}")"
  fi

  user_data="${seed_dir}/user-data"
  meta_data="${seed_dir}/meta-data"
  envsubst < "${template}" > "${user_data}"
  envsubst < "${ROOT}/scripts/vm/cloud-init/meta-data.tmpl" > "${meta_data}"

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
  local profile="$1"
  local disk_path="$2"
  local base_image="$3"
  local disk_gb="${4:-}"

  mkdir -p "$(vm_vms_dir "${profile}")"
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
  local profile="$1"
  local vm_name="$2"
  local disk_path seed_dir
  disk_path="$(vm_vms_dir "${profile}")/${vm_name}.qcow2"
  seed_dir="$(vm_seeds_dir "${profile}")/${vm_name}"

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

vm_ensure_network_for_profile() {
  local profile="$1"
  local net_name="$2"
  local bridge="${3:-}"

  if [[ -n "${bridge}" ]]; then
    vm_validate_bridge "${bridge}"
    return 0
  fi

  if [[ "${profile}" == "lab" && "${net_name}" == "home-dc-lab" ]]; then
    "${ROOT}/scripts/lab/network-ensure.sh" >/dev/null
    return 0
  fi

  vm_ensure_libvirt_network "${net_name}"
}

vm_inventory_lookup() {
  local profile="$1"
  local fqdn="$2"
  local key="$3"
  "${ROOT}/scripts/vm/inventory-host-var.sh" -i "${profile}" "${fqdn}" "${key}"
}

vm_inventory_lookup_optional() {
  local profile="$1"
  local fqdn="$2"
  local key="$3"
  vm_inventory_lookup "${profile}" "${fqdn}" "${key}" 2>/dev/null || true
}

load_inventory_network_exports() {
  local profile="$1"
  local fqdn="$2"
  export VM_GATEWAY="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_gateway")"
  export VM_SUBNET_PREFIX="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_subnet_prefix")"
  export VM_DNS_SEARCH="$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_dns_search")"
  export VM_DNS_SERVERS_JSON="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_dns_servers")"
}

vm_host_uses_dhcp() {
  local profile="$1"
  local fqdn="$2"
  local use_dhcp vm_ip
  use_dhcp="$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_use_dhcp")"
  if [[ "${use_dhcp,,}" == "true" ]]; then
    return 0
  fi
  vm_ip="$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_ip")"
  [[ -z "${vm_ip}" ]]
}

vm_inventory_host_known() {
  local profile="$1"
  local fqdn="$2"
  [[ -n "$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "ansible_host")" ]] \
    || [[ -n "$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_name")" ]]
}

load_profile_network_exports() {
  local profile="$1"
  require_cmd python3
  local inventory vars_file exports
  inventory="$(vm_profile_inventory_dir "${profile}")"
  vars_file="${inventory}/group_vars/all/vars.yml"
  if [[ ! -f "${vars_file}" ]]; then
    die "Missing ${vars_file} — copy from vars.yml.example and set vm_gateway, vm_subnet_prefix, vm_dns_servers"
  fi
  exports="$(python3 - "${vars_file}" <<'PY'
import json, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required — pip install pyyaml")

path = Path(sys.argv[1])
data = yaml.safe_load(path.read_text()) or {}
keys = ("vm_gateway", "vm_subnet_prefix", "vm_dns_search", "vm_dns_servers")
out = {k: data.get(k) for k in keys if data.get(k) is not None}
print(json.dumps(out))
PY
)"
  export VM_GATEWAY="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_gateway',''))" "${exports}")"
  export VM_SUBNET_PREFIX="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_subnet_prefix',''))" "${exports}")"
  export VM_DNS_SEARCH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_dns_search',''))" "${exports}")"
  export VM_DNS_SERVERS_JSON="$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('vm_dns_servers',[])))" "${exports}")"
  [[ -n "${VM_GATEWAY}" ]] || die "Profile ${profile} missing vm_gateway in group_vars/all/vars.yml"
  [[ -n "${VM_SUBNET_PREFIX}" ]] || die "Profile ${profile} missing vm_subnet_prefix in group_vars/all/vars.yml"
  [[ "${VM_DNS_SERVERS_JSON}" != "[]" ]] || die "Profile ${profile} missing vm_dns_servers in group_vars/all/vars.yml"
}

load_adhoc_network_exports() {
  local profile="$1"
  local fqdn="$2"
  if vm_inventory_host_known "${profile}" "${fqdn}"; then
    load_inventory_network_exports "${profile}" "${fqdn}"
  else
    load_profile_network_exports "${profile}"
  fi
}
