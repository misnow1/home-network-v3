#!/usr/bin/env bash
# Tier 2 production safety checks — no real production inventory required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROD_RUN="${ROOT}/scripts/prod-run.sh"
PROD_INVENTORY="${ROOT}/inventories/production/hosts.yml"

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    die "Expected failure: ${description}"
  fi
  log_info "ok — ${description}"
}

main() {
  [[ -x "${PROD_RUN}" ]] || die "Missing executable ${PROD_RUN}"

  assert_fails "prod-run without --confirm-production" \
    "${PROD_RUN}" -- playbooks/baseline.yml

  assert_fails "prod-run without playbook args" \
    "${PROD_RUN}" --confirm-production

  if [[ ! -f "${PROD_INVENTORY}" ]]; then
    assert_fails "prod-run without production hosts.yml" \
      "${PROD_RUN}" --confirm-production -- playbooks/baseline.yml --list-hosts
  else
    log_warn "production hosts.yml exists — skipping missing-inventory test"
  fi

  log_info "test-prod-safety.sh passed"
}

main "$@"
