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
  ensure_venv_path "${ROOT}"
  local inventory vault_file
  inventory="$(vm_profile_inventory "${profile}")"
  vault_file="$(ensure_vault_password_file_for_profile "${ROOT}" "${profile}")"
  ANSIBLE_CONFIG="${ROOT}/ansible.cfg" ansible-inventory \
    -i "${inventory}" \
    --vault-password-file "${vault_file}" \
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
    VM_DNS_SERVERS_YAML="$(vm_build_static_dns_yaml "${VM_DNS_SERVERS_JSON:-[]}" "${VM_DNS_SEARCH:-}")"
    export VM_DNS_SERVERS_YAML
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
  local vm_mac="${3:-}"
  local arg=""

  if [[ -n "${bridge}" ]]; then
    arg="bridge=${bridge},model=virtio"
  else
    arg="network=${net_name},model=virtio"
  fi
  if [[ -n "${vm_mac}" ]]; then
    arg="${arg},mac=${vm_mac}"
  fi
  printf '%s' "${arg}"
}

vm_generate_mac_from_name() {
  local vm_name="$1"
  require_cmd python3
  python3 - "${vm_name}" <<'PY'
import hashlib, sys

digest = hashlib.sha256(sys.argv[1].encode()).digest()
print(f"52:54:00:{digest[0]:02x}:{digest[1]:02x}:{digest[2]:02x}")
PY
}

vm_manifest_lookup() {
  local manifest="$1"
  local key="$2"
  [[ -f "${manifest}" ]] || return 1
  grep -E "^${key}=" "${manifest}" 2>/dev/null | head -1 | cut -d= -f2- || true
}

vm_resolve_mac() {
  local profile="${1:-}"
  local fqdn="${2:-}"
  local vm_name="$3"
  local seed_dir="$4"
  local mac manifest

  if [[ -n "${profile}" && -n "${fqdn}" ]]; then
    mac="$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_mac")"
    if [[ -n "${mac}" ]]; then
      printf '%s' "${mac}"
      return 0
    fi
  fi

  manifest="${seed_dir}/manifest.txt"
  mac="$(vm_manifest_lookup "${manifest}" "vm_mac")"
  if [[ -n "${mac}" ]]; then
    printf '%s' "${mac}"
    return 0
  fi

  vm_generate_mac_from_name "${vm_name}"
}

# Build virt-install argv (array name in caller: local -a args; vm_build_virt_install_argv args ...).
vm_build_virt_install_argv() {
  local -n _out="$1"
  local vm_name="$2"
  local disk_path="$3"
  local seed_iso="$4"
  local network_arg="$5"
  local memory_mb="$6"
  local vcpus="$7"
  local nested_virt="$8"

  _out=(
    --connect "${LIBVIRT_DEFAULT_URI:-qemu:///system}"
    --name "${vm_name}"
    --memory "${memory_mb}"
    --vcpus "${vcpus}"
    --disk "path=${disk_path},format=qcow2,bus=virtio"
    --disk "path=${seed_iso},device=cdrom"
    --os-variant ubuntu24.04
    --network "${network_arg}"
    --graphics none
    --console "pty,target.type=serial"
    --import
    --noautoconsole
  )
  if [[ "${nested_virt}" -eq 1 ]]; then
    _out+=(--cpu host-passthrough)
  fi
}

vm_quote_args() {
  local arg quoted=()
  for arg in "$@"; do
    quoted+=("$(printf '%q' "${arg}")")
  done
  (IFS=' '; printf '%s' "${quoted[*]}")
}

# Write install.sh, optional domain.xml, and manifest.txt beside the cloud-init seed.
vm_write_install_artifacts() {
  local vm_name="$1"
  local fqdn="$2"
  local vm_ip="$3"
  local cloud_init_mode="$4"
  local disk_path="$5"
  local seed_iso="$6"
  local base_image="$7"
  local network_arg="$8"
  local memory_mb="$9"
  local vcpus="${10}"
  local nested_virt="${11}"
  local bundle_dir="${12}"
  local vm_mac="${13:-}"
  local -a virt_argv=()

  vm_build_virt_install_argv virt_argv "${vm_name}" "${disk_path}" "${seed_iso}" \
    "${network_arg}" "${memory_mb}" "${vcpus}" "${nested_virt}"

  local install_sh="${bundle_dir}/install.sh"
  local domain_xml="${bundle_dir}/domain.xml"
  local manifest="${bundle_dir}/manifest.txt"
  local quoted_cmd nested_cpu=""
  quoted_cmd="$(vm_quote_args virt-install "${virt_argv[@]}")"
  if [[ "${nested_virt}" -eq 1 ]]; then
    nested_cpu=$'  --noautoconsole \\\n  --cpu host-passthrough'
  else
    nested_cpu='  --noautoconsole'
  fi

  if command -v virt-install >/dev/null 2>&1; then
    if virt-install "${virt_argv[@]}" --print-xml > "${domain_xml}" 2>/dev/null; then
      log_info "Wrote ${domain_xml}"
    else
      log_warn "Could not generate domain.xml (libvirt network may be undefined on this host)"
      rm -f "${domain_xml}"
    fi
  else
    log_warn "virt-install not found — skipping domain.xml (install.sh still generated)"
    rm -f "${domain_xml}"
  fi

  {
    cat <<EOF
#!/usr/bin/env bash
# Generated by vm-create.sh --dry-run. Run on the target hypervisor after copying artifacts.
set -euo pipefail

VM_DATA_BASE="\${VM_DATA_BASE:-$(vm_data_base)}"
DISK_PATH="\${DISK_PATH:-${disk_path}}"
SEED_ISO="\${SEED_ISO:-${seed_iso}}"
BASE_IMAGE="\${BASE_IMAGE:-${base_image}}"
LIBVIRT_DEFAULT_URI="\${LIBVIRT_DEFAULT_URI:-qemu:///system}"
DOMAIN_XML="\${DOMAIN_XML:-${domain_xml}}"

[[ -f "\${DISK_PATH}" ]] || { echo "Missing disk: \${DISK_PATH}" >&2; exit 1; }
[[ -f "\${SEED_ISO}" ]] || { echo "Missing seed ISO: \${SEED_ISO}" >&2; exit 1; }
[[ -f "\${BASE_IMAGE}" ]] || {
  echo "Missing base cloud image: \${BASE_IMAGE}" >&2
  echo "Copy from the build host or run image-ensure.sh on this hypervisor." >&2
  exit 1
}

command -v virsh >/dev/null || { echo "virsh required" >&2; exit 1; }

if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
  echo "VM ${vm_name} already exists — run vm-destroy.sh first" >&2
  exit 1
fi

if [[ -f "\${DOMAIN_XML}" ]]; then
  virsh --connect "\${LIBVIRT_DEFAULT_URI}" define "\${DOMAIN_XML}"
  virsh --connect "\${LIBVIRT_DEFAULT_URI}" start "${vm_name}"
  exit 0
fi

command -v virt-install >/dev/null || { echo "virt-install required (no domain.xml)" >&2; exit 1; }

exec virt-install \\
  --connect "\${LIBVIRT_DEFAULT_URI}" \\
  --name "${vm_name}" \\
  --memory "${memory_mb}" \\
  --vcpus "${vcpus}" \\
  --disk "path=\${DISK_PATH},format=qcow2,bus=virtio" \\
  --disk "path=\${SEED_ISO},device=cdrom" \\
  --os-variant ubuntu24.04 \\
  --network "${network_arg}" \\
  --graphics none \\
  --console "pty,target.type=serial" \\
  --import \\
${nested_cpu}
EOF
  } > "${install_sh}"
  chmod 755 "${install_sh}"

  {
    printf 'vm_name=%s\n' "${vm_name}"
    printf 'fqdn=%s\n' "${fqdn}"
    if [[ "${cloud_init_mode}" == "dhcp" ]]; then
      printf 'network_mode=dhcp\n'
    else
      printf 'network_mode=static\n'
      printf 'vm_ip=%s\n' "${vm_ip}"
    fi
    if [[ -n "${vm_mac}" ]]; then
      printf 'vm_mac=%s\n' "${vm_mac}"
    fi
    printf 'disk_path=%s\n' "${disk_path}"
    printf 'seed_iso=%s\n' "${seed_iso}"
    printf 'base_image=%s\n' "${base_image}"
    printf 'install_script=%s\n' "${install_sh}"
    if [[ -f "${domain_xml}" ]]; then
      printf 'domain_xml=%s\n' "${domain_xml}"
      printf 'define_cmd=virsh define %s\n' "${domain_xml}"
      printf 'start_cmd=virsh start %s\n' "${vm_name}"
    fi
    printf 'virt_install_cmd=%s\n' "${quoted_cmd}"
    cat <<'NOTES'

# Copy to target hypervisor
# 1. Base cloud image (once per hypervisor): copy base_image or run image-ensure.sh
# 2. Disk overlay: disk_path (qcow2 backing file must resolve on target — same path or qemu-img rebase)
# 3. Cloud-init seed: seed_iso (and optional user-data/meta-data in the same directory)
# 4. Run install_script on the target (uses domain.xml when present — preserves MAC)

# If backing path differs on the target:
#   qemu-img info disk_path
#   qemu-img rebase -u -b /path/on/target/noble-server-cloudimg-amd64.img disk_path
NOTES
  } > "${manifest}"

  log_info "Wrote ${install_sh}"
  log_info "Wrote ${manifest}"
}

vm_define_domain_from_virt_install() {
  local vm_name="$1"
  local domain_xml="$2"
  shift 2
  local -a virt_argv=("$@")

  require_cmd virsh
  require_cmd virt-install

  virt-install "${virt_argv[@]}" --print-xml > "${domain_xml}"
  virsh define "${domain_xml}" >/dev/null
  log_info "Defined VM ${vm_name} (not started)"
}

vm_write_manifest() {
  local vm_name="$1"
  local fqdn="$2"
  local vm_ip="$3"
  local cloud_init_mode="$4"
  local disk_path="$5"
  local seed_iso="$6"
  local base_image="$7"
  local domain_xml="$8"
  local vm_mac="$9"
  local manifest="${10}"

  {
    printf 'vm_name=%s\n' "${vm_name}"
    printf 'fqdn=%s\n' "${fqdn}"
    if [[ "${cloud_init_mode}" == "dhcp" ]]; then
      printf 'network_mode=dhcp\n'
    else
      printf 'network_mode=static\n'
      printf 'vm_ip=%s\n' "${vm_ip}"
    fi
    if [[ -n "${vm_mac}" ]]; then
      printf 'vm_mac=%s\n' "${vm_mac}"
    fi
    printf 'disk_path=%s\n' "${disk_path}"
    printf 'seed_iso=%s\n' "${seed_iso}"
    printf 'base_image=%s\n' "${base_image}"
    if [[ -f "${domain_xml}" ]]; then
      printf 'domain_xml=%s\n' "${domain_xml}"
      printf 'define_cmd=virsh define %s\n' "${domain_xml}"
      printf 'start_cmd=virsh start %s\n' "${vm_name}"
    fi
  } > "${manifest}"
  log_info "Wrote ${manifest}"
}

vm_print_reservation_block() {
  local fqdn="$1"
  local vm_name="$2"
  local vm_mac="$3"
  local reserve_ip="$4"
  local profile="$5"

  cat <<EOF >&2

=== DHCP reservation required before first boot ===
FQDN:     ${fqdn}
VM:       ${vm_name}
MAC:      ${vm_mac}
Reserve:  ${reserve_ip}  (ansible_host from inventory)

Create a DHCP reservation on your router (MAC -> IP), then start the VM:
  ./scripts/vm/vm-start.sh -i ${profile} ${fqdn}

EOF
}

vm_wait_for_reservation_confirm() {
  log_info "Press Enter after creating the DHCP reservation (Ctrl-C to abort)..."
  read -r _
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
  VM_GATEWAY="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_gateway")"
  export VM_GATEWAY
  VM_SUBNET_PREFIX="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_subnet_prefix")"
  export VM_SUBNET_PREFIX
  VM_DNS_SEARCH="$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_dns_search")"
  export VM_DNS_SEARCH
  VM_DNS_SERVERS_JSON="$(vm_inventory_lookup "${profile}" "${fqdn}" "vm_dns_servers")"
  export VM_DNS_SERVERS_JSON
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
  VM_GATEWAY="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_gateway',''))" "${exports}")"
  export VM_GATEWAY
  VM_SUBNET_PREFIX="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_subnet_prefix',''))" "${exports}")"
  export VM_SUBNET_PREFIX
  VM_DNS_SEARCH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('vm_dns_search',''))" "${exports}")"
  export VM_DNS_SEARCH
  VM_DNS_SERVERS_JSON="$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]).get('vm_dns_servers',[])))" "${exports}")"
  export VM_DNS_SERVERS_JSON
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
