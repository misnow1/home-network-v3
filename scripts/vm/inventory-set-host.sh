#!/usr/bin/env bash
# Set or update ansible_host for an inventory VM (ephemeral DHCP workflow).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

PROFILE="production"
INVENTORY_FQDN=""
VM_IP=""
DISCOVER=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i PROFILE] --fqdn <host> (--ip <addr> | --discover)

Update inventories/<PROFILE>/hosts.yml with ansible_host for a VM host.

Use after boot when the IP is assigned by DHCP and you do not use a router
reservation (--prepare workflow). Not recommended for bastion — prefer
vm-create.sh --prepare so ansible_host matches the reservation from first boot.

Options:
  -i, --inventory PROFILE  Inventory profile (default: production)
  --fqdn FQDN              Inventory hostname (e.g. bastion.home.2123studios.com)
  --ip ADDR                Set ansible_host to ADDR
  --discover               Discover IP via libvirt guest agent (VM must be running)
  -h, --help               Show this help

Examples:
  $(basename "$0") -i production --fqdn build01.home.2123studios.com --discover
  $(basename "$0") -i production --fqdn build01.home.2123studios.com --ip 192.168.1.50
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      --fqdn)
        INVENTORY_FQDN="$2"
        shift 2
        ;;
      --ip)
        VM_IP="$2"
        shift 2
        ;;
      --discover)
        DISCOVER=1
        shift
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

ensure_hosts_file() {
  local hosts_file hosts_example
  hosts_file="$(vm_profile_inventory "${PROFILE}")"
  if [[ -f "${hosts_file}" ]]; then
    return 0
  fi
  hosts_example="$(vm_profile_inventory_dir "${PROFILE}")/hosts.yml.example"
  [[ -f "${hosts_example}" ]] || die "Missing ${hosts_example}"
  cp "${hosts_example}" "${hosts_file}"
  log_info "Created ${hosts_file} from example"
}

update_inventory() {
  local hosts_file="$1"
  local host_name="$2"
  local host_ip="$3"
  require_cmd python3
  python3 - "${hosts_file}" "${host_name}" "${host_ip}" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required — install with: pip install pyyaml")

hosts_path = Path(sys.argv[1])
host_name = sys.argv[2]
host_ip = sys.argv[3]

data = yaml.safe_load(hosts_path.read_text()) or {}


def walk(node):
    if not isinstance(node, dict):
        return False
    hosts = node.get("hosts")
    if isinstance(hosts, dict) and host_name in hosts:
        hosts[host_name]["ansible_host"] = host_ip
        return True
    children = node.get("children")
    if isinstance(children, dict):
        for child in children.values():
            if walk(child):
                return True
    return False


if not walk(data.get("all", {})):
    sys.exit(f"Host {host_name!r} not found in {hosts_path}")

hosts_path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
print(f"Set {host_name} ansible_host -> {host_ip}")
PY
}

main() {
  parse_args "$@"

  [[ -n "${INVENTORY_FQDN}" ]] || { usage; exit 1; }
  if [[ "${DISCOVER}" -eq 1 && -n "${VM_IP}" ]]; then
    die "Use either --ip or --discover, not both"
  fi
  if [[ "${DISCOVER}" -eq 0 && -z "${VM_IP}" ]]; then
    die "Provide --ip or --discover"
  fi

  local hosts_file vm_name
  hosts_file="$(vm_profile_inventory "${PROFILE}")"
  vm_name="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_name")"

  if [[ "${DISCOVER}" -eq 1 ]]; then
    require_cmd virsh
    VM_IP="$(vm_wait_for_ip "${vm_name}" "${VM_IP_DISCOVERY_TIMEOUT_SECS:-300}" "${VM_SSH_POLL_SECS:-5}")"
    log_info "Discovered ${vm_name} at ${VM_IP}"
  fi

  ensure_hosts_file
  update_inventory "${hosts_file}" "${INVENTORY_FQDN}" "${VM_IP}"
}

main "$@"
