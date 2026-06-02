#!/usr/bin/env bash
# Production playbook wrapper — requires explicit confirmation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

CONFIRM=0
LOG_DIR="${ROOT}/logs"
PROD_INVENTORY="${ROOT}/inventories/production/hosts.yml"

usage() {
  cat <<EOF
Usage: $(basename "$0") --confirm-production -- ansible-playbook [args...]

Runs ansible-playbook against production inventory with logging and guardrails.
See docs/run-order.md.

Example:
  $(basename "$0") --confirm-production -- playbooks/baseline.yml --limit nas.example.home
EOF
}

main() {
  require_cmd ansible-playbook

  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --confirm-production)
        CONFIRM=1
        shift
        ;;
      --)
        shift
        args=("$@")
        break
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1 (use -- before ansible-playbook args)"
        ;;
    esac
  done

  [[ "${CONFIRM}" -eq 1 ]] || die "Refusing to run without --confirm-production"
  [[ -f "${PROD_INVENTORY}" ]] || die "Missing ${PROD_INVENTORY} — copy from hosts.yml.example"
  [[ ${#args[@]} -gt 0 ]] || die "No ansible-playbook arguments provided"

  mkdir -p "${LOG_DIR}"
  local log_file="${LOG_DIR}/prod-run-$(date -u +%Y%m%dT%H%M%SZ).log"

  log_info "Logging production run to ${log_file}"
  {
    echo "# timestamp: $(date -u --iso-8601=seconds)"
    echo "# user: ${USER}"
    echo "# cwd: ${ROOT}"
    echo "# command: ansible-playbook -i inventories/production ${args[*]}"
  } >> "${log_file}"

  ansible_env() {
    export ANSIBLE_CONFIG="${ROOT}/ansible.cfg"
  }
  ansible_env

  if [[ -f "${ROOT}/.vault_pass" ]]; then
    ansible-playbook -i "${PROD_INVENTORY}" --vault-password-file "${ROOT}/.vault_pass" "${args[@]}" \
      2>&1 | tee -a "${log_file}"
  else
    ansible-playbook -i "${PROD_INVENTORY}" "${args[@]}" 2>&1 | tee -a "${log_file}"
  fi
}

main "$@"
