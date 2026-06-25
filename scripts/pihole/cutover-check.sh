#!/usr/bin/env bash
# Validate Pi-hole DNS cutover readiness (pre) or completion (post).
#
# Pre-cutover (after pihole-converge.yml, before UniFi DHCP DNS change):
#   ./scripts/pihole/cutover-check.sh --phase pre
#
# Post-cutover (after UniFi DHCP DNS → Pi-hole, router forwarders retired):
#   ./scripts/pihole/cutover-check.sh --phase post
#
# Environment overrides: PIHOLE1, PIHOOLE2, DC1, DC2, AD_DOMAIN, ROUTER
set -euo pipefail

PHASE=""
WARNINGS=0
FAILURES=0

PIHOLE1="${PIHOLE1:-192.168.1.18}"
PIHOLE2="${PIHOLE2:-192.168.1.22}"
DC1="${DC1:-192.168.1.10}"
DC2="${DC2:-192.168.1.11}"
AD_DOMAIN="${AD_DOMAIN:-home.2123studios.com}"
ROUTER="${ROUTER:-192.168.1.1}"
BLOCK_TEST="${BLOCK_TEST:-doubleclick.net}"

usage() {
  grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase) PHASE="${2:?}"; shift 2 ;;
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

require_dig() {
  command -v dig >/dev/null 2>&1 || {
    fail "dig is required"
    exit 2
  }
}

check_pihole_ad_forward() {
  local pihole_ip="$1"
  local label="$2"
  local out

  out="$(dig +time=2 +tries=1 "@${pihole_ip}" "dc1.${AD_DOMAIN}" A +short 2>/dev/null | head -1 || true)"
  if [[ "${out}" == "${DC1}" ]]; then
    pass "${label}: forwards AD A record for dc1"
  else
    fail "${label}: dc1.${AD_DOMAIN} A via Pi-hole (got '${out:-empty}', want ${DC1})"
  fi

  out="$(dig +time=2 +tries=1 "@${pihole_ip}" "_ldap._tcp.${AD_DOMAIN}" SRV +short 2>/dev/null | head -1 || true)"
  if [[ -n "${out}" ]]; then
    pass "${label}: resolves AD SRV via DC forward"
  else
    fail "${label}: _ldap._tcp.${AD_DOMAIN} SRV empty via Pi-hole"
  fi
}

check_pihole_blocking() {
  local pihole_ip="$1"
  local label="$2"
  local out rc=0

  out="$(dig +time=2 +tries=1 "@${pihole_ip}" "${BLOCK_TEST}" A +short 2>/dev/null || true)" || rc=$?
  if [[ -z "${out}" || "${out}" == "0.0.0.0" ]]; then
    pass "${label}: blocklist active for ${BLOCK_TEST}"
  else
    warn "${label}: ${BLOCK_TEST} returned '${out}' (may be allowlisted or blocklist disabled)"
  fi
}

check_dc_authoritative() {
  local out
  out="$(dig +time=2 +tries=1 "@${DC1}" "${AD_DOMAIN}" SOA +short 2>/dev/null | head -1 || true)"
  if [[ -n "${out}" ]]; then
    pass "dc1 authoritative SOA for ${AD_DOMAIN}"
  else
    fail "dc1 SOA for ${AD_DOMAIN} empty"
  fi
}

check_router_not_forwarding_ad() {
  local conf_ok=1
  if command -v ssh >/dev/null 2>&1; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "root@${ROUTER}" \
      'grep -rh "server=/home" /run/dnsmasq.dhcp.conf.d/ /data/on_boot.d/ 2>/dev/null | grep -v "\.disabled" | head -1' 2>/dev/null | grep -q 'server=/'; then
      conf_ok=0
    fi
  else
    warn "ssh unavailable — skip router forwarder check"
    return 0
  fi

  if [[ "${conf_ok}" -eq 1 ]]; then
    pass "router has no active server=/home AD forwarding inject"
  else
    if [[ "${PHASE}" == "post" ]]; then
      fail "router still has server=/home AD forwarding — retire legacy on-boot scripts"
    else
      warn "router still has server=/home AD forwarding (expected until post-cutover cleanup)"
    fi
  fi
}

main() {
  require_dig

  echo "=== Pi-hole cutover check (${PHASE}) ==="
  echo "Pi-hole: ${PIHOLE1}, ${PIHOLE2} | DCs: ${DC1}, ${DC2} | domain: ${AD_DOMAIN}"

  check_dc_authoritative
  check_pihole_ad_forward "${PIHOLE1}" "pihole1"
  check_pihole_ad_forward "${PIHOLE2}" "pihole2"
  check_pihole_blocking "${PIHOLE1}" "pihole1"
  check_pihole_blocking "${PIHOLE2}" "pihole2"

  if [[ "${PHASE}" == "post" ]]; then
    check_router_not_forwarding_ad
    pass "manual: confirm UniFi DHCP DNS is ${PIHOLE1} and ${PIHOLE2} on VLAN 1 and IoT VLAN 2"
    pass "manual: confirm Pi-hole query log shows client IPs (not ${DC1})"
    pass "manual: confirm UniFi client hostnames visible after lease renew"
    pass "manual: DDNS lease test — dig @${DC1} <hostname>.${AD_DOMAIN} A after renew"
  else
    warn "pre-cutover: clients may still use old DNS until UniFi DHCP is updated"
    pass "manual: run pihole-converge.yml on both hosts before changing DHCP"
  fi

  echo "=== Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s) ==="
  [[ "${FAILURES}" -eq 0 ]]
}

main "$@"
