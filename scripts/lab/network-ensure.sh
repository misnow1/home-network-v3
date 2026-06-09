#!/usr/bin/env bash
# Define, reconfigure if needed, start, and autostart the lab libvirt network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

NET_NAME="${LAB_NET_NAME:-home-dc-lab}"
NET_XML_TMPL="${ROOT}/scripts/lab/libvirt/lab-network.xml.tmpl"
NET_XML="${ROOT}/.lab/lab-network.xml"
LAB_DDNS_HOOK="${ROOT}/scripts/lab/dhcp-ddns-hook-lab.sh"
EXPECTED_GATEWAY="192.168.100.1"
START_RETRY_SECS="${LAB_NET_START_RETRY_SECS:-3}"

render_network_xml() {
  require_cmd envsubst
  mkdir -p "${ROOT}/.lab"
  export LAB_DDNS_HOOK
  envsubst < "${NET_XML_TMPL}" > "${NET_XML}"
}

network_is_defined() {
  virsh net-info "${NET_NAME}" >/dev/null 2>&1
}

network_active_state() {
  virsh net-info "${NET_NAME}" 2>/dev/null \
    | awk '/^Active:/ { print $NF }'
}

network_is_active() {
  [[ "$(network_active_state)" == "yes" ]]
}

network_gateway() {
  virsh net-dumpxml "${NET_NAME}" 2>/dev/null \
    | sed -n "s/.*<ip address=['\"]\\([^'\"]*\\)['\"].*/\\1/p" \
    | head -1
}

network_has_dhcp_script() {
  local expected="${1:-}"
  virsh net-dumpxml "${NET_NAME}" 2>/dev/null | grep -Fq "dhcp-script=${expected}"
}

expected_dhcp_script() {
  printf '%s' "${LAB_DDNS_HOOK}"
}

undefine_network() {
  log_info "Removing libvirt network ${NET_NAME}"
  virsh net-destroy "${NET_NAME}" 2>/dev/null || true
  virsh net-undefine "${NET_NAME}" 2>/dev/null || true
}

define_network() {
  render_network_xml
  virsh net-define "${NET_XML}"
  log_info "Defined libvirt network ${NET_NAME} from ${NET_XML_TMPL}"
}

ensure_network_started() {
  if network_is_active; then
    log_info "Libvirt network ${NET_NAME} is already active"
    return 0
  fi

  log_info "Starting libvirt network ${NET_NAME} (currently: $(network_active_state))"
  local start_err
  if start_err="$(virsh net-start "${NET_NAME}" 2>&1)"; then
    return 0
  fi

  if grep -qi 'already active' <<< "${start_err}"; then
    log_info "Libvirt reports ${NET_NAME} is already active"
    return 0
  fi

  if grep -qi 'already in use' <<< "${start_err}"; then
    log_warn "Bridge conflict; retrying after net-destroy"
    virsh net-destroy "${NET_NAME}" 2>/dev/null || true
    sleep "${START_RETRY_SECS}"
    start_err="$(virsh net-start "${NET_NAME}" 2>&1)" || die "Failed to start ${NET_NAME}: ${start_err}"
    return 0
  fi

  if grep -qi 'Operation not permitted' <<< "${start_err}"; then
    die "Cannot create bridge for ${NET_NAME} (permission denied). Run on kvm01 as a user in the libvirt group, or check virtnetworkd."
  fi

  die "Failed to start ${NET_NAME}: ${start_err}"
}

main() {
  require_cmd virsh
  [[ -f "${NET_XML_TMPL}" ]] || die "Missing network template: ${NET_XML_TMPL}"
  [[ -x "${LAB_DDNS_HOOK}" ]] || chmod +x "${LAB_DDNS_HOOK}"

  render_network_xml

  if network_is_defined; then
    local current_gateway expected_script
    current_gateway="$(network_gateway || true)"
    expected_script="$(expected_dhcp_script || true)"
    if [[ "${current_gateway}" != "${EXPECTED_GATEWAY}" ]]; then
      log_warn "Network ${NET_NAME} gateway is ${current_gateway:-unknown}; redefining for lab.test"
      undefine_network
    elif [[ -n "${expected_script}" ]] && ! network_has_dhcp_script "${expected_script}"; then
      log_warn "Network ${NET_NAME} missing dhcp-script=${expected_script}; redefining"
      undefine_network
    else
      log_info "Libvirt network ${NET_NAME} already defined (gateway ${current_gateway})"
    fi
  fi

  if ! network_is_defined; then
    define_network
  fi

  ensure_network_started
  virsh net-autostart "${NET_NAME}"

  network_is_active || die "Libvirt network ${NET_NAME} is not active (state: $(network_active_state || echo unknown))"
  [[ "$(network_gateway || true)" == "${EXPECTED_GATEWAY}" ]] \
    || die "Network ${NET_NAME} gateway is $(network_gateway || echo unknown), expected ${EXPECTED_GATEWAY}"

  virsh net-info "${NET_NAME}"
}

main "$@"
