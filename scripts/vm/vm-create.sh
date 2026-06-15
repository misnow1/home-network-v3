#!/usr/bin/env bash
# Create a VM from the Ubuntu 24.04 cloud image with cloud-init.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

PROFILE="lab"
VM_NIC="${VM_NIC:-enp1s0}"
NET_NAME="${VM_NET_NAME:-home-dc-lab}"
MEMORY_MB="${VM_MEMORY_MB:-3072}"
VCPUS="${VM_VCPUS:-2}"

VM_NAME=""
HOSTNAME=""
FQDN=""
VM_IP=""
BRIDGE=""
DISK_GB=""
USE_DHCP=0
NESTED_VIRT=0
NETWORK_EXPLICIT=0
INVENTORY_FQDN=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [-i PROFILE] <inventory-fqdn>     Inventory mode (positional FQDN)
  $(basename "$0") [-i PROFILE] --name NAME [OPTIONS]  Ad-hoc mode (no positional FQDN)

Inventory mode reads vm_name, vm_ip, vm_network, etc. from inventories/<PROFILE>.
Ad-hoc mode builds the VM from flags; use --fqdn, --ip, or --dhcp as needed.

Options:
  -i, --inventory PROFILE Inventory profile (default: lab)
  --name NAME       libvirt domain name (required in ad-hoc mode)
  --hostname NAME   cloud-init hostname (ad-hoc; default: --name)
  --fqdn FQDN       cloud-init FQDN (ad-hoc only — not used in inventory mode)
  --ip ADDR         Static cloud-init IP (ad-hoc; uses profile network defaults)
  --memory MB       RAM in MB (default: 3072)
  --vcpus N         vCPU count (default: 2)
  --disk-gb N       qcow2 overlay size in GB
  --bridge NAME     Attach to host Linux bridge (implies DHCP cloud-init)
  --network NAME    libvirt network (default: home-dc-lab for ad-hoc)
  --dhcp            DHCP cloud-init on libvirt network
  --nested-virt     Enable host-passthrough CPU
  -h, --help        Show this help

Examples:
  $(basename "$0") -i lab dc01.lab.test
  $(basename "$0") -i production dc1.home.2123studios.com --disk-gb 20
  $(basename "$0") -i production --name dc1 --fqdn dc1.home.2123studios.com --ip 192.168.1.10 --network external-default
  $(basename "$0") --name cka-cp1 --network vlan3 --dhcp --memory 4096 --vcpus 2 --disk-gb 20
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
      --hostname)
        HOSTNAME="$2"
        shift 2
        ;;
      --fqdn)
        FQDN="$2"
        shift 2
        ;;
      --ip)
        VM_IP="$2"
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

  if [[ -n "${VM_IP}" && "${USE_DHCP}" -eq 1 ]]; then
    die "--ip and --dhcp are mutually exclusive"
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
    elif [[ -n "${VM_IP}" ]]; then
      die "Ad-hoc static IP requires --fqdn"
    elif vm_inventory_host_known "${PROFILE}" "${HOSTNAME}"; then
      FQDN="${HOSTNAME}"
    else
      die "Ad-hoc mode requires --fqdn, --dhcp, --bridge, or --ip"
    fi
  fi
}

resolve_adhoc_cloud_init() {
  ADHOC_CLOUD_MODE=""
  ADHOC_VM_IP=""

  if [[ -n "${BRIDGE}" ]] || [[ "${USE_DHCP}" -eq 1 ]]; then
    ADHOC_CLOUD_MODE=dhcp
    return 0
  fi

  if [[ -n "${VM_IP}" ]]; then
    load_adhoc_network_exports "${PROFILE}" "${FQDN}"
    ADHOC_CLOUD_MODE=static
    ADHOC_VM_IP="${VM_IP}"
    return 0
  fi

  if vm_inventory_host_known "${PROFILE}" "${FQDN}"; then
    if vm_host_uses_dhcp "${PROFILE}" "${FQDN}"; then
      ADHOC_CLOUD_MODE=dhcp
      return 0
    fi
    load_inventory_network_exports "${PROFILE}" "${FQDN}"
    ADHOC_CLOUD_MODE=static
    ADHOC_VM_IP="$(vm_inventory_lookup "${PROFILE}" "${FQDN}" "vm_ip")"
    return 0
  fi

  die "Ad-hoc mode requires --dhcp, --bridge, --ip, or inventory FQDN with vm_ip (try: -i ${PROFILE} ${FQDN})"
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

  vm_ensure_network_for_profile "${PROFILE}" "${net_name}" "${bridge}"

  "${ROOT}/scripts/vm/keys-ensure.sh" -i "${PROFILE}" >/dev/null
  "${ROOT}/scripts/vm/dirs-ensure.sh" -i "${PROFILE}" >/dev/null
  "${ROOT}/scripts/vm/image-ensure.sh" >/dev/null

  local base_image disk_path seed_iso
  base_image="$(vm_cloud_image_path)"
  disk_path="$(vm_vms_dir "${PROFILE}")/${vm_name}.qcow2"

  if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    die "VM ${vm_name} already exists — run vm-destroy.sh first"
  fi

  vm_create_disk "${PROFILE}" "${disk_path}" "${base_image}" "${disk_gb}"

  if [[ "${cloud_init_mode}" == "dhcp" ]]; then
    if [[ -n "${bridge}" ]] || [[ "${net_name}" != "home-dc-lab" ]]; then
      if [[ -z "${VM_DNS_SEARCH:-}" ]]; then
        export VM_DNS_SEARCH=""
      fi
    else
      export VM_DNS_SEARCH="${VM_DNS_SEARCH:-lab.test}"
    fi
    seed_iso="$(vm_render_cloud_init "${PROFILE}" dhcp "${fqdn}" "${vm_name}")"
  else
    seed_iso="$(vm_render_cloud_init "${PROFILE}" static "${fqdn}" "${vm_name}" "${vm_ip}")"
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

    local vm_name vm_ip host_memory host_disk_gb nested_virt_flag=0 cloud_mode net_name
    vm_name="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_name")"
    net_name="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_network")"
    load_inventory_network_exports "${PROFILE}" "${INVENTORY_FQDN}"

    if vm_host_uses_dhcp "${PROFILE}" "${INVENTORY_FQDN}"; then
      cloud_mode=dhcp
      vm_ip=""
    else
      cloud_mode=static
      vm_ip="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_ip")"
    fi

    host_memory="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_memory_mb")"
    if [[ -n "${host_memory}" ]]; then
      MEMORY_MB="${host_memory}"
    fi
    host_disk_gb="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_disk_gb")"
    if [[ -n "${DISK_GB}" ]]; then
      host_disk_gb="${DISK_GB}"
    fi
    nested_virt="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_nested_virt")"
    if [[ "${nested_virt,,}" == "true" ]]; then
      nested_virt_flag=1
    fi
    if [[ "${NESTED_VIRT}" -eq 1 ]]; then
      nested_virt_flag=1
    fi

    create_vm "${vm_name}" "${INVENTORY_FQDN}" "${vm_ip}" "${cloud_mode}" "" "${net_name}" \
      "${MEMORY_MB}" "${VCPUS}" "${host_disk_gb}" "${nested_virt_flag}"
    return 0
  fi

  resolve_adhoc_config
  resolve_adhoc_cloud_init
  create_vm "${VM_NAME}" "${FQDN}" "${ADHOC_VM_IP}" "${ADHOC_CLOUD_MODE}" "${BRIDGE}" "${NET_NAME}" \
    "${MEMORY_MB}" "${VCPUS}" "${DISK_GB}" "${NESTED_VIRT}"
}

main "$@"
