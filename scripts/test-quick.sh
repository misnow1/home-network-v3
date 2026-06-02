#!/usr/bin/env bash
# Tier 1+2 tests: linters, syntax-check, and structural playbooks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/ansible.sh
source "${ROOT}/scripts/lib/ansible.sh"

main() {
  if [[ -x "${ROOT}/.venv/bin/ansible-playbook" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi

  require_cmd yamllint
  require_cmd ansible-lint
  require_cmd ansible-playbook

  ensure_vault_password_file "${ROOT}" >/dev/null

  log_info "Tier 1 — yamllint"
  (cd "${ROOT}" && yamllint .)

  log_info "Tier 1 — ansible-lint"
  (cd "${ROOT}" && ansible-lint)

  log_info "Tier 1 — ansible-playbook --syntax-check"
  run_ansible_syntax_check "${ROOT}"

  log_info "Tier 2 — structural tests"
  for test_playbook in "${ROOT}"/tests/structural/*.yml; do
    [[ -f "${test_playbook}" ]] || continue
    log_info "running ${test_playbook}"
    run_ansible_playbook "${ROOT}" "${test_playbook}"
  done

  log_info "test-quick.sh passed"
}

main "$@"
