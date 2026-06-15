#!/usr/bin/env bash
# Look up host or merged inventory variables from Ansible inventory JSON output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROFILE="lab"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i PROFILE] <fqdn> <variable-key>

Options:
  -i, --inventory PROFILE   Inventory profile (default: lab)
  -h, --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done
  REMAINING_ARGS=("$@")
}

host_var() {
  local fqdn="$1"
  local key="$2"
  require_cmd ansible-inventory
  require_cmd python3
  if [[ -x "${ROOT}/.venv/bin/ansible-inventory" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi
  local inventory
  inventory="$(vm_profile_inventory "${PROFILE}")"
  ANSIBLE_CONFIG="${ROOT}/ansible.cfg" ansible-inventory \
    -i "${inventory}" \
    --host "${fqdn}" \
    | python3 -c "import json,sys; data=json.load(sys.stdin); v=data.get(sys.argv[1]); print('' if v is None else v if isinstance(v,str) else json.dumps(v))" "${key}"
}

main() {
  parse_args "$@"
  set -- "${REMAINING_ARGS[@]:-}"
  local fqdn="${1:?FQDN required}"
  local key="${2:?variable key required}"
  local value
  value="$(host_var "${fqdn}" "${key}")"
  if [[ "${key}" != "vm_ip" && "${key}" != "vm_use_dhcp" ]]; then
    [[ -n "${value}" ]] || die "Host ${fqdn} missing inventory var ${key}"
  fi
  printf '%s' "${value}"
}

main "$@"
