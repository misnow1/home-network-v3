#!/bin/sh
# Chain UniFi dnsmasq-dhcp-script + home-network DDNS hook.
# Installed as /data/home-ddns/dhcp-script-wrapper.sh — referenced from shared.conf.
# See docs/unifi-gateway-dns.md

if [ -x /usr/bin/dnsmasq-dhcp-script ]; then
  /usr/bin/dnsmasq-dhcp-script "$@" "domain=${DNSMASQ_DOMAIN:-}" || true
fi

export DDNS_ENV_FILE="/data/home-ddns/home-ddns.env"
exec /data/home-ddns/dhcp-ddns-hook.sh "$@"
