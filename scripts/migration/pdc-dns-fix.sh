#!/usr/bin/env bash
# Bulk DNS repairs on pdc using Administrator (not --machine-pass).
#
# Use when samba_dnsupdate / --machine-pass fail (Kerberos desync or IPv6 RPC).
# Always targets 127.0.0.1 to avoid stale AAAA on pdc.home.2123studios.com.
#
#   AD_ADMIN_PASSWORD='…' ./scripts/migration/pdc-dns-fix.sh --on-pdc
#   AD_ADMIN_PASSWORD='…' ./scripts/migration/pdc-dns-fix.sh --remote pdc.home.2123studios.com
#
# Options: --delete-pdc-aaaa  --add-zone-ns  --add-pdc-guid-cname  --all (default)
set -euo pipefail

ON_PDC=0
REMOTE_HOST=""
DO_AAAA=1
DO_NS=1
DO_GUID=1

AD_DOMAIN="${AD_DOMAIN:-home.2123studios.com}"
PDC_FQDN="${PDC_FQDN:-pdc.${AD_DOMAIN}}"
PDC_IP="${PDC_IP:-192.168.1.2}"
PDC_NETBIOS="${PDC_NETBIOS:-PDC}"
DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
SAMBA_LDB="${SAMBA_LDB:-/var/lib/samba/private/sam.ldb}"
CONFIG_DN="CN=Configuration,DC=home,DC=2123studios,DC=com"
JOIN_SITE="${JOIN_SITE:-FerryCrossing}"

usage() {
  grep '^#' "$0" | head -15 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --on-pdc) ON_PDC=1; shift ;;
    --remote) REMOTE_HOST="${2:?}"; shift 2 ;;
    --delete-pdc-aaaa) DO_AAAA=1; DO_NS=0; DO_GUID=0; shift ;;
    --add-zone-ns) DO_AAAA=0; DO_NS=1; DO_GUID=0; shift ;;
    --add-pdc-guid-cname) DO_AAAA=0; DO_NS=0; DO_GUID=1; shift ;;
    --all) DO_AAAA=1; DO_NS=1; DO_GUID=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "${AD_ADMIN_PASSWORD:-}" ]] || {
  echo "Set AD_ADMIN_PASSWORD (Administrator password)." >&2
  exit 1
}

samba_tool() {
  PASSWD="${AD_ADMIN_PASSWORD}" samba-tool "$@" -UAdministrator
}

pdc_object_guid() {
  local servers_dn="CN=Servers,CN=${JOIN_SITE},CN=Sites,${CONFIG_DN}"
  ldbsearch -H "${SAMBA_LDB}" \
    -b "CN=NTDS Settings,CN=${PDC_NETBIOS},${servers_dn}" \
    -s base objectGUID 2>/dev/null | awk '/^objectGUID: / {print $2; exit}'
}

run_fixes() {
  echo "=== pdc-dns-fix (server=${DNS_SERVER}) ==="

  if [[ "${DO_AAAA}" -eq 1 ]]; then
    echo "--- delete stale pdc AAAA in home.2123studios.com ---"
    local out ip
    out="$(samba_tool dns query "${DNS_SERVER}" home.2123studios.com pdc ALL 2>/dev/null || true)"
    while read -r ip; do
      [[ -z "${ip}" ]] && continue
      echo "  delete AAAA ${ip}"
      samba_tool dns delete "${DNS_SERVER}" home.2123studios.com pdc AAAA "${ip}" \
        || echo "  (delete failed or already gone)"
    done < <(grep -E '^[[:space:]]+AAAA:' <<<"${out}" | awk '{print $2}')
    echo "  dig check: $(dig +short @"${DNS_SERVER}" "${PDC_FQDN}" AAAA | tr '\n' ' ')"
  fi

  if [[ "${DO_GUID}" -eq 1 ]]; then
    local guid
    guid="$(pdc_object_guid)"
    [[ -n "${guid}" ]] || { echo "Could not read pdc objectGUID" >&2; exit 1; }
    echo "--- ensure _msdcs GUID CNAME ${guid} ---"
    samba_tool dns add "${DNS_SERVER}" "_msdcs.${AD_DOMAIN}" "${guid}" CNAME "${PDC_FQDN}." \
      --allow-existing || true
  fi

  if [[ "${DO_NS}" -eq 1 ]]; then
    echo "--- ensure apex NS on all zones ---"
    local zonelist zone out ns_count
    zonelist="$(samba_tool dns zonelist "${DNS_SERVER}" 2>/dev/null)"
    while read -r zone; do
      [[ -z "${zone}" ]] && continue
      out="$(samba_tool dns query "${DNS_SERVER}" "${zone}" @ NS 2>/dev/null || true)"
      ns_count="$(grep -cE '^[[:space:]]+NS:' <<<"${out}" || true)"
      if [[ "${ns_count}" -ge 1 ]]; then
        echo "  OK NS: ${zone}"
      else
        echo "  add NS: ${zone}"
        samba_tool dns add "${DNS_SERVER}" "${zone}" @ NS "${PDC_FQDN}." --allow-existing
      fi
    done < <(printf '%s\n' "${zonelist}" | awk -F': ' '/pszZoneName/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
  fi

  echo "=== done — verify: dig +short @${DNS_SERVER} ${PDC_FQDN} AAAA (empty) ==="
}

dispatch_remote() {
  local root key user
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  key="${PDC_AUDIT_SSH_KEY:-${root}/scripts/vm/keys/prod_id_ed25519}"
  user="${PDC_AUDIT_SSH_USER:-ansible}"
  ssh -i "${key}" -o StrictHostKeyChecking=no "${user}@${REMOTE_HOST}" \
    "sudo -E env AD_ADMIN_PASSWORD='${AD_ADMIN_PASSWORD}' AD_DOMAIN='${AD_DOMAIN}' bash -s -- --on-pdc" <"$0"
}

if [[ -n "${REMOTE_HOST}" ]]; then
  dispatch_remote
elif [[ "${ON_PDC}" -eq 1 ]] || [[ -f "${SAMBA_LDB}" ]]; then
  run_fixes
else
  echo "Use --on-pdc or --remote HOST" >&2
  exit 2
fi
