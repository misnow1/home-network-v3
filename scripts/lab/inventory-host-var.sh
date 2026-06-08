#!/usr/bin/env bash
# Look up lab host variables from Ansible inventory JSON output.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

host_var() {
  local fqdn="$1"
  local key="$2"
  require_cmd ansible-inventory
  require_cmd python3
  if [[ -x "${ROOT}/.venv/bin/ansible-inventory" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi
  ANSIBLE_CONFIG="${ROOT}/ansible.cfg" ansible-inventory \
    -i "${ROOT}/inventories/lab" \
    --host "${fqdn}" \
    | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get(sys.argv[1], ''))" "${key}"
}

main() {
  local fqdn="${1:?FQDN required}"
  local key="${2:?variable key required}"
  local value
  value="$(host_var "${fqdn}" "${key}")"
  [[ -n "${value}" ]] || die "Host ${fqdn} missing inventory var ${key}"
  printf '%s' "${value}"
}

main "$@"
