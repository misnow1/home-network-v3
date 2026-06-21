#!/usr/bin/env bash
# Validate AD migration cutover readiness (pre) or completion (post).
#
# Pre-cutover (before FSMO transfer / router DNS / pdc demotion):
#   ./scripts/migration/cutover-check.sh --phase pre --remote dc1.home.2123studios.com
#
# Post-cutover (after FSMO on dc1, DNS cutover, pdc demoted):
#   ./scripts/migration/cutover-check.sh --phase post --remote dc1.home.2123studios.com
#
# Does not perform FSMO transfer, router changes, or demotion — read-only validation.
# Manual steps: docs/migration-runbook.md Phase 1 Steps 5–8.
set -euo pipefail

PHASE=""
REMOTE_HOST=""
ON_DC=0
WARNINGS=0
FAILURES=0

AD_DOMAIN="${AD_DOMAIN:-home.2123studios.com}"
DC_NETBIOS="${DC_NETBIOS:-DC1}"
LEGACY_DC_NETBIOS="${LEGACY_DC_NETBIOS:-PDC}"
LEGACY_DC_FQDN="${LEGACY_DC_FQDN:-pdc.${AD_DOMAIN}}"
DC_FQDN="${DC_FQDN:-dc1.${AD_DOMAIN}}"
DC_IP="${DC_IP:-192.168.1.10}"
DDNS_API_PORT="${DDNS_API_PORT:-8765}"
DDNS_API_URL="${DDNS_API_URL:-http://127.0.0.1:${DDNS_API_PORT}/ddns/v1/health}"
SAMBA_LDB="${SAMBA_LDB:-/var/lib/samba/private/sam.ldb}"

usage() {
  grep '^#' "$0" | head -22 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:?}"; shift 2 ;;
    --on-dc) ON_DC=1; shift ;;
    --remote) REMOTE_HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "${PHASE}" == "pre" || "${PHASE}" == "post" ]] || {
  echo "--phase pre|post is required" >&2
  usage
  exit 2
}

pass() { echo "PASS: $*"; }
warn() { echo "WARN: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

run_samba_tool() {
  timeout "${1}" samba-tool "${@:2}"
}

check_replication() {
  local repl_out repl_rc=0
  repl_out="$(run_samba_tool 90 drs showrepl 2>&1)" || repl_rc=$?
  if [[ "${repl_rc}" -eq 124 ]]; then
    fail "drs showrepl timed out"
    return 1
  fi
  if grep -qE 'failed, result|WERR_' <<<"${repl_out}"; then
    fail "drs showrepl shows failures"
    grep -E 'failed, result|WERR_' <<<"${repl_out}" | head -10 || true
    return 1
  fi
  pass "drs showrepl clean"
  return 0
}

check_fsmo() {
  local fsmo_out
  fsmo_out="$(run_samba_tool 30 fsmo show 2>&1)" || {
    fail "samba-tool fsmo show failed"
    return 1
  }

  if [[ "${PHASE}" == "pre" ]]; then
    if grep -q "CN=${LEGACY_DC_NETBIOS}," <<<"${fsmo_out}"; then
      pass "FSMO still on ${LEGACY_DC_NETBIOS} (expected pre-cutover)"
    else
      warn "FSMO may already be on ${DC_NETBIOS} — cutover may have started"
    fi
    return 0
  fi

  if grep -q "CN=${DC_NETBIOS}," <<<"${fsmo_out}"; then
    pass "FSMO references ${DC_NETBIOS}"
  else
    fail "FSMO does not show ${DC_NETBIOS} — transfer roles before post-check"
    echo "${fsmo_out}"
    return 1
  fi

  if grep -q "CN=${LEGACY_DC_NETBIOS}," <<<"${fsmo_out}"; then
    fail "FSMO still on ${LEGACY_DC_NETBIOS} — complete transfer before post-check"
    echo "${fsmo_out}"
    return 1
  fi
  pass "FSMO off ${LEGACY_DC_NETBIOS}"
  return 0
}

check_dns_local() {
  local soa dc_a
  soa="$(dig @127.0.0.1 "${AD_DOMAIN}" SOA +short 2>/dev/null | head -1 || true)"
  [[ -n "${soa}" ]] && pass "SOA for ${AD_DOMAIN} via local BIND: ${soa}" || warn "No SOA from dig @127.0.0.1"

  dc_a="$(dig @127.0.0.1 "${DC_FQDN}" A +short 2>/dev/null | head -1 || true)"
  if [[ "${dc_a}" == "${DC_IP}" ]]; then
    pass "${DC_FQDN} A → ${DC_IP}"
  else
    warn "${DC_FQDN} A is '${dc_a:-<empty>}' (expected ${DC_IP})"
  fi
}

check_kinit_hint() {
  if command -v kinit >/dev/null 2>&1; then
    pass "kinit available — run: kinit Administrator@${AD_DOMAIN^^} (manual)"
  else
    warn "kinit not installed on this host"
  fi
}

check_ddns_api() {
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not installed — cannot check DDNS API (see docs/ddns-runbook.md)"
    return 0
  fi

  local health_out health_rc=0
  health_out="$(curl -fsS --connect-timeout 3 --max-time 10 "${DDNS_API_URL}" 2>&1)" || health_rc=$?

  if [[ "${health_rc}" -eq 0 && "${health_out}" == *ok* ]]; then
    pass "DDNS API healthy at ${DDNS_API_URL}"
    return 0
  fi

  if [[ "${PHASE}" == "pre" ]]; then
    fail "DDNS API not healthy at ${DDNS_API_URL} — run ddns-api.yml (docs/ddns-runbook.md)"
    [[ -n "${health_out}" ]] && echo "${health_out}" | head -3
    return 1
  fi

  warn "DDNS API check failed at ${DDNS_API_URL} — verify ddns-api.yml and router hook"
  [[ -n "${health_out}" ]] && echo "${health_out}" | head -3
  return 0
}

run_checks() {
  echo "=== Cutover check (${PHASE}): ${DC_FQDN} ==="

  [[ -f "${SAMBA_LDB}" ]] && pass "sam.ldb present" || fail "sam.ldb missing"
  systemctl is-active samba-ad-dc >/dev/null 2>&1 && pass "samba-ad-dc active" || fail "samba-ad-dc down"

  pass "Samba version: $(samba -V 2>/dev/null | head -1)"

  check_replication || true
  check_fsmo || true
  check_dns_local
  check_ddns_api || true
  check_kinit_hint

  if [[ "${PHASE}" == "pre" ]]; then
    echo ""
    echo "Pre-cutover manual steps (docs/migration-runbook.md):"
    echo "  1. ddns-api.yml on dc1 — docs/ddns-runbook.md"
    echo "  2. samba-tool fsmo transfer to ${DC_NETBIOS}"
    echo "  3. Router cutover — docs/unifi-gateway-dns.md"
    echo "  4. Validate clients, then samba-tool domain demote on ${LEGACY_DC_FQDN}"
    echo "  5. Re-run: cutover-check.sh --phase post --remote ${DC_FQDN}"
  else
    echo ""
    echo "Post-cutover: confirm DHCP DNS, DDNS hook (docs/unifi-gateway-dns.md),"
    echo "and demoted ${LEGACY_DC_FQDN} offline."
  fi

  echo "=== Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s) ==="
  [[ "${FAILURES}" -eq 0 ]]
}

dispatch_remote() {
  local root key user
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  key="${CUTOVER_CHECK_SSH_KEY:-${root}/scripts/vm/keys/prod_id_ed25519}"
  user="${CUTOVER_CHECK_SSH_USER:-ansible}"
  [[ -f "${key}" ]] || { echo "SSH key missing: ${key}" >&2; exit 1; }

  local -a remote_env=(
    "AD_DOMAIN=${AD_DOMAIN}"
    "DC_NETBIOS=${DC_NETBIOS}"
    "LEGACY_DC_NETBIOS=${LEGACY_DC_NETBIOS}"
    "LEGACY_DC_FQDN=${LEGACY_DC_FQDN}"
    "DC_FQDN=${DC_FQDN}"
    "DC_IP=${DC_IP}"
    "DDNS_API_URL=${DDNS_API_URL}"
    "PHASE=${PHASE}"
  )

  ssh -i "${key}" -o StrictHostKeyChecking=no -o ConnectTimeout=15 "${user}@${REMOTE_HOST}" \
    "sudo env ${remote_env[*]} bash -s -- --on-dc --phase ${PHASE}" <"$0"
}

if [[ -n "${REMOTE_HOST}" ]]; then
  dispatch_remote
elif [[ "${ON_DC}" -eq 1 ]] || [[ -f "${SAMBA_LDB}" ]]; then
  run_checks
else
  echo "Use --remote HOST --phase pre|post from the control node, or --on-dc on the DC." >&2
  usage
  exit 2
fi
