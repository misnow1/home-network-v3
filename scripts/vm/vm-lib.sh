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

vm_normalize_ethernets() {
  local host_json="${1:-}"
  if [[ -z "${host_json}" ]]; then
    host_json='{}'
  fi
  require_cmd python3
  python3 - "${host_json}" <<'PY'
import ipaddress
import json
import re
import sys

host = json.loads(sys.argv[1] or "{}")
default_network = host.get("vm_network")
raw = host.get("ethernets")

if raw is None:
    if host.get("vm_ip") and not host.get("vm_use_dhcp"):
        prefix = host.get("vm_subnet_prefix", 24)
        entry = {
            "addresses": [f"{host['vm_ip']}/{prefix}"],
            "dhcp4": False,
            "dhcp6": False,
        }
        if host.get("vm_gateway"):
            entry["routes"] = [{"to": "default", "via": str(host["vm_gateway"])}]
        if host.get("vm_dns_servers"):
            entry["nameservers"] = list(host["vm_dns_servers"])
    else:
        entry = {"dhcp4": True, "dhcp6": True}
    if host.get("vm_mac"):
        entry["macaddress"] = host["vm_mac"]
    raw = [entry]

if not isinstance(raw, list) or not raw:
    raise SystemExit("ethernets must be a non-empty list when provided")

mac_re = re.compile(r"^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
normalized = []
for index, original in enumerate(raw, 1):
    if not isinstance(original, dict):
        raise SystemExit(f"ethernets[{index}] must be a mapping")
    entry = dict(original)
    if entry.get("network") and entry.get("bridge"):
        raise SystemExit(f"ethernets[{index}] cannot set both network and bridge")
    if not entry.get("network") and not entry.get("bridge"):
        if not default_network:
            raise SystemExit(f"ethernets[{index}] needs network/bridge and vm_network has no default")
        entry["network"] = default_network
    if "mac_address" in entry and "macaddress" not in entry:
        entry["macaddress"] = entry.pop("mac_address")
    if entry.get("macaddress") and not mac_re.fullmatch(str(entry["macaddress"])):
        raise SystemExit(f"ethernets[{index}] has invalid macaddress")

    addresses = entry.get("addresses", [])
    if not isinstance(addresses, list):
        raise SystemExit(f"ethernets[{index}].addresses must be a list")
    for address in addresses:
        try:
            ipaddress.ip_interface(address)
        except ValueError as exc:
            raise SystemExit(f"ethernets[{index}] invalid address {address}: {exc}") from exc

    if not addresses and "dhcp4" not in entry and "dhcp6" not in entry:
        entry["dhcp4"] = True
        entry["dhcp6"] = True
    else:
        entry.setdefault("dhcp4", False)
        entry.setdefault("dhcp6", False)
    if not isinstance(entry["dhcp4"], bool) or not isinstance(entry["dhcp6"], bool):
        raise SystemExit(f"ethernets[{index}] dhcp4/dhcp6 must be booleans")
    normalized.append(entry)

print(json.dumps(normalized, separators=(",", ":")))
PY
}

vm_inventory_ethernets() {
  local profile="$1"
  local fqdn="$2"
  vm_normalize_ethernets "$(vm_inventory_host_json "${profile}" "${fqdn}")"
}

vm_ethernets_primary_ipv4() {
  local ethernets_json="$1"
  python3 - "${ethernets_json}" <<'PY'
import ipaddress, json, sys
for address in json.loads(sys.argv[1])[0].get("addresses", []):
    interface = ipaddress.ip_interface(address)
    if interface.version == 4:
        print(interface.ip)
        break
PY
}

vm_ethernets_use_dhcp() {
  local ethernets_json="$1"
  # The first NIC is the management NIC. DHCPv6 on a static-IPv4 host does not
  # require IPv4 lease discovery or a router reservation.
  python3 -c 'import json,sys; e=json.loads(sys.argv[1]); raise SystemExit(0 if e[0].get("dhcp4") else 1)' \
    "${ethernets_json}"
}

vm_build_netplan_yaml() {
  local ethernets_json="$1"
  require_cmd python3
  python3 - "${ethernets_json}" <<'PY'
import json
import sys
import yaml

entries = json.loads(sys.argv[1])
ethernets = {}
for index, entry in enumerate(entries, 1):
    guest = {
        key: value
        for key, value in entry.items()
        if key not in {"network", "bridge", "macaddress", "mac_address"}
    }
    nameservers = guest.get("nameservers")
    if isinstance(nameservers, list):
        guest["nameservers"] = {"addresses": nameservers}
    ethernets[f"enp{index}s0"] = guest

print(yaml.safe_dump(
    {"network": {"version": 2, "ethernets": ethernets}},
    sort_keys=False,
    default_flow_style=False,
).rstrip())
PY
}

vm_indent_yaml() {
  local spaces="$1"
  local content="$2"
  local padding
  printf -v padding '%*s' "${spaces}" ''
  while IFS= read -r line; do
    printf '%s%s\n' "${padding}" "${line}"
  done <<< "${content}"
}

vm_render_cloud_init() {
  local profile="$1"
  local fqdn="$2"
  local vm_name="$3"
  local ethernets_json="$4"
  local pubkey seed_dir user_data meta_data template netplan_yaml

  pubkey="$(cat "$(vm_ssh_pub_key_path "${profile}")")"
  seed_dir="$(vm_seeds_dir "${profile}")/${vm_name}"
  mkdir -p "${seed_dir}"

  export VM_FQDN="${fqdn}"
  export VM_HOST_SHORT="${fqdn%%.*}"
  export VM_INSTANCE_ID="${vm_name}"
  export VM_SSH_PUBKEY="${pubkey}"
  template="${ROOT}/scripts/vm/cloud-init/user-data.tmpl"
  netplan_yaml="$(vm_build_netplan_yaml "${ethernets_json}")"
  VM_NETPLAN_YAML="$(vm_indent_yaml 6 "${netplan_yaml}")"
  export VM_NETPLAN_YAML

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

vm_network_args() {
  local ethernets_json="$1"
  local vcpus="${2:-1}"
  local perf_profile="${3:-lab}"
  python3 - "${ethernets_json}" "${vcpus}" "${perf_profile}" <<'PY'
import json, sys

entries = json.loads(sys.argv[1])
vcpus = int(sys.argv[2])
perf_profile = sys.argv[3]

for entry in entries:
    if entry.get("bridge"):
        arg = f"bridge={entry['bridge']},model=virtio"
    else:
        arg = f"network={entry['network']},model=virtio"
    if entry.get("macaddress"):
        arg += f",mac={entry['macaddress']}"
    if perf_profile in ("balanced", "storage", "windows11") and vcpus > 1:
        arg += f",driver.queues={vcpus}"
    print(arg)
PY
}

vm_perf_profile_validate() {
  local profile="$1"
  case "${profile}" in
    lab|balanced|storage|windows11) ;;
    *) die "Invalid perf profile: ${profile} (expected lab, balanced, storage, or windows11)" ;;
  esac
}

vm_is_windows_profile() {
  [[ "${1:-}" == "windows11" ]]
}

vm_parse_cpu_topology() {
  # Prints: cores threads  (from "cores,threads" inventory form).
  local topology="${1:-}"
  local cores threads
  if [[ -z "${topology}" ]]; then
    printf ''
    return 0
  fi
  if [[ ! "${topology}" =~ ^([1-9][0-9]*),([1-9][0-9]*)$ ]]; then
    die "Invalid vm_cpu_topology: ${topology} (expected cores,threads e.g. 6,1)"
  fi
  cores="${BASH_REMATCH[1]}"
  threads="${BASH_REMATCH[2]}"
  printf '%s %s' "${cores}" "${threads}"
}

vm_disk_virt_install_arg() {
  local perf_profile="$1"
  local disk_path="$2"
  case "${perf_profile}" in
    lab)
      printf 'path=%s,format=qcow2,bus=virtio' "${disk_path}"
      ;;
    balanced|storage|windows11)
      printf 'path=%s,format=qcow2,bus=virtio,cache=none,io=native,discard=unmap' "${disk_path}"
      ;;
    *)
      die "Invalid perf profile: ${perf_profile}"
      ;;
  esac
}

# Inject Hyper-V / Windows 11 domain knobs virt-install cannot express fully.
vm_enrich_windows11_domain_xml() {
  local domain_xml="$1"
  local os_variant="${2:-win11}"
  require_cmd python3
  python3 - "${domain_xml}" "${os_variant}" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, os_variant = sys.argv[1], sys.argv[2]
tree = ET.parse(path)
root = tree.getroot()

# Metadata: win/11 for libosinfo.
metadata = root.find("metadata")
if metadata is None:
    metadata = ET.SubElement(root, "metadata")
libns = "http://libosinfo.org/xmlns/libvirt/domain/1.0"
ET.register_namespace("libosinfo", libns)
libinfo = metadata.find(f"{{{libns}}}libosinfo")
if libinfo is None:
    for child in list(metadata):
        metadata.remove(child)
    libinfo = ET.SubElement(metadata, f"{{{libns}}}libosinfo")
os_el = libinfo.find(f"{{{libns}}}os")
if os_el is None:
    os_el = ET.SubElement(libinfo, f"{{{libns}}}os")
os_id = "http://microsoft.com/win/11" if os_variant.startswith("win11") else f"http://microsoft.com/{os_variant}"
os_el.set("id", os_id)

features = root.find("features")
if features is None:
    features = ET.SubElement(root, "features")
hyperv = features.find("hyperv")
if hyperv is None:
    hyperv = ET.SubElement(features, "hyperv")
hyperv.set("mode", "custom")

def ensure_hv(tag, **attrs):
    node = hyperv.find(tag)
    if node is None:
        node = ET.SubElement(hyperv, tag)
    node.set("state", "on")
    for key, value in attrs.items():
        node.set(key, value)
    return node

ensure_hv("relaxed")
ensure_hv("vapic")
ensure_hv("spinlocks", retries="8191")
ensure_hv("vpindex")
ensure_hv("runtime")
ensure_hv("synic")
stimer = ensure_hv("stimer")
direct = stimer.find("direct")
if direct is None:
    direct = ET.SubElement(stimer, "direct")
direct.set("state", "on")
ensure_hv("reset")
ensure_hv("frequencies")
ensure_hv("tlbflush")
ensure_hv("ipi")

cpu = root.find("cpu")
if cpu is not None and cpu.get("mode") == "host-passthrough":
    # Ensure topoext for AMD hosts (harmless elsewhere).
    found = False
    for feature in cpu.findall("feature"):
        if feature.get("name") == "topoext":
            feature.set("policy", "require")
            found = True
            break
    if not found:
        feat = ET.SubElement(cpu, "feature")
        feat.set("policy", "require")
        feat.set("name", "topoext")

tree.write(path, encoding="utf-8", xml_declaration=True)
PY
}

vm_ethernets_with_xml_macs() {
  local ethernets_json="$1"
  local domain_xml="$2"
  python3 - "${ethernets_json}" "${domain_xml}" <<'PY'
import json, sys
import xml.etree.ElementTree as ET

entries = json.loads(sys.argv[1])
macs = [
    element.attrib["address"]
    for element in ET.parse(sys.argv[2]).getroot().findall("./devices/interface/mac")
]
if len(macs) != len(entries):
    raise SystemExit(f"domain XML has {len(macs)} NIC MACs; expected {len(entries)}")
for entry, mac in zip(entries, macs):
    entry["macaddress"] = mac
print(json.dumps(entries, separators=(",", ":")))
PY
}

vm_primary_mac() {
  local ethernets_json="$1"
  python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0].get("macaddress",""))' \
    "${ethernets_json}"
}

# Fill missing NIC MACs with QEMU locally-administered addresses (52:54:00:*).
# Keeps dry-run manifests usable when virt-install is unavailable (e.g. CI).
vm_ensure_ethernets_macs() {
  local ethernets_json="$1"
  require_cmd python3
  python3 - "${ethernets_json}" <<'PY'
import json
import secrets
import sys

entries = json.loads(sys.argv[1])
for entry in entries:
    if entry.get("macaddress"):
        continue
    # Locally administered unicast MAC in the qemu/kvm OUI range.
    entry["macaddress"] = "52:54:00:%02x:%02x:%02x" % tuple(
        secrets.token_bytes(3)
    )
print(json.dumps(entries, separators=(",", ":")))
PY
}

vm_print_ethernets_yaml() {
  local ethernets_json="$1"
  python3 - "${ethernets_json}" <<'PY'
import json, sys, yaml
print(yaml.safe_dump({"ethernets": json.loads(sys.argv[1])}, sort_keys=False).rstrip())
PY
}

# Build virt-install argv with one --network per normalized ethernet.
# Optional trailing args: cpu_topology (cores,threads), os_variant.
vm_build_virt_install_argv() {
  local -n _out="$1"
  local vm_name="$2"
  local disk_path="$3"
  local seed_iso="$4"
  local ethernets_json="$5"
  local memory_mb="$6"
  local vcpus="$7"
  local nested_virt="$8"
  local perf_profile="${9:-lab}"
  local cpu_topology="${10:-}"
  local os_variant="${11:-}"
  local -a network_args=()
  local network_arg disk_arg vcpus_arg cores threads
  vm_perf_profile_validate "${perf_profile}"
  mapfile -t network_args < <(vm_network_args "${ethernets_json}" "${vcpus}" "${perf_profile}")
  disk_arg="$(vm_disk_virt_install_arg "${perf_profile}" "${disk_path}")"

  vcpus_arg="${vcpus}"
  if [[ -n "${cpu_topology}" ]]; then
    read -r cores threads <<< "$(vm_parse_cpu_topology "${cpu_topology}")"
    vcpus_arg="sockets=1,cores=${cores},threads=${threads}"
  fi

  if [[ -z "${os_variant}" ]]; then
    if vm_is_windows_profile "${perf_profile}"; then
      os_variant="win11"
    else
      os_variant="ubuntu24.04"
    fi
  fi

  _out=(
    --connect "${LIBVIRT_DEFAULT_URI:-qemu:///system}"
    --name "${vm_name}"
    --memory "${memory_mb}"
    --vcpus "${vcpus_arg}"
    --disk "${disk_arg}"
    --os-variant "${os_variant}"
  )
  if [[ -n "${seed_iso}" ]]; then
    _out+=(--disk "path=${seed_iso},device=cdrom")
  fi
  for network_arg in "${network_args[@]}"; do
    _out+=(--network "${network_arg}")
  done

  if vm_is_windows_profile "${perf_profile}"; then
    _out+=(
      --boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes"
      --features "hyperv_relaxed=on,hyperv_vapic=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191,hyperv_synic=on,hyperv_reset=on,smm=on,vmport=off"
      --cpu "host-passthrough,migratable=off"
      --tpm "backend.type=emulator,backend.version=2.0,model=tpm-crb"
      --clock "offset=localtime"
      --graphics "vnc,listen=127.0.0.1"
      --video vga
      --import
      --noautoconsole
    )
  else
    _out+=(
      --graphics none
      --console "pty,target.type=serial"
      --import
      --noautoconsole
    )
    if [[ "${nested_virt}" -eq 1 ]]; then
      _out+=(--cpu host-passthrough)
    elif [[ "${perf_profile}" != "lab" ]]; then
      _out+=(--cpu host-model)
    fi
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
  local ethernets_json="$3"
  local disk_path="$4"
  local seed_iso="$5"
  local base_image="$6"
  local memory_mb="$7"
  local vcpus="$8"
  local nested_virt="$9"
  local perf_profile="${10:-lab}"
  local bundle_dir="${11}"
  local cpu_topology="${12:-}"
  local os_variant="${13:-}"
  local -a virt_argv=()

  ethernets_json="$(vm_ensure_ethernets_macs "${ethernets_json}")"
  vm_build_virt_install_argv virt_argv "${vm_name}" "${disk_path}" "${seed_iso}" \
    "${ethernets_json}" "${memory_mb}" "${vcpus}" "${nested_virt}" "${perf_profile}" \
    "${cpu_topology}" "${os_variant}"

  local install_sh="${bundle_dir}/install.sh"
  local domain_xml="${bundle_dir}/domain.xml"
  local manifest="${bundle_dir}/manifest.txt"
  local quoted_cmd autostart_line=""
  quoted_cmd="$(vm_quote_args virt-install "${virt_argv[@]}")"
  if [[ "${AUTOSTART:-1}" -eq 1 ]]; then
    # LIBVIRT_DEFAULT_URI stays literal — it is expanded when install.sh runs, not now.
    # shellcheck disable=SC2016
    autostart_line=$(printf 'virsh --connect "${LIBVIRT_DEFAULT_URI}" autostart "%s"' "${vm_name}")
  fi

  if command -v virt-install >/dev/null 2>&1; then
    if virt-install "${virt_argv[@]}" --print-xml > "${domain_xml}" 2>/dev/null; then
      if vm_is_windows_profile "${perf_profile}"; then
        vm_enrich_windows11_domain_xml "${domain_xml}" "${os_variant:-win11}"
      fi
      ethernets_json="$(vm_ethernets_with_xml_macs "${ethernets_json}" "${domain_xml}")"
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
EOF
    if [[ -n "${seed_iso}" ]]; then
      cat <<'EOF'
[[ -f "${SEED_ISO}" ]] || { echo "Missing seed ISO: ${SEED_ISO}" >&2; exit 1; }
EOF
    fi
    if [[ -n "${base_image}" ]]; then
      cat <<'EOF'
[[ -f "${BASE_IMAGE}" ]] || {
  echo "Missing base cloud image: ${BASE_IMAGE}" >&2
  echo "Copy from the build host or run image-ensure.sh on this hypervisor." >&2
  exit 1
}
EOF
    fi
    cat <<EOF

command -v virsh >/dev/null || { echo "virsh required" >&2; exit 1; }

if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
  echo "VM ${vm_name} already exists — run vm-destroy.sh first" >&2
  exit 1
fi

if [[ -f "\${DOMAIN_XML}" ]]; then
  virsh --connect "\${LIBVIRT_DEFAULT_URI}" define "\${DOMAIN_XML}"
  ${autostart_line}
  virsh --connect "\${LIBVIRT_DEFAULT_URI}" start "${vm_name}"
  virsh --connect "\${LIBVIRT_DEFAULT_URI}" domiflist "${vm_name}"
  exit 0
fi

command -v virt-install >/dev/null || { echo "virt-install required (no domain.xml)" >&2; exit 1; }
${quoted_cmd}
virsh --connect "\${LIBVIRT_DEFAULT_URI}" domiflist "${vm_name}"
EOF
  } > "${install_sh}"
  chmod 755 "${install_sh}"

  {
    printf 'vm_name=%s\n' "${vm_name}"
    printf 'fqdn=%s\n' "${fqdn}"
    printf 'ethernets_json=%s\n' "${ethernets_json}"
    printf 'disk_path=%s\n' "${disk_path}"
    printf 'seed_iso=%s\n' "${seed_iso}"
    printf 'base_image=%s\n' "${base_image}"
    printf 'perf_profile=%s\n' "${perf_profile}"
    printf 'cpu_topology=%s\n' "${cpu_topology}"
    printf 'os_variant=%s\n' "${os_variant}"
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
#    (Ubuntu guests only — Windows blank disks skip this)
# 2. Disk overlay: disk_path
# 3. Cloud-init seed: seed_iso when present (Ubuntu guests)
# 4. Run install_script on the target (uses domain.xml when present — preserves MAC)

# If backing path differs on the target:
#   qemu-img info disk_path
#   qemu-img rebase -u -b /path/on/target/noble-server-cloudimg-amd64.img disk_path
NOTES
    printf '\n# Inventory-ready resolved interfaces\n'
    vm_print_ethernets_yaml "${ethernets_json}"
  } > "${manifest}"

  log_info "Wrote ${install_sh}"
  log_info "Wrote ${manifest}"
}

vm_set_autostart() {
  local vm_name="$1"
  require_cmd virsh
  if virsh autostart "${vm_name}" >/dev/null; then
    log_info "Marked VM ${vm_name} for autostart on host boot"
  else
    log_warn "Failed to mark VM ${vm_name} for autostart"
  fi
}

vm_define_domain_from_virt_install() {
  local vm_name="$1"
  local domain_xml="$2"
  shift 2
  local -a virt_argv=("$@")

  require_cmd virsh
  require_cmd virt-install

  mkdir -p "$(dirname "${domain_xml}")"
  virt-install "${virt_argv[@]}" --print-xml > "${domain_xml}"
  virsh define "${domain_xml}" >/dev/null
  log_info "Defined VM ${vm_name} (not started)"
}

vm_write_manifest() {
  local vm_name="$1"
  local fqdn="$2"
  local ethernets_json="$3"
  local disk_path="$4"
  local seed_iso="$5"
  local base_image="$6"
  local domain_xml="$7"
  local manifest="$8"

  {
    printf 'vm_name=%s\n' "${vm_name}"
    printf 'fqdn=%s\n' "${fqdn}"
    printf 'ethernets_json=%s\n' "${ethernets_json}"
    printf 'disk_path=%s\n' "${disk_path}"
    printf 'seed_iso=%s\n' "${seed_iso}"
    printf 'base_image=%s\n' "${base_image}"
    if [[ -f "${domain_xml}" ]]; then
      printf 'domain_xml=%s\n' "${domain_xml}"
      printf 'define_cmd=virsh define %s\n' "${domain_xml}"
      printf 'start_cmd=virsh start %s\n' "${vm_name}"
    fi
    printf '\n# Inventory-ready resolved interfaces\n'
    vm_print_ethernets_yaml "${ethernets_json}"
  } > "${manifest}"
  log_info "Wrote ${manifest}"
}

vm_print_reservation_block() {
  local fqdn="$1"
  local vm_name="$2"
  local ethernets_json="$3"
  local reserve_ip="$4"
  local profile="$5"
  local vm_mac
  vm_mac="$(vm_primary_mac "${ethernets_json}")"

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

vm_discover_ips() {
  local vm_name="$1"
  require_cmd virsh
  virsh domifaddr "${vm_name}" --source agent 2>/dev/null \
    | awk '/ipv4|ipv6/ { print $4 }' \
    | cut -d/ -f1
}

vm_discover_ip() {
  local vm_name="$1"
  vm_discover_ips "${vm_name}" | awk '!/^127\./ && $0 != "::1" { print; exit }'
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

# Blank qcow2 for Windows (or other non-cloud-image) guests — no backing file.
vm_create_blank_disk() {
  local profile="$1"
  local disk_path="$2"
  local disk_gb="$3"

  [[ -n "${disk_gb}" ]] || die "Blank disk create requires disk size in GB"
  mkdir -p "$(vm_vms_dir "${profile}")"
  if [[ -f "${disk_path}" ]]; then
    return 0
  fi
  qemu-img create -f qcow2 "${disk_path}" "${disk_gb}G"
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

vm_ensure_ethernets_for_profile() {
  local profile="$1"
  local ethernets_json="$2"
  local kind name
  while IFS=$'\t' read -r kind name; do
    [[ -n "${name}" ]] || continue
    if [[ "${kind}" == "bridge" ]]; then
      vm_validate_bridge "${name}"
    else
      vm_ensure_network_for_profile "${profile}" "${name}"
    fi
  done < <(python3 - "${ethernets_json}" <<'PY'
import json, sys
for entry in json.loads(sys.argv[1]):
    if entry.get("bridge"):
        print("bridge", entry["bridge"], sep="\t")
    else:
        print("network", entry["network"], sep="\t")
PY
)
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
  vm_ethernets_use_dhcp "$(vm_inventory_ethernets "${profile}" "${fqdn}")"
}

vm_inventory_host_known() {
  local profile="$1"
  local fqdn="$2"
  [[ -n "$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "ansible_host")" ]] \
    || [[ -n "$(vm_inventory_lookup_optional "${profile}" "${fqdn}" "vm_name")" ]]
}

vm_profile_default_network() {
  local profile="$1"
  local vars_file
  vars_file="$(vm_profile_inventory_dir "${profile}")/group_vars/all/vars.yml"
  if [[ ! -f "${vars_file}" && -f "${vars_file}.example" ]]; then
    vars_file="${vars_file}.example"
  fi
  [[ -f "${vars_file}" ]] || die "Profile ${profile} has no group_vars/all/vars.yml"
  python3 - "${vars_file}" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
network = data.get("vm_network")
if not network:
    raise SystemExit(f"{sys.argv[1]} is missing vm_network")
print(network)
PY
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
