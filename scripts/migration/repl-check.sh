#!/usr/bin/env bash
# Read-only replication health check for a joined Samba AD DC (typically dc1).
#
# Run from the control node:
#   ./scripts/migration/repl-check.sh --remote dc1.home.2123studios.com
#
# Directly on the DC:
#   sudo ./scripts/migration/repl-check.sh --on-dc
#
# Mixed Samba versions (e.g. dc1 4.19.x replicating from pdc 4.21.x) are expected
# during migration — this script checks replication, not version parity.
# See docs/dc-runbook.md and scripts/migration/repl-check.sh.
set -euo pipefail

ON_DC=0
REMOTE_HOST=""
WARNINGS=0
FAILURES=0

AD_DOMAIN="${AD_DOMAIN:-home.2123studios.com}"
DC_FQDN="${DC_FQDN:-dc1.${AD_DOMAIN}}"
LEGACY_DC_NETBIOS="${LEGACY_DC_NETBIOS:-PDC}"
SAMBA_LDB="${SAMBA_LDB:-/var/lib/samba/private/sam.ldb}"

usage() {
  grep '^#' "$0" | head -18 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --on-dc) ON_DC=1; shift ;;
    --remote) REMOTE_HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

pass() { echo "PASS: $*"; }
warn() { echo "WARN: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

run_samba_tool() {
  # Running as root on the DC — no -U/--machine-pass needed (see dc-runbook.md).
  timeout "${1}" samba-tool "${@:2}"
}

run_checks() {
  echo "=== Replication check: ${DC_FQDN} (${AD_DOMAIN}) ==="

  command -v samba >/dev/null && pass "Samba: $(samba -V 2>/dev/null | head -1)" || fail "samba not found"
  systemctl is-active samba-ad-dc >/dev/null 2>&1 \
    && pass "samba-ad-dc active" \
    || fail "samba-ad-dc not active"
  systemctl is-active named >/dev/null 2>&1 && pass "named active" || warn "named not active"
  [[ -f "${SAMBA_LDB}" ]] && pass "sam.ldb present" || fail "sam.ldb missing — host not joined"

  echo "=== drs showrepl (up to 90s) ==="
  local repl_out repl_rc=0
  repl_out="$(run_samba_tool 90 drs showrepl 2>&1)" || repl_rc=$?
  if [[ "${repl_rc}" -eq 124 ]]; then
    fail "drs showrepl timed out after 90s"
  elif grep -qE 'failed, result|WERR_' <<<"${repl_out}"; then
    fail "drs showrepl shows failures"
    grep -E 'failed, result|WERR_|INBOUND' <<<"${repl_out}" | head -20 || true
  elif grep -qi 'was successful' <<<"${repl_out}"; then
    pass "drs showrepl reports successful inbound replication"
  else
    warn "drs showrepl completed without obvious failures — review output"
    head -30 <<<"${repl_out}"
  fi

  if grep -qi "${LEGACY_DC_NETBIOS}" <<<"${repl_out}" && grep -q "CN=${LEGACY_DC_NETBIOS}," <<<"${repl_out}"; then
    pass "Replication partner ${LEGACY_DC_NETBIOS} visible in drs output"
  else
    warn "Legacy DC ${LEGACY_DC_NETBIOS} not found in drs showrepl (may be post-cutover)"
  fi

  echo "=== dbcheck --cross-ncs (read-only, up to 120s) ==="
  local db_out db_rc=0
  db_out="$(run_samba_tool 120 dbcheck --cross-ncs 2>&1)" || db_rc=$?
  if [[ "${db_rc}" -eq 124 ]]; then
    fail "dbcheck timed out after 120s"
  elif grep -qiE '\([1-9][0-9]* errors?\)|[Ee]rror:' <<<"${db_out}"; then
    warn "dbcheck reported issues — review and consider: samba-tool dbcheck --cross-ncs --fix"
    grep -iE '\([1-9][0-9]* errors?\)|[Ee]rror:' <<<"${db_out}" | head -15 || true
  else
    pass "dbcheck --cross-ncs completed without errors"
  fi

  echo "=== domain info ==="
  if run_samba_tool 30 domain info 127.0.0.1 >/dev/null 2>&1; then
    pass "domain info 127.0.0.1 OK"
  else
    fail "samba-tool domain info 127.0.0.1 failed"
  fi

  echo "=== Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s) ==="
  [[ "${FAILURES}" -eq 0 ]]
}

dispatch_remote() {
  local root key user
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  key="${REPL_CHECK_SSH_KEY:-${root}/scripts/vm/keys/prod_id_ed25519}"
  user="${REPL_CHECK_SSH_USER:-ansible}"
  [[ -f "${key}" ]] || { echo "SSH key missing: ${key}" >&2; exit 1; }

  local -a remote_env=(
    "AD_DOMAIN=${AD_DOMAIN}"
    "DC_FQDN=${DC_FQDN}"
    "LEGACY_DC_NETBIOS=${LEGACY_DC_NETBIOS}"
  )

  ssh -i "${key}" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "${user}@${REMOTE_HOST}" \
    "sudo env ${remote_env[*]} bash -s -- --on-dc" <"$0"
}

if [[ -n "${REMOTE_HOST}" ]]; then
  dispatch_remote
elif [[ "${ON_DC}" -eq 1 ]] || [[ -f "${SAMBA_LDB}" ]]; then
  run_checks
else
  echo "Run on a joined DC with --on-dc, or use --remote HOST from the control node." >&2
  usage
  exit 2
fi
