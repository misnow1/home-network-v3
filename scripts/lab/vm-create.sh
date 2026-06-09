#!/usr/bin/env bash
# Create a lab VM from the Ubuntu 24.04 cloud image with cloud-init.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/lab/vm-lib.sh"

LAB_NIC="${LAB_NIC:-enp1s0}"
NET_NAME="${LAB_NET_NAME:-home-dc-lab}"
MEMORY_MB="${LAB_VM_MEMORY_MB:-3072}"
VCPUS="${LAB_VM_VCPUS:-2}"

VM_NAME=""
HOSTNAME=""
FQDN=""
BRIDGE=""
DISK_GB=""
USE_DHCP=0
NESTED_VIRT=0
NETWORK_EXPLICIT=0
INVENTORY_FQDN=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <fqdn>                    Inventory mode (static IP, home-dc-lab)
  $(basename "$0") [OPTIONS]                 Ad-hoc mode

Options:
  --name NAME       libvirt domain name (required without FQDN)
  --hostname NAME   cloud-init hostname (default: --name)
  --fqdn FQDN       cloud-init FQDN (default: derived from hostname)
  --memory MB       RAM in MB (default: 3072)
  --vcpus N         vCPU count (default: 2)
  --disk-gb N       qcow2 overlay size in GB
  --bridge NAME     Attach to host Linux bridge (implies DHCP cloud-init)
  --network NAME    libvirt network (default: home-dc-lab)
  --dhcp            DHCP cloud-init on libvirt network
  --nested-virt     Enable host-passthrough CPU
  -h, --help        Show this help

Examples:
  $(basename "$0") dc01.lab.test
  $(basename "$0") --name cka-cp1 --network vlan3 --dhcp --memory 4096 --vcpus 2 --disk-gb 20
  $(basename "$0") --name cka-cp1 --bridge vlan3 --memory 4096 --vcpus 2 --disk-gb 20
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        VM_NAME="$2"
        shift 2
        ;;
      --hostname)
        HOSTNAME="$2"
        shift 2
        ;;
      --fqdn)
        FQDN="$2"
        shift 2
        ;;
      --memory)
        MEMORY_MB="$2"
        shift 2
        ;;
      --vcpus)
        VCPUS="$2"
        shift 2
        ;;
      --disk-gb)
        DISK_GB="$2"
        shift 2
        ;;
      --bridge)
        BRIDGE="$2"
        USE_DHCP=1
        shift 2
        ;;
      --network)
        NET_NAME="$2"
        NETWORK_EXPLICIT=1
        shift 2
        ;;
      --dhcp)
        USE_DHCP=1
        shift
        ;;
      --nested-virt)
        NESTED_VIRT=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
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

resolve_adhoc_config() {
  [[ -n "${VM_NAME}" ]] || die "Ad-hoc mode requires --name"

  if [[ -n "${BRIDGE}" && "${NETWORK_EXPLICIT}" -eq 1 ]]; then
    die "--bridge and --network are mutually exclusive"
  fi

  HOSTNAME="${HOSTNAME:-${VM_NAME}}"
  if [[ -z "${FQDN}" ]]; then
    if [[ -n "${BRIDGE}" ]]; then
      FQDN="${HOSTNAME}"
    elif [[ "${USE_DHCP}" -eq 1 ]]; then
      if [[ "${HOSTNAME}" == *.* ]]; then
        FQDN="${HOSTNAME}"
      elif [[ "${NET_NAME}" == "home-dc-lab" ]]; then
        FQDN="${HOSTNAME}.lab.test"
      else
        FQDN="${HOSTNAME}"
      fi
    else
      die "Ad-hoc mode without --bridge requires --dhcp or inventory FQDN"
    fi
  fi
}

create_vm() {
  local vm_name="$1"
  local fqdn="$2"
  local vm_ip="$3"
  local cloud_init_mode="$4"
  local bridge="$5"
  local net_name="$6"
  local memory_mb="$7"
  local vcpus="$8"
  local disk_gb="$9"
  local nested_virt="${10}"

  require_cmd virsh
  require_cmd virt-install
  require_cmd qemu-img
  require_cmd envsubst

  if [[ -n "${bridge}" ]]; then
    vm_validate_bridge "${bridge}"
  elif [[ "${net_name}" == "home-dc-lab" ]]; then
    "${ROOT}/scripts/lab/network-ensure.sh" >/dev/null
  else
    vm_ensure_libvirt_network "${net_name}"
  fi

  "${ROOT}/scripts/lab/keys-ensure.sh" >/dev/null
  "${ROOT}/scripts/lab/dirs-ensure.sh" >/dev/null
  "${ROOT}/scripts/lab/image-ensure.sh" >/dev/null

  local base_image disk_path seed_iso
  base_image="$(lab_cloud_image_path)"
  disk_path="$(lab_vms_dir)/${vm_name}.qcow2"

  if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    die "VM ${vm_name} already exists — run vm-destroy.sh first"
  fi

  vm_create_disk "${disk_path}" "${base_image}" "${disk_gb}"

  if [[ "${cloud_init_mode}" == "dhcp" ]]; then
    if [[ -n "${bridge}" ]] || [[ "${net_name}" != "home-dc-lab" ]]; then
      export LAB_DNS_SEARCH=""
    else
      export LAB_DNS_SEARCH="lab.test"
    fi
    seed_iso="$(vm_render_cloud_init dhcp "${fqdn}" "${vm_name}")"
  else
    seed_iso="$(vm_render_cloud_init static "${fqdn}" "${vm_name}" "${vm_ip}")"
  fi
  chmod 644 "${seed_iso}" 2>/dev/null || true

  local network_arg
  network_arg="$(vm_build_network_arg "${bridge}" "${net_name}")"

  local virt_args=(
    --connect "${LIBVIRT_DEFAULT_URI:-qemu:///system}"
    --name "${vm_name}"
    --memory "${memory_mb}"
    --vcpus "${vcpus}"
    --disk "path=${disk_path},format=qcow2,bus=virtio"
    --disk "path=${seed_iso},device=cdrom"
    --os-variant ubuntu24.04
    --network "${network_arg}"
    --graphics none
    --console pty,target.type=serial
    --import
    --noautoconsole
  )

  if [[ "${nested_virt}" -eq 1 ]]; then
    virt_args+=(--cpu host-passthrough)
  fi

  if [[ "${cloud_init_mode}" == "dhcp" ]]; then
    log_info "Creating VM ${vm_name} (${fqdn}, DHCP)"
  else
    log_info "Creating VM ${vm_name} (${fqdn} @ ${vm_ip})"
  fi
  virt-install "${virt_args[@]}"
  log_info "VM ${vm_name} created"
}

main() {
  parse_args "$@"

  if [[ -n "${INVENTORY_FQDN}" ]]; then
    [[ -z "${VM_NAME}" ]] || die "Cannot combine inventory FQDN with --name"
    [[ -z "${BRIDGE}" ]] || die "Cannot combine inventory FQDN with --bridge"
    [[ "${USE_DHCP}" -eq 0 ]] || die "Cannot combine inventory FQDN with --dhcp"
    [[ "${NETWORK_EXPLICIT}" -eq 0 ]] || die "Cannot combine inventory FQDN with --network"

    local vm_name vm_ip host_memory host_disk_gb nested_virt_flag=0
    vm_name="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_vm_name")"
    vm_ip="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_vm_ip")"
    host_memory="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_vm_memory_mb" 2>/dev/null || true)"
    if [[ -n "${host_memory}" ]]; then
      MEMORY_MB="${host_memory}"
    fi
    host_disk_gb="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_vm_disk_gb" 2>/dev/null || true)"
    if [[ -n "${DISK_GB}" ]]; then
      host_disk_gb="${DISK_GB}"
    fi
    nested_virt="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${INVENTORY_FQDN}" "lab_nested_virt" 2>/dev/null || true)"
    if [[ "${nested_virt,,}" == "true" ]]; then
      nested_virt_flag=1
    fi
    if [[ "${NESTED_VIRT}" -eq 1 ]]; then
      nested_virt_flag=1
    fi

    create_vm "${vm_name}" "${INVENTORY_FQDN}" "${vm_ip}" static "" "${NET_NAME}" \
      "${MEMORY_MB}" "${VCPUS}" "${host_disk_gb}" "${nested_virt_flag}"
    return 0
  fi

  resolve_adhoc_config
  create_vm "${VM_NAME}" "${FQDN}" "" dhcp "${BRIDGE}" "${NET_NAME}" \
    "${MEMORY_MB}" "${VCPUS}" "${DISK_GB}" "${NESTED_VIRT}"
}

main "$@"
