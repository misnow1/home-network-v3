#!/bin/bash
# Point UniFi dnsmasq dhcp-script at a chained wrapper (UniFi hook + DDNS API hook).
# Install: /data/on_boot.d/20-home-ddns.sh (chmod 755)
# See docs/unifi-gateway-dns.md
#
# dnsmasq allows only ONE dhcp-script across all includes. UniFi sets it in
# shared.conf (→ /tmp/dnsmasq-main.dhcp.script → dnsmasq-dhcp-script). Do not add
# a second dhcp-script= line in home-ddns.conf.

set -euo pipefail

LOG="/data/home-ddns/install.log"
HOOK="/data/home-ddns/dhcp-ddns-hook.sh"
WRAPPER="/data/home-ddns/dhcp-script-wrapper.sh"
ENV_FILE="/data/home-ddns/home-ddns.env"
BACKUP_LINE="/data/home-ddns/shared-dhcp-script.line.bak"
LEGACY_INJECT_NAME="home-ddns.conf"

log() {
  echo "$(date -Iseconds) $*" | tee -a "${LOG}"
}

reload_main_dnsmasq() {
  if [[ -f /run/dnsmasq-main.pid ]]; then
    kill "$(cat /run/dnsmasq-main.pid)" 2>/dev/null || true
    log "signalled main dnsmasq reload via /run/dnsmasq-main.pid"
  else
    pkill -f 'dnsmasq-main' 2>/dev/null || pkill dnsmasq 2>/dev/null || true
    log "signalled dnsmasq reload (no main pid file)"
  fi
}

mkdir -p /data/home-ddns
touch "${LOG}"
chmod 600 "${LOG}" 2>/dev/null || true

if [[ ! -x "${HOOK}" ]]; then
  log "error: missing executable hook at ${HOOK}"
  exit 1
fi

if [[ ! -r "${ENV_FILE}" ]]; then
  log "error: missing env file ${ENV_FILE} (copy home-ddns.env.example and set secrets)"
  exit 1
fi

# Install or refresh wrapper (install-home-ddns.sh also copies this).
if [[ -f "${WRAPPER}.repo" ]]; then
  install -m 0755 "${WRAPPER}.repo" "${WRAPPER}"
elif [[ ! -x "${WRAPPER}" ]]; then
  cat >"${WRAPPER}" <<'EOF'
#!/bin/sh
if [ -x /usr/bin/dnsmasq-dhcp-script ]; then
  /usr/bin/dnsmasq-dhcp-script "$@" "domain=${DNSMASQ_DOMAIN:-}" || true
fi
export DDNS_ENV_FILE="/data/home-ddns/home-ddns.env"
exec /data/home-ddns/dhcp-ddns-hook.sh "$@"
EOF
  chmod 755 "${WRAPPER}"
fi

CONF_DIR=""
for candidate in /run/dnsmasq.dhcp.conf.d /run/dnsmasq.conf.d; do
  if [[ -d "${candidate}" ]]; then
    CONF_DIR="${candidate}"
    break
  fi
done

if [[ -z "${CONF_DIR}" ]]; then
  log "error: no dnsmasq runtime conf.d directory found under /run/"
  exit 1
fi

SHARED="${CONF_DIR}/shared.conf"
for _ in $(seq 1 60); do
  if [[ -f "${SHARED}" ]]; then
    break
  fi
  sleep 2
done

if [[ ! -f "${SHARED}" ]]; then
  log "error: ${SHARED} not found after wait"
  exit 1
fi

# Remove legacy inject that duplicated dhcp-script= (causes "illegal repeated keyword").
LEGACY_INJECT="${CONF_DIR}/${LEGACY_INJECT_NAME}"
if [[ -f "${LEGACY_INJECT}" ]]; then
  rm -f "${LEGACY_INJECT}"
  log "removed legacy ${LEGACY_INJECT} (duplicate dhcp-script)"
fi

# Backup original UniFi dhcp-script line once (for rollback).
if [[ ! -f "${BACKUP_LINE}" ]]; then
  grep -E '^[[:space:]]*#?[[:space:]]*dhcp-script=' "${SHARED}" >"${BACKUP_LINE}" 2>/dev/null || true
  touch "${BACKUP_LINE}"
  chmod 600 "${BACKUP_LINE}"
fi

WRAPPER_LINE="dhcp-script=${WRAPPER}"
CHANGED=0

if grep -qE '^[[:space:]]*#?[[:space:]]*dhcp-script=' "${SHARED}"; then
  if ! grep -qxF "${WRAPPER_LINE}" "${SHARED}"; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*dhcp-script=.*|${WRAPPER_LINE}|" "${SHARED}"
    log "patched ${SHARED} → ${WRAPPER_LINE}"
    CHANGED=1
  else
    log "ok: ${SHARED} already points at wrapper"
  fi
else
  printf '%s\n' "${WRAPPER_LINE}" >>"${SHARED}"
  log "appended ${WRAPPER_LINE} to ${SHARED}"
  CHANGED=1
fi

ACTIVE_COUNT="$(grep -hE '^[^#]*dhcp-script=' "${CONF_DIR}"/*.conf 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${ACTIVE_COUNT}" != "1" ]]; then
  log "error: expected 1 active dhcp-script= in ${CONF_DIR}, found ${ACTIVE_COUNT}"
  grep -hE '^[^#]*dhcp-script=' "${CONF_DIR}"/*.conf 2>/dev/null | tee -a "${LOG}" || true
  exit 1
fi

if [[ "${CHANGED}" -eq 1 ]]; then
  reload_main_dnsmasq
else
  log "no reload needed"
fi
