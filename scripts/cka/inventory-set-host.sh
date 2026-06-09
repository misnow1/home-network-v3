#!/usr/bin/env bash
# Set or update ansible_host for a CKA inventory host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=../lab/vm-lib.sh
source "${ROOT}/scripts/lab/vm-lib.sh"

INVENTORY_DIR="${ROOT}/inventories/cka"
HOSTS_FILE="${INVENTORY_DIR}/hosts.yml"
HOSTS_EXAMPLE="${INVENTORY_DIR}/hosts.yml.example"

VM_NAME=""
VM_IP=""
DISCOVER=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --name <host> (--ip <addr> | --discover)

Update inventories/cka/hosts.yml with ansible_host for a CKA VM.

Options:
  --name NAME    Inventory hostname / libvirt domain name (e.g. cka-cp1)
  --ip ADDR      Set ansible_host to ADDR
  --discover     Discover IP via libvirt guest agent (VM must be running)
  -h, --help     Show this help

Examples:
  $(basename "$0") --name cka-cp1 --ip 192.168.1.50
  $(basename "$0") --name cka-cp1 --discover
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        VM_NAME="$2"
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
  if [[ -f "${HOSTS_FILE}" ]]; then
    return 0
  fi
  [[ -f "${HOSTS_EXAMPLE}" ]] || die "Missing ${HOSTS_EXAMPLE}"
  cp "${HOSTS_EXAMPLE}" "${HOSTS_FILE}"
  log_info "Created ${HOSTS_FILE} from example"
}

update_inventory() {
  local host_name="$1"
  local host_ip="$2"
  require_cmd python3
  python3 - "${HOSTS_FILE}" "${host_name}" "${host_ip}" <<'PY'
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
cka = data.setdefault("all", {}).setdefault("children", {}).setdefault("cka", {})
hosts = cka.setdefault("hosts", {})
entry = hosts.setdefault(host_name, {})
entry["ansible_host"] = host_ip

hosts_path.write_text(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
print(f"Set {host_name} ansible_host -> {host_ip}")
PY
}

main() {
  parse_args "$@"

  [[ -n "${VM_NAME}" ]] || { usage; exit 1; }
  if [[ "${DISCOVER}" -eq 1 && -n "${VM_IP}" ]]; then
    die "Use either --ip or --discover, not both"
  fi
  if [[ "${DISCOVER}" -eq 0 && -z "${VM_IP}" ]]; then
    die "Provide --ip or --discover"
  fi

  if [[ "${DISCOVER}" -eq 1 ]]; then
    require_cmd virsh
    VM_IP="$(vm_wait_for_ip "${VM_NAME}" "${LAB_IP_DISCOVERY_TIMEOUT_SECS:-300}" "${LAB_SSH_POLL_SECS:-5}")"
    log_info "Discovered ${VM_NAME} at ${VM_IP}"
  fi

  ensure_hosts_file
  update_inventory "${VM_NAME}" "${VM_IP}"
}

main "$@"
