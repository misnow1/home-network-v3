# shellcheck shell=bash
# dhcp-ddns-parse.sh — parse dnsmasq dhcp-script argv into IP, hostname, client_id.
# Sourced by dhcp-ddns-hook.sh and test-dhcp-ddns-hook-parse.sh (not executed directly).

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
  python3 -c 'import ipaddress, sys; ipaddress.IPv6Address(sys.argv[1])' "$1" 2>/dev/null
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
