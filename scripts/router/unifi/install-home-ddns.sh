#!/usr/bin/env bash
# One-time installer for DDNS hook files on a UniFi gateway (run as root via SSH).
# Expects dhcp-ddns-hook.sh and home-ddns.env.example in /tmp/ (see docs/unifi-gateway-dns.md).
set -euo pipefail

DEST="/data/home-ddns"
BOOT_DIR="/data/on_boot.d"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root on the gateway." >&2
  exit 1
fi

mkdir -p "${DEST}" "${BOOT_DIR}"

if [[ -f /tmp/dhcp-ddns-hook.sh ]]; then
  install -m 0755 /tmp/dhcp-ddns-hook.sh "${DEST}/dhcp-ddns-hook.sh"
else
  echo "Missing /tmp/dhcp-ddns-hook.sh — scp from repo scripts/dhcp-ddns-hook.sh first." >&2
  exit 1
fi

if [[ -f /tmp/dhcp-script-wrapper.sh ]]; then
  install -m 0755 /tmp/dhcp-script-wrapper.sh "${DEST}/dhcp-script-wrapper.sh"
elif [[ -f "${DEST}/dhcp-script-wrapper.sh" ]]; then
  :
else
  echo "Warning: dhcp-script-wrapper.sh not in /tmp — 20-home-ddns.sh will create it on boot." >&2
fi

if [[ -f /tmp/home-ddns.env.example ]]; then
  install -m 0600 /tmp/home-ddns.env.example "${DEST}/home-ddns.env.example"
fi

if [[ ! -f "${DEST}/home-ddns.env" ]]; then
  if [[ -f "${DEST}/home-ddns.env.example" ]]; then
    cp -a "${DEST}/home-ddns.env.example" "${DEST}/home-ddns.env"
    echo "Created ${DEST}/home-ddns.env — edit DDNS_BEARER_TOKEN before cutover."
  else
    echo "Warning: no env file; create ${DEST}/home-ddns.env manually." >&2
  fi
fi

chmod 600 "${DEST}/home-ddns.env" 2>/dev/null || true

echo "Installed:"
ls -la "${DEST}/"
