#!/usr/bin/env bash
# Wait until cloud-init finishes and SSH accepts connections for the ansible user.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

PROFILE="lab"
SSH_USER="${VM_SSH_USER:-ansible}"
TIMEOUT_SECS="${VM_SSH_TIMEOUT_SECS:-600}"
SLEEP_SECS="${VM_SSH_POLL_SECS:-10}"
IP_DISCOVERY_TIMEOUT_SECS="${VM_IP_DISCOVERY_TIMEOUT_SECS:-300}"

VM_NAME=""
VM_IP=""
INVENTORY_FQDN=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [-i PROFILE] <fqdn>                         Wait using inventory IP or guest agent
  $(basename "$0") [-i PROFILE] --name <vm-name> [--ip ADDR]   Wait on ad-hoc VM

Examples:
  $(basename "$0") -i lab dc01.lab.test
  $(basename "$0") --name cka-cp1
  $(basename "$0") --name cka-cp1 --ip 10.0.0.42
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      --name)
        VM_NAME="$2"
        shift 2
        ;;
      --ip)
        VM_IP="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        [[ -z "${INVENTORY_FQDN}" ]] || die "Unexpected argument: $1"
        INVENTORY_FQDN="$1"
        shift
        ;;
    esac
  done
}

wait_for_ssh() {
  local target_label="$1"
  local vm_ip="$2"
  local ssh_key
  ssh_key="$(vm_ssh_key_path "${PROFILE}")"
  local elapsed=0

  [[ -f "${ssh_key}" ]] || die "Missing SSH key ${ssh_key} — run keys-ensure.sh -i ${PROFILE}"

  while (( elapsed < TIMEOUT_SECS )); do
    if ssh -i "${ssh_key}" \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      "${SSH_USER}@${vm_ip}" 'cloud-init status --wait >/dev/null 2>&1 || true; echo ok' \
      2>/dev/null | grep -q ok; then
      log_info "SSH ready on ${target_label} (${vm_ip})"
      return 0
    fi
    log_info "Waiting for SSH on ${vm_ip} (${elapsed}s / ${TIMEOUT_SECS}s)"
    sleep "${SLEEP_SECS}"
    elapsed=$((elapsed + SLEEP_SECS))
  done

  die "Timed out waiting for SSH on ${target_label} (${vm_ip})"
}

report_guest_ips() {
  local vm_name="$1"
  local ips
  ips="$(vm_discover_ips "${vm_name}" || true)"
  if [[ -n "${ips}" ]]; then
    log_info "Guest-agent addresses for ${vm_name}:"
    while IFS= read -r ip; do
      log_info "  ${ip}"
    done <<< "${ips}"
  else
    log_warn "No guest-agent addresses reported for ${vm_name}"
  fi
}

main() {
  parse_args "$@"

  if [[ -n "${INVENTORY_FQDN}" && -n "${VM_NAME}" ]]; then
    die "Use either --name or an inventory FQDN, not both"
  fi

  if [[ -z "${INVENTORY_FQDN}" && -z "${VM_NAME}" ]]; then
    usage
    exit 1
  fi

  require_cmd ssh

  if [[ -n "${INVENTORY_FQDN}" ]]; then
    VM_NAME="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_name")"
    if vm_host_uses_dhcp "${PROFILE}" "${INVENTORY_FQDN}"; then
      require_cmd virsh
      VM_IP="$(vm_wait_for_ip "${VM_NAME}" "${IP_DISCOVERY_TIMEOUT_SECS}" "${SLEEP_SECS}")"
      log_info "Discovered ${VM_NAME} at ${VM_IP}"
    else
      VM_IP="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "ansible_host")"
    fi
    wait_for_ssh "${INVENTORY_FQDN}" "${VM_IP}"
    require_cmd virsh
    report_guest_ips "${VM_NAME}"
    return 0
  fi

  if [[ -z "${VM_IP}" ]]; then
    require_cmd virsh
    VM_IP="$(vm_wait_for_ip "${VM_NAME}" "${IP_DISCOVERY_TIMEOUT_SECS}" "${SLEEP_SECS}")"
    log_info "Discovered ${VM_NAME} at ${VM_IP}"
  fi

  wait_for_ssh "${VM_NAME}" "${VM_IP}"
  require_cmd virsh
  report_guest_ips "${VM_NAME}"
}

main "$@"
