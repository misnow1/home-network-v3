#!/usr/bin/env bash
# dhcp-ddns-hook.sh — dnsmasq dhcp-script: notify DC DDNS API on lease add/old/del (IPv4 + IPv6).
#
# Install on the dnsmasq host (router / libvirt hypervisor). Configure dnsmasq:
#   dhcp-script=/usr/local/sbin/dhcp-ddns-hook.sh
#
# Configuration (root-only, e.g. /etc/home-ddns.env — not world-readable):
#   DDNS_UPDATE_URL          Primary HTTPS URL (e.g. https://dc2.home.example.com/ddns/v1/lease)
#   DDNS_UPDATE_URL_FALLBACK Optional second URL (e.g. replica DC), tried if primary fails
#   DDNS_BEARER_TOKEN        Shared secret (Authorization: Bearer …)
#   DDNS_CURL_EXTRA_ARGS     Optional extra curl args (quoted string), e.g. '--resolve dc2.example.com:443:192.168.1.23'
#   DDNS_ENV_FILE            Override path to env file (default /etc/home-ddns.env)
#
# dnsmasq argv (verify on your build — use a logging wrapper first):
#   IPv4 typical: add|old|del <mac> <ipv4> <hostname> [<client_id> ...]
#   IPv6 typical: add|old|del <duid> <iaid> <ipv6> <hostname> [<client_id> ...]
#   Some builds use IPv6 order: add|old|del <mac> <ipv6> <hostname>
#
# Requires: curl; for JSON body one of: python3, jq (or python3 is used from curl host for escaping).
#
set -euo pipefail

umask 077

log() {
  if command -v logger >/dev/null 2>&1; then
    logger -t dhcp-ddns-hook "$@"
  fi
  # Also append when LOG_FILE is set (e.g. DDNS_LOG_FILE=/var/log/home-ddns-hook.log in env file)
  if [[ -n "${DDNS_LOG_FILE:-}" && -w "$(dirname "${DDNS_LOG_FILE}")" ]]; then
    echo "$(date -Iseconds) $*" >>"${DDNS_LOG_FILE}" 2>/dev/null || true
  fi
  echo "$(date -Iseconds) $*"
}

die() {
  log "error: $*"
  exit 0
}

ENV_FILE="${DDNS_ENV_FILE:-}"
if [[ -z "${ENV_FILE}" ]]; then
  for candidate in /data/home-ddns/home-ddns.env /etc/home-ddns.env; do
    if [[ -f "${candidate}" ]]; then
      ENV_FILE="${candidate}"
      break
    fi
  done
fi
ENV_FILE="${ENV_FILE:-/etc/home-ddns.env}"
if [[ -f "$ENV_FILE" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set -u
fi

: "${DDNS_UPDATE_URL:?Set DDNS_UPDATE_URL in ${ENV_FILE}}"
: "${DDNS_BEARER_TOKEN:?Set DDNS_BEARER_TOKEN in ${ENV_FILE}}"

CURL=(curl -sS --connect-timeout 3 --max-time 15 -H "Content-Type: application/json")

if [[ -n "${DDNS_CURL_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  CURL+=(${DDNS_CURL_EXTRA_ARGS})
fi

ACTION="${1:-}"
shift || true

if [[ -z "$ACTION" ]]; then
  die "missing dnsmasq action"
fi

case "$ACTION" in
add | old | del) ;;
*)
  die "unknown action: $ACTION"
  ;;
esac

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  [[ "$1" == *:* ]]
}

# Pick client address and hostname from remaining argv (flexible ordering).
pick_lease_fields() {
  local -a tok
  tok=("$@")
  local ip=""
  local hn=""
  local cid=""
  local i t
  for t in "${tok[@]}"; do
    if is_ipv4 "$t"; then
      ip="$t"
      break
    fi
  done
  if [[ -z "$ip" ]]; then
    for t in "${tok[@]}"; do
      if is_ipv6 "$t"; then
        ip="$t"
        break
      fi
    done
  fi
  # Hostname: last non-IP, non-MAC-looking token often is hostname; prefer first label-like token after IP
  for ((i = ${#tok[@]} - 1; i >= 0; i--)); do
    t="${tok[i]}"
    if [[ "$t" == "*" ]]; then
      continue
    fi
    if is_ipv4 "$t" || is_ipv6 "$t"; then
      continue
    fi
    if [[ "$t" =~ ^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$ ]]; then
      cid="${cid:-$t}"
      continue
    fi
    # IAID often numeric-only; DUID hex/colon — if token is *only* hex and very long, treat as id
    if [[ "$t" =~ ^[0-9a-fA-F:*.-]+$ && ${#t} -gt 24 ]]; then
      cid="${cid:-$t}"
      continue
    fi
    if [[ "$t" =~ ^[0-9]+$ && ${#t} -le 12 ]]; then
      continue
    fi
    hn="$t"
    break
  done
  # client_id: MAC if we saw Ethernet MAC pattern in tokens
  for t in "${tok[@]}"; do
    if [[ "$t" =~ ^([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}$ ]]; then
      cid="$t"
      break
    fi
  done
  if [[ -z "$cid" && ${#tok[@]} -ge 1 ]]; then
    cid="${tok[0]}"
  fi
  printf '%s\n%s\n%s\n' "$ip" "$hn" "$cid"
}

readarray -t _picked < <(pick_lease_fields "$@")
IP="${_picked[0]:-}"
HOSTNAME_RAW="${_picked[1]:-}"
CLIENT_ID="${_picked[2]:-}"

api_action="upsert"
if [[ "$ACTION" == "del" ]]; then
  api_action="delete"
fi

if [[ -z "$IP" ]]; then
  log "skip: no IP in argv for action=$ACTION args=$*"
  exit 0
fi

# delete with no client hostname: API can still remove PTR and infer forward name from PTR (IPv4).
if [[ -z "$HOSTNAME_RAW" || "$HOSTNAME_RAW" == "*" ]]; then
  if [[ "$ACTION" == "del" ]]; then
    HOSTNAME=""
  else
    log "skip: empty hostname action=$ACTION ip=$IP"
    exit 0
  fi
else
  # Single DNS label: strip domain suffix if present
  : "${DDNS_DNS_DOMAIN:?Set DDNS_DNS_DOMAIN in ${ENV_FILE}}"
  HOSTNAME="$HOSTNAME_RAW"
  _dns_suffix_dot=".${DDNS_DNS_DOMAIN}"
  if [[ "$HOSTNAME" == *"$_dns_suffix_dot" ]]; then
    HOSTNAME="${HOSTNAME%"$_dns_suffix_dot"}"
  fi
  if [[ "$HOSTNAME" == *.* ]]; then
    HOSTNAME="${HOSTNAME%%.*}"
  fi

  if ! [[ "$HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
    log "skip: invalid hostname label host=$HOSTNAME"
    exit 0
  fi
fi

json_payload() {
  local act="$1" addr="$2" host="$3" cid="$4"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json,sys
act,addr,host,cid = sys.argv[1:5]
print(json.dumps({"action":act,"address":addr,"hostname":host,"client_id":cid}))
' "$act" "$addr" "$host" "$cid"
  elif command -v jq >/dev/null 2>&1; then
    jq -cn --arg act "$act" --arg addr "$addr" --arg host "$host" --arg cid "$cid" \
      '{action:$act,address:$addr,hostname:$host,client_id:$cid}'
  else
    log "error: need python3 or jq for JSON encoding"
    exit 0
  fi
}

PAYLOAD="$(json_payload "$api_action" "$IP" "$HOSTNAME" "$CLIENT_ID")"

post_url() {
  local url="$1"
  "${CURL[@]}" \
    -H "Authorization: Bearer ${DDNS_BEARER_TOKEN}" \
    -d "$PAYLOAD" \
    -o /dev/null \
    -w "%{http_code}" \
    "$url"
}

code="$(post_url "$DDNS_UPDATE_URL" || true)"
if [[ "$code" =~ ^2 ]]; then
  log "ok $ACTION host=$HOSTNAME ip=$IP http=$code"
  exit 0
fi

log "warn primary failed host=$HOSTNAME ip=$IP http=$code url=$DDNS_UPDATE_URL"

if [[ -n "${DDNS_UPDATE_URL_FALLBACK:-}" ]]; then
  code_fb="$(post_url "$DDNS_UPDATE_URL_FALLBACK" || true)"
  if [[ "$code_fb" =~ ^2 ]]; then
    log "ok $ACTION fallback host=$HOSTNAME ip=$IP http=$code_fb"
    exit 0
  fi
  log "warn fallback failed host=$HOSTNAME ip=$IP http=$code_fb"
fi

exit 0
