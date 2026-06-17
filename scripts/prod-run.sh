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
  ensure_venv_path "${ROOT}"
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
  local log_file
  log_file="${LOG_DIR}/prod-run-$(date -u +%Y%m%dT%H%M%SZ).log"

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

  # Production must use its own vault password. ansible.cfg defaults
  # vault_password_file to .vault_pass_lab, so without this guard a production
  # run would silently decrypt with the LAB password. Require .vault_pass (or
  # VAULT_PASS) and override the lab default explicitly.
  local prod_vault="${ROOT}/.vault_pass"
  if [[ ! -f "${prod_vault}" && -n "${VAULT_PASS:-}" ]]; then
    printf '%s' "${VAULT_PASS}" > "${prod_vault}"
    chmod 600 "${prod_vault}"
  fi
  [[ -f "${prod_vault}" ]] || die "Missing ${prod_vault} (production vault password). Refusing to fall back to the lab vault — see docs/vault-schema.md"
  export ANSIBLE_VAULT_PASSWORD_FILE="${prod_vault}"

  ansible-playbook -i "${PROD_INVENTORY}" --vault-password-file "${prod_vault}" "${args[@]}" \
    2>&1 | tee -a "${log_file}"
}

main "$@"
