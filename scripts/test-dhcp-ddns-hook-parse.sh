#!/usr/bin/env bash
# Unit tests for dhcp-ddns-parse.sh (dnsmasq argv → IP, hostname, client_id).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/dhcp-ddns-parse.sh
source "${ROOT}/scripts/lib/dhcp-ddns-parse.sh"

failures=0

assert_pick() {
  local name="$1"
  local want_ip="$2"
  local want_hn="$3"
  local want_cid="$4"
  shift 4
  local -a got
  readarray -t got < <(pick_lease_fields "$@")
  local got_ip="${got[0]:-}"
  local got_hn="${got[1]:-}"
  local got_cid="${got[2]:-}"
  if [[ "$got_ip" != "$want_ip" || "$got_hn" != "$want_hn" || "$got_cid" != "$want_cid" ]]; then
    log_error "${name}: expected ip=${want_ip} hn=${want_hn} cid=${want_cid}"
    log_error "${name}: got      ip=${got_ip} hn=${got_hn} cid=${got_cid}"
    failures=$((failures + 1))
  fi
}

require_cmd python3

log_info "dhcp-ddns-hook parse tests"

# IPv4 — production log shape
assert_pick "ipv4-basic" \
  "192.168.1.243" "u7-pro-xg" "90:41:b2:b0:6c:95" \
  "90:41:b2:b0:6c:95" "192.168.1.243" "u7-pro-xg"

# IPv6 DUID order — DUID must not be mistaken for address (homeassistant log)
assert_pick "ipv6-duid-order" \
  "2001:db8:1::5" "homeassistant" "00:04:b4:d6:6c:78:8a:5f:c6:1e:35:fd:94:6c:80:40:21:e9" \
  "00:04:b4:d6:6c:78:8a:5f:c6:1e:35:fd:94:6c:80:40:21:e9" "1234" "2001:db8:1::5" "homeassistant"

# IPv6 alt MAC order
assert_pick "ipv6-mac-order" \
  "2001:db8:1::9" "fedora38-1" "52:54:00:75:d3:73" \
  "52:54:00:75:d3:73" "2001:db8:1::9" "fedora38-1"

# bastion-el9 DUID from production logs
assert_pick "ipv6-bastion" \
  "fd00::1" "bastion-el9" "00:04:91:78:15:c9:25:77:d4:5b:92:8a:4e:76:b3:0c:69:9b" \
  "00:04:91:78:15:c9:25:77:d4:5b:92:8a:4e:76:b3:0c:69:9b" "42" "fd00::1" "bastion-el9"

# dc1 DUID from production logs
assert_pick "ipv6-dc1" \
  "2001:db8::dc1" "dc1" "00:02:00:00:ab:11:29:2c:1d:e9:ca:bf:50:4c" \
  "00:02:00:00:ab:11:29:2c:1d:e9:ca:bf:50:4c" "7" "2001:db8::dc1" "dc1"

# No IPv6 address yet — hook should skip (empty IP)
assert_pick "duid-no-v6" \
  "" "" "00:04:b4:d6:6c:78:8a:5f:c6:1e:35:fd:94:6c:80:40:21:e9" \
  "00:04:b4:d6:6c:78:8a:5f:c6:1e:35:fd:94:6c:80:40:21:e9" "1234" "*"

# DUID alone must not parse as IPv6
if is_ipv6 "00:04:b4:d6:6c:78:8a:5f:c6:1e:35:fd:94:6c:80:40:21:e9"; then
  log_error "is_ipv6 incorrectly accepted DUID"
  failures=$((failures + 1))
fi

# MAC must not parse as IPv6
if is_ipv6 "90:41:b2:b0:6c:95"; then
  log_error "is_ipv6 incorrectly accepted MAC"
  failures=$((failures + 1))
fi

if [[ "$failures" -gt 0 ]]; then
  log_error "${failures} dhcp-ddns-hook parse test(s) failed"
  exit 1
fi

log_info "dhcp-ddns-hook parse tests passed"
