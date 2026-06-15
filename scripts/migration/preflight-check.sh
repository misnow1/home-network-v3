#!/usr/bin/env bash
# Read-only pre-flight checks before AD migration maintenance window.
# Does not connect to production hosts except optional SSH ping when inventory exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROD_INVENTORY_DIR="${ROOT}/inventories/production"
PROD_INVENTORY="${PROD_INVENTORY_DIR}/hosts.yml"
PROD_VAULT="${PROD_INVENTORY_DIR}/group_vars/vault.yml"
VAULT_PASS="${ROOT}/.vault_pass"
PROD_SSH_KEY="${ROOT}/scripts/vm/keys/prod_id_ed25519"
WARNINGS=0

ANSIBLE_SSH_USER=""
ANSIBLE_SSH_KEY=""

warn() {
  log_warn "$@"
  WARNINGS=$((WARNINGS + 1))
}

pass() {
  log_info "OK: $*"
}

prod_inventory_arg() {
  if [[ -d "${PROD_INVENTORY_DIR}" && -f "${PROD_INVENTORY}" ]]; then
    printf '%s' "${PROD_INVENTORY_DIR}"
  else
    printf '%s' "${PROD_INVENTORY}"
  fi
}

# Resolve SSH user/key from inventory merged vars, with repo defaults as fallback.
load_prod_ansible_ssh() {
  local host="${1:-}"

  ANSIBLE_SSH_USER="ansible"
  ANSIBLE_SSH_KEY="${PROD_SSH_KEY}"

  if [[ -n "${host}" ]] && command -v ansible-inventory >/dev/null 2>&1 && [[ -f "${PROD_INVENTORY}" ]]; then
    local host_vars
    host_vars="$(ansible-inventory -i "$(prod_inventory_arg)" --host "${host}" 2>/dev/null || true)"
    if [[ -n "${host_vars}" && "${host_vars}" != "{}" ]]; then
      local inv_user inv_key
      inv_user="$(printf '%s' "${host_vars}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ansible_user') or '')" 2>/dev/null || true)"
      inv_key="$(printf '%s' "${host_vars}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ansible_ssh_private_key_file') or '')" 2>/dev/null || true)"
      [[ -n "${inv_user}" ]] && ANSIBLE_SSH_USER="${inv_user}"
      if [[ -n "${inv_key}" && -f "${inv_key}" ]]; then
        ANSIBLE_SSH_KEY="${inv_key}"
      fi
    fi
  fi

  if [[ ! -f "${ANSIBLE_SSH_KEY}" ]]; then
    warn "Production SSH private key not found at ${ANSIBLE_SSH_KEY} (run ./scripts/vm/keys-ensure.sh -i production)"
    return 1
  fi

  pass "Using SSH user ${ANSIBLE_SSH_USER} with key ${ANSIBLE_SSH_KEY#"${ROOT}/"}"
  return 0
}

run_ansible_adhoc() {
  local host="$1"
  local module="$2"
  local module_args="${3:-}"

  load_prod_ansible_ssh "${host}" || return 1

  local -a cmd=(
    ansible -i "$(prod_inventory_arg)"
    -u "${ANSIBLE_SSH_USER}"
    --private-key "${ANSIBLE_SSH_KEY}"
    "${host}"
    -m "${module}"
    -o
  )
  if [[ -n "${module_args}" ]]; then
    cmd+=(-a "${module_args}")
  fi

  "${cmd[@]}"
}

run_ansible_ping() {
  local host="$1"
  local ping_out

  if ! ping_out="$(run_ansible_adhoc "${host}" ping 2>&1)"; then
    warn "SSH ping failed for ${host}: ${ping_out}"
    return 1
  fi

  if grep -q SUCCESS <<<"${ping_out}"; then
    pass "SSH ping succeeded: ${host}"
    return 0
  fi

  warn "SSH ping failed for ${host}: ${ping_out}"
  return 1
}

main() {
  require_repo_root >/dev/null
  log_info "AD migration pre-flight (read-only)"

  if [[ -f "${PROD_INVENTORY}" ]]; then
    pass "Production inventory exists: ${PROD_INVENTORY}"
  else
    warn "Missing ${PROD_INVENTORY} — copy from hosts.yml.example before migration"
  fi

  local prod_ansible_yml="${PROD_INVENTORY_DIR}/group_vars/all/ansible.yml"
  if [[ -f "${prod_ansible_yml}" ]]; then
    pass "Production ansible.yml exists: ${prod_ansible_yml#"${ROOT}/"}"
  else
    warn "Missing ${prod_ansible_yml#"${ROOT}/"} — copy from group_vars/all/ansible.yml.example (preflight uses prod key fallback)"
  fi

  if [[ -f "${PROD_VAULT}" ]]; then
    pass "Production vault file exists: ${PROD_VAULT}"
  else
    warn "Missing ${PROD_VAULT} — create with ansible-vault before migration"
  fi

  if [[ -f "${VAULT_PASS}" ]]; then
    pass "Production vault password file exists: ${VAULT_PASS}"
    if [[ -f "${PROD_VAULT}" ]]; then
      if ansible-vault view "${PROD_VAULT}" --vault-password-file "${VAULT_PASS}" >/dev/null 2>&1; then
        pass "Production vault decrypts with .vault_pass"
      else
        warn "Production vault does not decrypt with .vault_pass"
      fi
    fi
  else
    warn "Missing ${VAULT_PASS} — cannot verify vault decrypt"
  fi

  for doc in \
    "${ROOT}/docs/migration-runbook.md" \
    "${ROOT}/playbooks/dc-restore.yml" \
    "${ROOT}/roles/samba_dc/tasks/restore.yml"; do
    if [[ -f "${doc}" ]]; then
      pass "Present: ${doc#"${ROOT}/"}"
    else
      warn "Missing expected file: ${doc#"${ROOT}/"}"
    fi
  done

  if [[ -f "${PROD_INVENTORY}" ]] && command -v ansible-inventory >/dev/null 2>&1; then
    local dc_hosts
    dc_hosts="$(ansible-inventory -i "$(prod_inventory_arg)" --list 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('dc',{}).get('hosts',[])))" 2>/dev/null || true)"
    if [[ -n "${dc_hosts}" ]]; then
      pass "DC hosts in inventory: ${dc_hosts}"
      if command -v ansible >/dev/null 2>&1; then
        for host in ${dc_hosts}; do
          if run_ansible_ping "${host}"; then
            if run_ansible_adhoc "${host}" command "test ! -f /var/lib/samba/private/sam.ldb" 2>/dev/null | grep -q SUCCESS; then
              pass "No sam.ldb on ${host} (ready for restore)"
            else
              warn "${host} already has sam.ldb — dc-restore requires a fresh host"
            fi
            local samba_out
            if samba_out="$(run_ansible_adhoc "${host}" command "samba -V" 2>&1)" && grep -q SUCCESS <<<"${samba_out}"; then
              pass "Samba version on ${host} (compare with old pdc manually)"
              grep -v 'SUCCESS =>' <<<"${samba_out}" | grep -v '^$' || true
            fi
          fi
        done
      fi
    else
      warn "No hosts in dc group — check production inventory"
    fi
  fi

  log_info "Pre-flight complete (${WARNINGS} warning(s))"
  if [[ "${WARNINGS}" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
