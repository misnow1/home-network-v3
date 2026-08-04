#!/usr/bin/env bash
# Generate Ubuntu Server autoinstall (nocloud) CIDATA files from Ansible inventory.
#
# Profile: bare_metal_simple — single/static NIC via MAC match + whole-disk storage.
# For hypervisor reimages (interactive storage, Ansible netplan), use:
#   scripts/reimage/ubuntu-autoinstall/build-user-data.sh
# For VMs, use:
#   scripts/vm/vm-create.sh
#
# Example:
#   ./scripts/vm/keys-ensure.sh -i production
#   ./scripts/reimage/cloud-init-from-inventory.sh \
#     -i production \
#     k8s-node-1.home.2123studios.com \
#     -o /mnt/CIDATA
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=../vm/vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

PROFILE="production"
OUTPUT_DIR=""
FQDN=""
INSTANCE_ID=""
STORAGE_LAYOUT="lvm"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: cloud-init-from-inventory.sh -i PROFILE FQDN -o DIR [options]

Read a host from Ansible inventory and write Ubuntu autoinstall user-data /
meta-data for a bare_metal_simple reimage (MAC-matched netplan + whole-disk).

Options:
  -i, --inventory PROFILE   lab or production (default: production)
  -o, --output DIR          Output directory (CIDATA mount; required unless --dry-run)
  --storage-layout NAME     Autoinstall layout: lvm (default) or direct
  --instance-id ID          meta-data instance-id (default: reimage-<hostname>-<date>)
  --dry-run                 Write to a temp dir and print paths (do not require -o)
  -h, --help                Show this help

Inventory requirements for bare_metal_simple:
  - No vm_name (those hosts are VMs — use vm-create.sh)
  - ethernets[] with a real macaddress (not "tbd")
  - Static addresses and/or dhcp4/dhcp6 as needed
  - Do not set network/bridge (libvirt-only; ignored for bare metal)

USB flow: write Ubuntu 24.04 Server ISO, add VFAT partition labeled CIDATA,
copy generated files there, boot the host.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i | --inventory)
        PROFILE="$2"
        shift 2
        ;;
      -o | --output)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --storage-layout)
        STORAGE_LAYOUT="$2"
        shift 2
        ;;
      --instance-id)
        INSTANCE_ID="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        if [[ -n "${FQDN}" ]]; then
          die "Unexpected argument: $1"
        fi
        FQDN="$1"
        shift
        ;;
    esac
  done
}

short_hostname_from_fqdn() {
  local fqdn="$1"
  printf '%s' "${fqdn%%.*}"
}

# Normalize inventory ethernets for bare metal: require MAC, forbid relying on
# libvirt network/bridge, emit Subiquity autoinstall network YAML (netplan).
bare_metal_network_yaml() {
  local host_json="$1"
  python3 - "${host_json}" <<'PY'
import ipaddress
import json
import re
import sys

import yaml

host = json.loads(sys.argv[1] or "{}")
raw = host.get("ethernets")
if not isinstance(raw, list) or not raw:
    raise SystemExit(
        "bare_metal_simple requires ethernets: — a non-empty list with macaddress"
    )

mac_re = re.compile(r"^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
placeholder_macs = {"tbd", "todo", "changeme", "replace", "00:00:00:00:00:00"}

ethernets = {}
for index, original in enumerate(raw, 1):
    if not isinstance(original, dict):
        raise SystemExit(f"ethernets[{index}] must be a mapping")
    entry = dict(original)
    if "mac_address" in entry and "macaddress" not in entry:
        entry["macaddress"] = entry.pop("mac_address")
    # Common typo from early drafts
    if "macaddrss" in entry and "macaddress" not in entry:
        entry["macaddress"] = entry.pop("macaddrss")

    mac = str(entry.get("macaddress") or "").strip()
    if not mac:
        raise SystemExit(
            f"ethernets[{index}] missing macaddress — required for bare-metal "
            "autoinstall (match by MAC; NIC name varies)"
        )
    if mac.lower() in placeholder_macs or not mac_re.fullmatch(mac):
        raise SystemExit(
            f"ethernets[{index}] macaddress={mac!r} is not a real MAC — "
            "set the NIC MAC from the machine label/BIOS/ip link before generating"
        )

    if entry.get("network") or entry.get("bridge"):
        # Allowed in inventory for documentation but not used on bare metal.
        pass

    addresses = entry.get("addresses", [])
    if addresses is None:
        addresses = []
    if not isinstance(addresses, list):
        raise SystemExit(f"ethernets[{index}].addresses must be a list")
    for address in addresses:
        try:
            ipaddress.ip_interface(address)
        except ValueError as exc:
            raise SystemExit(
                f"ethernets[{index}] invalid address {address}: {exc}"
            ) from exc

    dhcp4 = entry.get("dhcp4")
    dhcp6 = entry.get("dhcp6")
    if dhcp4 is None and dhcp6 is None and not addresses:
        dhcp4 = True
        dhcp6 = True
    if dhcp4 is None:
        dhcp4 = False
    if dhcp6 is None:
        dhcp6 = False
    if not isinstance(dhcp4, bool) or not isinstance(dhcp6, bool):
        raise SystemExit(f"ethernets[{index}] dhcp4/dhcp6 must be booleans")

    nic = {
        "match": {"macaddress": mac.lower()},
        "set-name": f"nic{index}",
        "dhcp4": dhcp4,
        "dhcp6": dhcp6,
    }
    if addresses:
        nic["addresses"] = list(addresses)
    routes = entry.get("routes")
    if routes:
        if not isinstance(routes, list):
            raise SystemExit(f"ethernets[{index}].routes must be a list")
        nic["routes"] = routes
    nameservers = entry.get("nameservers")
    if nameservers:
        if isinstance(nameservers, list):
            nic["nameservers"] = {"addresses": list(nameservers)}
        elif isinstance(nameservers, dict):
            nic["nameservers"] = nameservers
        else:
            raise SystemExit(
                f"ethernets[{index}].nameservers must be a list or mapping"
            )

    ethernets[f"nic{index}"] = nic

doc = {"version": 2, "ethernets": ethernets}
# Indent as a child of autoinstall.network (2 spaces under "  network:").
text = yaml.safe_dump(doc, sort_keys=False, default_flow_style=False).rstrip()
print("\n".join(f"    {line}" if line else "" for line in text.splitlines()))
PY
}

validate_host_for_bare_metal() {
  local host_json="$1"
  python3 - "${host_json}" <<'PY'
import json
import sys

host = json.loads(sys.argv[1] or "{}")
if host.get("vm_name"):
    raise SystemExit(
        f"host has vm_name={host['vm_name']!r} — this is a VM; use "
        "scripts/vm/vm-create.sh instead"
    )
profile = str(host.get("install_profile") or "bare_metal_simple")
if profile in {"hypervisor_reimage", "hypervisor"}:
    raise SystemExit(
        f"install_profile={profile!r} — use "
        "scripts/reimage/ubuntu-autoinstall/build-user-data.sh "
        "(identity-only USB; network via hypervisor.yml)"
    )
if profile not in {"bare_metal_simple", "bare-metal-simple", ""}:
    raise SystemExit(
        f"unsupported install_profile={profile!r} "
        "(supported: bare_metal_simple; hypervisor_reimage uses build-user-data.sh)"
    )
print(profile or "bare_metal_simple")
PY
}

main() {
  parse_args "$@"

  [[ -n "${FQDN}" ]] || die "Required: inventory FQDN (e.g. k8s-node-1.home.2123studios.com)"
  case "${STORAGE_LAYOUT}" in
    lvm | direct) ;;
    *) die "Unsupported --storage-layout ${STORAGE_LAYOUT} (use lvm or direct)" ;;
  esac

  if [[ "${DRY_RUN}" -eq 1 && -z "${OUTPUT_DIR}" ]]; then
    OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cidata-XXXXXX")"
    log_info "Dry-run output directory: ${OUTPUT_DIR}"
    # shellcheck disable=SC2064
    trap 'rm -rf "${OUTPUT_DIR}"' EXIT
  fi
  [[ -n "${OUTPUT_DIR}" ]] || die "Required: -o /path/to/CIDATA (or --dry-run)"

  require_cmd envsubst
  require_cmd openssl
  require_cmd python3
  require_cmd ansible-inventory
  ensure_venv_path "${ROOT}"

  # PyYAML is available via the project venv / Ansible deps; fall back check.
  python3 -c 'import yaml' 2>/dev/null || die "Python PyYAML required (use repo .venv)"

  local pub_key_file pub_key host_json hostname password_hash network_yaml install_profile
  pub_key_file="$(vm_ssh_pub_key_path "${PROFILE}")"
  [[ -f "${pub_key_file}" ]] || die "Missing ${pub_key_file} — run scripts/vm/keys-ensure.sh -i ${PROFILE}"
  pub_key="$(tr -d '\n' < "${pub_key_file}")"

  log_info "Reading inventory host ${FQDN} (profile=${PROFILE})"
  host_json="$(vm_inventory_host_json "${PROFILE}" "${FQDN}")"
  install_profile="$(validate_host_for_bare_metal "${host_json}")"
  network_yaml="$(bare_metal_network_yaml "${host_json}")"

  hostname="$(short_hostname_from_fqdn "${FQDN}")"
  [[ -n "${INSTANCE_ID}" ]] || INSTANCE_ID="reimage-${hostname}-$(date +%Y%m%d)"

  # Subiquity requires identity.password; lock account via late-command passwd -l.
  password_hash="$(openssl passwd -6 "$(openssl rand -hex 16)")"

  mkdir -p "${OUTPUT_DIR}"

  export AUTOINSTALL_HOSTNAME="${hostname}"
  export AUTOINSTALL_PASSWORD_HASH="${password_hash}"
  export AUTOINSTALL_SSH_PUBKEY="${pub_key}"
  export AUTOINSTALL_INSTANCE_ID="${INSTANCE_ID}"
  export AUTOINSTALL_STORAGE_LAYOUT="${STORAGE_LAYOUT}"
  export AUTOINSTALL_NETWORK_YAML="${network_yaml}"

  local tmpl_dir
  tmpl_dir="${ROOT}/scripts/reimage/ubuntu-autoinstall"

  # shellcheck disable=SC2016
  envsubst '${AUTOINSTALL_HOSTNAME} ${AUTOINSTALL_PASSWORD_HASH} ${AUTOINSTALL_SSH_PUBKEY} ${AUTOINSTALL_STORAGE_LAYOUT} ${AUTOINSTALL_NETWORK_YAML}' \
    < "${tmpl_dir}/bare-metal-simple-user-data.tmpl" > "${OUTPUT_DIR}/user-data"

  # shellcheck disable=SC2016
  envsubst '${AUTOINSTALL_HOSTNAME} ${AUTOINSTALL_INSTANCE_ID}' \
    < "${tmpl_dir}/meta-data.tmpl" > "${OUTPUT_DIR}/meta-data"

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    trap - EXIT
  fi

  log_info "Wrote ${OUTPUT_DIR}/user-data and meta-data"
  log_info "  profile=${install_profile} hostname=${hostname} fqdn=${FQDN}"
  log_info "  storage-layout=${STORAGE_LAYOUT} ssh-key=${pub_key_file}"
  log_info "Label USB partition CIDATA, copy these files, boot Ubuntu Server 24.04."
  log_info "After install: ssh -i ${pub_key_file%.pub} ansible@<ansible_host> hostname"
}

main "$@"
