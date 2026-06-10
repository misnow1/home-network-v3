#!/usr/bin/env bash
# Read-only pre-flight checks before AD migration maintenance window.
# Does not connect to production hosts except optional SSH ping when inventory exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROD_INVENTORY="${ROOT}/inventories/production/hosts.yml"
PROD_VAULT="${ROOT}/inventories/production/group_vars/vault.yml"
VAULT_PASS="${ROOT}/.vault_pass"
WARNINGS=0

warn() {
  log_warn "$@"
  WARNINGS=$((WARNINGS + 1))
}

pass() {
  log_info "OK: $*"
}

main() {
  require_repo_root >/dev/null
  log_info "AD migration pre-flight (read-only)"

  if [[ -f "${PROD_INVENTORY}" ]]; then
    pass "Production inventory exists: ${PROD_INVENTORY}"
  else
    warn "Missing ${PROD_INVENTORY} — copy from hosts.yml.example before migration"
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
    dc_hosts="$(ansible-inventory -i "${PROD_INVENTORY}" --list 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(' '.join(d.get('dc',{}).get('hosts',[])))" 2>/dev/null || true)"
    if [[ -n "${dc_hosts}" ]]; then
      pass "DC hosts in inventory: ${dc_hosts}"
      if command -v ansible >/dev/null 2>&1; then
        for host in ${dc_hosts}; do
          if ansible -i "${PROD_INVENTORY}" "${host}" -m ping -o 2>/dev/null | grep -q SUCCESS; then
            pass "SSH ping succeeded: ${host}"
            if ansible -i "${PROD_INVENTORY}" "${host}" -m command -a "test ! -f /var/lib/samba/private/sam.ldb" -o 2>/dev/null | grep -q SUCCESS; then
              pass "No sam.ldb on ${host} (ready for restore)"
            else
              warn "${host} already has sam.ldb — dc-restore requires a fresh host"
            fi
            if ansible -i "${PROD_INVENTORY}" "${host}" -m command -a "samba -V" -o 2>/dev/null; then
              pass "Samba version on ${host} (compare with old pdc manually)"
            fi
          else
            warn "SSH ping failed or skipped for ${host} (check SSH and inventory)"
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
