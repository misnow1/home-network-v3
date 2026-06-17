#!/usr/bin/env bash
# Read-only audit of the legacy Samba AD DC (pdc) before dc1 replica join.
#
# From the control node (SSH to pdc):
#   AD_ADMIN_PASSWORD='…' ./scripts/migration/pdc-audit.sh --remote pdc.home.2123studios.com
#
# Directly on pdc (copy script or pipe stdin):
#   curl … | sudo AD_ADMIN_PASSWORD='…' bash -s -- --on-pdc
#   sudo AD_ADMIN_PASSWORD='…' /path/to/pdc-audit.sh --on-pdc
#
# Apply AD repairs after reviewing audit output:
#   … pdc-audit.sh --on-pdc --apply-fixes
#
# Environment: AD_DOMAIN, PDC_FQDN, PDC_IP, JOIN_SITE, STALE_DC_NETBIOS, AD_ADMIN_PASSWORD
set -euo pipefail

ON_PDC=0
REMOTE_HOST=""
APPLY_FIXES=0
WARNINGS=0
FAILURES=0

AD_DOMAIN="${AD_DOMAIN:-home.2123studios.com}"
AD_REALM="${AD_REALM:-HOME.2123STUDIOS.COM}"
PDC_FQDN="${PDC_FQDN:-pdc.${AD_DOMAIN}}"
PDC_IP="${PDC_IP:-192.168.1.2}"
PDC_NETBIOS="${PDC_NETBIOS:-PDC}"
JOIN_SITE="${JOIN_SITE:-FerryCrossing}"
STALE_DC_NETBIOS="${STALE_DC_NETBIOS:-DC1}"
SAMBA_LDB="${SAMBA_LDB:-/var/lib/samba/private/sam.ldb}"
CONFIG_DN="CN=Configuration,DC=home,DC=2123studios,DC=com"

usage() {
  grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --on-pdc) ON_PDC=1; shift ;;
    --remote) REMOTE_HOST="${2:?}"; shift 2 ;;
    --apply-fixes) APPLY_FIXES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

pass() { echo "PASS: $*"; }
warn() { echo "WARN: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }

samba_tool() {
  local -a auth_args=()
  if [[ -n "${AD_ADMIN_PASSWORD:-}" ]]; then
    auth_args=(-UAdministrator)
    PASSWD="${AD_ADMIN_PASSWORD}" samba-tool "${auth_args[@]}" "$@"
  else
    samba-tool --machine-pass "$@"
  fi
}

dns_local() {
  dig @"127.0.0.1" +short "$@" 2>/dev/null || true
}

pdc_object_guid() {
  local servers_dn="CN=Servers,CN=${JOIN_SITE},CN=Sites,${CONFIG_DN}"
  local guid
  guid="$(ldbsearch -H "${SAMBA_LDB}" \
    -b "CN=NTDS Settings,CN=${PDC_NETBIOS},${servers_dn}" \
    -s base objectGUID 2>/dev/null | awk '/^objectGUID: / {print $2; exit}')"
  if [[ -z "${guid}" ]]; then
    guid="$(ldbsearch -H "${SAMBA_LDB}" -b "${servers_dn}" \
      -s sub "(cn=${PDC_NETBIOS})" objectGUID 2>/dev/null | awk '/^objectGUID: / {print $2; exit}')"
  fi
  printf '%s' "${guid}"
}

zone_apex_ns_count() {
  local zone="$1" out rc=0
  out="$(samba_tool dns query localhost "${zone}" @ NS 2>/dev/null)" || rc=$?
  [[ "${rc}" -ne 0 ]] && { echo 0; return; }
  grep -cE '^[[:space:]]+NS:' <<<"${out}" || echo 0
}

run_checks() {
  echo "=== PDC audit: ${AD_DOMAIN} (site=${JOIN_SITE}, apply_fixes=${APPLY_FIXES}) ==="

  command -v samba >/dev/null && pass "Samba: $(samba -V 2>/dev/null | head -1)" || fail "samba not found"
  systemctl is-active samba >/dev/null 2>&1 && pass "samba active" || fail "samba not active"
  [[ -f "${SAMBA_LDB}" ]] && pass "sam.ldb present" || fail "sam.ldb missing"

  if grep -qE '^\s*dns hostname\s*=' /etc/samba/smb.conf 2>/dev/null; then
    warn "smb.conf has dns hostname= (4.20+ only on dc1; remove on 4.19 after join)"
  fi

  local stale
  stale="$(samba_tool computer list 2>/dev/null | grep -i "${STALE_DC_NETBIOS}" || true)"
  if [[ -z "${stale}" ]]; then
    pass "No ${STALE_DC_NETBIOS} computer account (ready for rejoin)"
  else
    fail "Remove stale DC: samba-tool domain demote --remove-other-dead-server=${STALE_DC_NETBIOS} -UAdministrator"
    echo "${stale}"
  fi

  local sites site
  sites="$(samba_tool sites list 2>/dev/null || true)"
  for site in FerryCrossing Woodbine Swanhollow; do
    grep -qx "${site}" <<<"${sites}" && pass "Site: ${site}" || fail "Missing site: ${site}"
  done

  local servers_dn="CN=Servers,CN=${JOIN_SITE},CN=Sites,${CONFIG_DN}"
  if ldbsearch -H "${SAMBA_LDB}" -b "${servers_dn}" -s base dn 2>/dev/null | grep -q '^dn:'; then
    pass "CN=Servers,CN=${JOIN_SITE} exists"
  else
    fail "Missing ${servers_dn}"
  fi

  local pdc_a pdc_aaaa
  pdc_a="$(dns_local "${PDC_FQDN}" A)"
  pdc_aaaa="$(dns_local "${PDC_FQDN}" AAAA)"
  [[ "${pdc_a}" == "${PDC_IP}" ]] && pass "${PDC_FQDN} A=${PDC_IP}" || fail "${PDC_FQDN} A='${pdc_a:-empty}' (want ${PDC_IP})"
  [[ -z "${pdc_aaaa}" ]] && pass "No stale ${PDC_FQDN} AAAA" || warn "${PDC_FQDN} AAAA=${pdc_aaaa}"

  local guid guid_cname
  guid="$(pdc_object_guid)"
  if [[ -n "${guid}" ]]; then
    pass "pdc objectGUID ${guid}"
    guid_cname="$(dns_local "${guid}._msdcs.${AD_DOMAIN}" CNAME)"
    if [[ -n "${guid_cname}" ]]; then
      pass "_msdcs GUID CNAME → ${guid_cname}"
    else
      fail "Missing ${guid}._msdcs.${AD_DOMAIN} CNAME"
      echo "  Fix: samba-tool dns add localhost _msdcs.${AD_DOMAIN} ${guid} CNAME ${PDC_FQDN}. -UAdministrator"
    fi
  else
    fail "Could not read pdc objectGUID from ldb"
  fi

  local zonelist zone ns_count
  zonelist="$(samba_tool dns zonelist localhost 2>/dev/null || true)"
  while read -r zone; do
    [[ -z "${zone}" ]] && continue
    ns_count="$(zone_apex_ns_count "${zone}")"
    if [[ "${ns_count}" -ge 1 ]]; then
      pass "Apex NS: ${zone}"
    else
      warn "Missing apex NS: ${zone}"
      echo "  Fix: samba-tool dns add localhost ${zone} @ NS ${PDC_FQDN}. -UAdministrator"
    fi
  done < <(printf '%s\n' "${zonelist}" | awk -F': ' '/pszZoneName/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')

  echo "=== drs showrepl (up to 90s) ==="
  local repl_out repl_rc=0
  repl_out="$(timeout 90 samba_tool drs showrepl 2>&1)" || repl_rc=$?
  if [[ "${repl_rc}" -eq 124 ]]; then
    warn "drs showrepl timed out"
  elif grep -qE 'failed, result|WERR_' <<<"${repl_out}"; then
    fail "drs showrepl shows failures"
    grep -E 'failed, result|WERR_|INBOUND' <<<"${repl_out}" | head -15 || true
  else
    pass "drs showrepl OK"
  fi
  if grep -qi 'DC1' <<<"${repl_out}"; then
    warn "drs output still mentions DC1"
  fi

  if samba_tool fsmo show 2>/dev/null | grep -qi "${PDC_NETBIOS}"; then
    pass "FSMO on pdc (expected pre-cutover)"
  else
    warn "Review FSMO: samba-tool fsmo show"
  fi

  if [[ "${APPLY_FIXES}" -eq 1 ]]; then
    echo "=== apply-fixes ==="
    samba_tool drs kcc && pass "drs kcc" || warn "drs kcc failed"
    samba_tool dbcheck --cross-ncs --fix && pass "dbcheck --fix" || warn "dbcheck reported issues"
    echo "Re-run: samba_dnsupdate --verbose  (review AAAA failures manually)"
  fi

  echo "=== Summary: ${FAILURES} failure(s), ${WARNINGS} warning(s) ==="
  [[ "${FAILURES}" -eq 0 ]]
}

dispatch_remote() {
  local root key user
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  key="${PDC_AUDIT_SSH_KEY:-${root}/scripts/vm/keys/prod_id_ed25519}"
  user="${PDC_AUDIT_SSH_USER:-ansible}"
  [[ -f "${key}" ]] || { echo "SSH key missing: ${key}" >&2; exit 1; }

  local -a remote_env=(
    "AD_DOMAIN=${AD_DOMAIN}"
    "PDC_FQDN=${PDC_FQDN}"
    "PDC_IP=${PDC_IP}"
    "JOIN_SITE=${JOIN_SITE}"
    "STALE_DC_NETBIOS=${STALE_DC_NETBIOS}"
    "APPLY_FIXES=${APPLY_FIXES}"
  )
  [[ -n "${AD_ADMIN_PASSWORD:-}" ]] && remote_env+=("AD_ADMIN_PASSWORD=${AD_ADMIN_PASSWORD}")

  ssh -i "${key}" -o StrictHostKeyChecking=no "${user}@${REMOTE_HOST}" \
    "sudo -E env ${remote_env[*]} bash -s -- --on-pdc ${APPLY_FIXES:+--apply-fixes}" <"$0"
}

if [[ -n "${REMOTE_HOST}" ]]; then
  dispatch_remote
elif [[ "${ON_PDC}" -eq 1 ]] || [[ -f "${SAMBA_LDB}" ]]; then
  run_checks
else
  echo "Run on pdc with --on-pdc, or use --remote HOST from the control node." >&2
  usage
  exit 2
fi
