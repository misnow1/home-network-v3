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
PERF_PROFILE="lab"
NETWORK_EXPLICIT=0
INVENTORY_FQDN=""
DRY_RUN=0
PREPARE=0
WAIT_RESERVATION=0
FORCE_BOOT=0
AUTOSTART=1
RESERVE_FQDN=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [-i PROFILE] <inventory-fqdn>     Inventory mode (positional FQDN)
  $(basename "$0") [-i PROFILE] --name NAME [OPTIONS]  Ad-hoc mode (no positional FQDN)

Inventory mode reads vm_name and ethernets from inventories/<PROFILE>.
Omitted ethernets creates one dual-stack DHCP NIC on the profile vm_network.
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
  --perf-profile P  VM tuning profile: lab (default), balanced, storage, windows11
  --dry-run         Build disk (+ cloud-init seed for Ubuntu); write install.sh and domain.xml
                    without defining the VM (for offline install on another hypervisor)
  --prepare         Define VM and report resolved MACs without starting
  --wait-reservation  With --prepare, pause until Enter after creating router reservation
  --force-boot      Boot immediately even for production DHCP inventory hosts
                    (required to start windows11 profiles — they define-only by default)
  --no-autostart    Do not mark the VM to start on host boot (default: autostart on)
  -h, --help        Show this help

Examples:
  $(basename "$0") -i lab dc01.lab.test
  $(basename "$0") -i production dc1.home.2123studios.com --disk-gb 20
  $(basename "$0") -i production --prepare bastion.home.2123studios.com
  $(basename "$0") -i production --prepare --wait-reservation bastion.home.2123studios.com
  $(basename "$0") -i production --prepare calculon2.home.2123studios.com
  $(basename "$0") -i production --name dc1 --fqdn dc1.home.2123studios.com --ip 192.168.1.10 --network external-default
  $(basename "$0") --name cka-cp1 --network vlan3 --dhcp --memory 4096 --vcpus 2 --disk-gb 20
  $(basename "$0") -i production --dry-run dc02.home.2123studios.com
  $(basename "$0") --name win-test --perf-profile windows11 --network external-default --dhcp --memory 8192 --vcpus 6 --disk-gb 128 --prepare
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
      --perf-profile)
        PERF_PROFILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --prepare)
        PREPARE=1
        shift
        ;;
      --wait-reservation)
        WAIT_RESERVATION=1
        shift
        ;;
      --force-boot)
        FORCE_BOOT=1
        shift
        ;;
      --no-autostart)
        AUTOSTART=0
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
  ADHOC_ETHERNETS_JSON=""

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
    ADHOC_ETHERNETS_JSON="$(vm_inventory_ethernets "${PROFILE}" "${FQDN}")"
    if vm_ethernets_use_dhcp "${ADHOC_ETHERNETS_JSON}"; then
      ADHOC_CLOUD_MODE=dhcp
      return 0
    fi
    ADHOC_CLOUD_MODE=static
    ADHOC_VM_IP="$(vm_ethernets_primary_ipv4 "${ADHOC_ETHERNETS_JSON}")"
    return 0
  fi

  die "Ad-hoc mode requires --dhcp, --bridge, --ip, or a known inventory FQDN"
}

create_vm() {
  local vm_name="$1"
  local fqdn="$2"
  local ethernets_json="$3"
  local memory_mb="$4"
  local vcpus="$5"
  local disk_gb="$6"
  local nested_virt="$7"
  local perf_profile="${8:-lab}"
  local cpu_topology="${9:-}"
  local os_variant="${10:-}"

  vm_perf_profile_validate "${perf_profile}"
  require_cmd qemu-img

  local windows_guest=0
  if vm_is_windows_profile "${perf_profile}"; then
    windows_guest=1
    [[ -n "${disk_gb}" ]] || die "windows11 profile requires --disk-gb or inventory vm_disk_gb"
  else
    require_cmd envsubst
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    require_cmd virsh
    require_cmd virt-install
    vm_ensure_ethernets_for_profile "${PROFILE}" "${ethernets_json}"
  else
    log_info "Dry-run: skipping libvirt network checks and VM define"
  fi

  if [[ "${PREPARE}" -eq 1 && "${DRY_RUN}" -eq 1 ]]; then
    die "--prepare and --dry-run are mutually exclusive"
  fi
  if [[ "${WAIT_RESERVATION}" -eq 1 && "${PREPARE}" -eq 0 ]]; then
    die "--wait-reservation requires --prepare"
  fi

  if [[ "${windows_guest}" -eq 0 ]]; then
    "${ROOT}/scripts/vm/keys-ensure.sh" -i "${PROFILE}" >/dev/null
  fi
  if [[ "${DRY_RUN}" -eq 1 || "${PREPARE}" -eq 1 || "${windows_guest}" -eq 1 ]]; then
    mkdir -p "$(vm_images_dir)" "$(vm_vms_dir "${PROFILE}")" "$(vm_seeds_dir "${PROFILE}")"
  else
    "${ROOT}/scripts/vm/dirs-ensure.sh" -i "${PROFILE}" >/dev/null
  fi

  local base_image="" disk_path seed_iso="" seed_dir domain_xml manifest resolved_ethernets
  disk_path="$(vm_vms_dir "${PROFILE}")/${vm_name}.qcow2"
  seed_dir="$(vm_seeds_dir "${PROFILE}")/${vm_name}"
  domain_xml="${seed_dir}/domain.xml"
  manifest="${seed_dir}/manifest.txt"
  mkdir -p "${seed_dir}"

  if [[ "${windows_guest}" -eq 0 ]]; then
    "${ROOT}/scripts/vm/image-ensure.sh" >/dev/null
    base_image="$(vm_cloud_image_path)"
  fi

  if [[ "${DRY_RUN}" -eq 0 ]]; then
    if virsh dominfo "${vm_name}" >/dev/null 2>&1; then
      if [[ "${PREPARE}" -eq 1 ]]; then
        local state
        state="$(virsh domstate "${vm_name}" 2>/dev/null || true)"
        if [[ "${state}" != "shut off" ]]; then
          die "VM ${vm_name} already exists and is not shut off — run vm-destroy.sh first"
        fi
        log_warn "Prepare: reusing existing defined VM ${vm_name}"
      else
        die "VM ${vm_name} already exists — run vm-destroy.sh first"
      fi
    fi
  elif [[ -d "${seed_dir}" && -f "${disk_path}" ]]; then
    log_warn "Dry-run: reusing existing disk and seed dir for ${vm_name}"
  fi

  if [[ "${windows_guest}" -eq 1 ]]; then
    vm_create_blank_disk "${PROFILE}" "${disk_path}" "${disk_gb}"
  else
    vm_create_disk "${PROFILE}" "${disk_path}" "${base_image}" "${disk_gb}"
    seed_iso="$(vm_render_cloud_init "${PROFILE}" "${fqdn}" "${vm_name}" "${ethernets_json}")"
    chmod 644 "${seed_iso}" 2>/dev/null || true
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    vm_write_install_artifacts "${vm_name}" "${fqdn}" "${ethernets_json}" \
      "${disk_path}" "${seed_iso}" "${base_image}" "${memory_mb}" "${vcpus}" \
      "${nested_virt}" "${perf_profile}" "${seed_dir}" "${cpu_topology}" "${os_variant}"
    log_info "Dry-run complete for ${vm_name} (${fqdn})"
    log_info "Artifacts:"
    log_info "  disk:      ${disk_path}"
    if [[ -n "${seed_iso}" ]]; then
      log_info "  seed ISO:  ${seed_iso}"
    fi
    log_info "  install:   ${seed_dir}/install.sh"
    if [[ -f "${seed_dir}/domain.xml" ]]; then
      log_info "  domain:    ${seed_dir}/domain.xml"
    fi
    log_info "  manifest:  ${seed_dir}/manifest.txt"
    if [[ "${windows_guest}" -eq 1 ]]; then
      log_info "Windows profile: attach an install ISO manually before first boot"
    else
      log_info "Copy disk, seed directory, and base image to the target hypervisor, then run install.sh"
    fi
    return 0
  fi

  local -a virt_argv=()
  vm_build_virt_install_argv virt_argv "${vm_name}" "${disk_path}" "${seed_iso}" \
    "${ethernets_json}" "${memory_mb}" "${vcpus}" "${nested_virt}" "${perf_profile}" \
    "${cpu_topology}" "${os_variant}"

  if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    mkdir -p "$(dirname "${domain_xml}")"
    virt-install "${virt_argv[@]}" --print-xml > "${domain_xml}"
    if [[ "${windows_guest}" -eq 1 ]]; then
      vm_enrich_windows11_domain_xml "${domain_xml}" "${os_variant:-win11}"
    fi
    virsh define "${domain_xml}" >/dev/null
    log_info "Defined VM ${vm_name} (not started)"
  else
    virsh dumpxml "${vm_name}" > "${domain_xml}"
    log_info "Prepare: VM ${vm_name} already defined — refreshing manifest"
  fi
  resolved_ethernets="$(vm_ethernets_with_xml_macs "${ethernets_json}" "${domain_xml}")"

  if [[ "${AUTOSTART}" -eq 1 ]]; then
    vm_set_autostart "${vm_name}"
  fi
  vm_write_manifest "${vm_name}" "${fqdn}" "${resolved_ethernets}" \
    "${disk_path}" "${seed_iso}" "${base_image}" "${domain_xml}" "${manifest}"
  log_info "Resolved VM interfaces:"
  vm_print_ethernets_yaml "${resolved_ethernets}" >&2

  if [[ "${PREPARE}" -eq 1 ]] || { [[ "${windows_guest}" -eq 1 ]] && [[ "${FORCE_BOOT}" -eq 0 ]]; }; then
    if [[ "${windows_guest}" -eq 1 && "${PREPARE}" -eq 0 ]]; then
      log_info "windows11 profile: defined only (pass --force-boot to start without an install ISO path)"
    fi
    if vm_ethernets_use_dhcp "${resolved_ethernets}" && [[ -n "${RESERVE_FQDN}" ]]; then
      local reserve_ip
      reserve_ip="$(vm_inventory_lookup "${PROFILE}" "${RESERVE_FQDN}" "ansible_host")"
      vm_print_reservation_block "${RESERVE_FQDN}" "${vm_name}" "${resolved_ethernets}" \
        "${reserve_ip}" "${PROFILE}"
      if [[ "${WAIT_RESERVATION}" -eq 1 ]]; then
        vm_wait_for_reservation_confirm
      fi
    else
      log_info "Prepared ${vm_name} (${fqdn}) — start with vm-start.sh when ready"
    fi
    return 0
  fi

  if vm_ethernets_use_dhcp "${resolved_ethernets}" && [[ "${PROFILE}" == "production" \
        && -n "${RESERVE_FQDN}" && "${FORCE_BOOT}" -eq 0 ]]; then
    log_warn "Production DHCP host ${RESERVE_FQDN}: booting immediately may race router reservations."
    log_warn "Prefer: $(basename "$0") -i production --prepare ${RESERVE_FQDN}"
  fi

  log_info "Starting VM ${vm_name} (${fqdn})"
  virsh start "${vm_name}" >/dev/null
  log_info "VM ${vm_name} created"
}

main() {
  parse_args "$@"

  if [[ "${NETWORK_EXPLICIT}" -eq 0 ]]; then
    NET_NAME="$(vm_profile_default_network "${PROFILE}")"
  fi

  if [[ -n "${INVENTORY_FQDN}" ]]; then
    [[ -z "${VM_NAME}" ]] || die "Cannot combine inventory FQDN with --name"
    [[ -z "${BRIDGE}" ]] || die "Cannot combine inventory FQDN with --bridge"
    [[ "${USE_DHCP}" -eq 0 ]] || die "Cannot combine inventory FQDN with --dhcp"
    [[ "${NETWORK_EXPLICIT}" -eq 0 ]] || die "Cannot combine inventory FQDN with --network"

    local vm_name host_memory host_disk_gb nested_virt_flag=0 ethernets_json
    local host_vcpus host_cpu_topology="" host_os_variant="" cores threads
    vm_name="$(vm_inventory_lookup "${PROFILE}" "${INVENTORY_FQDN}" "vm_name")"
    ethernets_json="$(vm_inventory_ethernets "${PROFILE}" "${INVENTORY_FQDN}")"
    RESERVE_FQDN="${INVENTORY_FQDN}"
    if ! vm_ethernets_use_dhcp "${ethernets_json}"; then
      RESERVE_FQDN=""
    fi

    host_memory="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_memory_mb")"
    if [[ -n "${host_memory}" ]]; then
      MEMORY_MB="${host_memory}"
    fi
    host_disk_gb="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_disk_gb")"
    if [[ -n "${DISK_GB}" ]]; then
      host_disk_gb="${DISK_GB}"
    fi
    host_vcpus="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_vcpus")"
    if [[ -z "${host_vcpus}" ]]; then
      host_vcpus="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_cpu_count")"
    fi
    if [[ -n "${host_vcpus}" ]]; then
      VCPUS="${host_vcpus}"
    fi
    host_cpu_topology="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_cpu_topology")"
    if [[ -n "${host_cpu_topology}" ]]; then
      read -r cores threads <<< "$(vm_parse_cpu_topology "${host_cpu_topology}")"
      VCPUS="$((cores * threads))"
    fi
    host_os_variant="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_os_variant")"
    nested_virt="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_nested_virt")"
    if [[ "${nested_virt,,}" == "true" ]]; then
      nested_virt_flag=1
    fi
    if [[ "${NESTED_VIRT}" -eq 1 ]]; then
      nested_virt_flag=1
    fi
    host_perf_profile="$(vm_inventory_lookup_optional "${PROFILE}" "${INVENTORY_FQDN}" "vm_perf_profile")"
    if [[ -n "${host_perf_profile}" ]]; then
      PERF_PROFILE="${host_perf_profile}"
    fi

    create_vm "${vm_name}" "${INVENTORY_FQDN}" "${ethernets_json}" \
      "${MEMORY_MB}" "${VCPUS}" "${host_disk_gb}" "${nested_virt_flag}" "${PERF_PROFILE}" \
      "${host_cpu_topology}" "${host_os_variant}"
    return 0
  fi

  RESERVE_FQDN=""
  resolve_adhoc_config
  resolve_adhoc_cloud_init
  local adhoc_host_json="" ethernets_json=""
  if [[ -n "${ADHOC_ETHERNETS_JSON}" ]]; then
    ethernets_json="${ADHOC_ETHERNETS_JSON}"
  elif [[ "${ADHOC_CLOUD_MODE}" == "static" ]]; then
    adhoc_host_json="$(python3 - "${NET_NAME}" "${BRIDGE}" "${ADHOC_VM_IP}" \
      "${VM_SUBNET_PREFIX}" "${VM_GATEWAY}" "${VM_DNS_SERVERS_JSON}" <<'PY'
import json, sys
network, bridge, ip, prefix, gateway, dns_json = sys.argv[1:]
entry = {
    "addresses": [f"{ip}/{prefix}"],
    "dhcp4": False,
    "dhcp6": False,
    "routes": [{"to": "default", "via": gateway}],
    "nameservers": json.loads(dns_json),
}
entry["bridge" if bridge else "network"] = bridge or network
print(json.dumps({"ethernets": [entry]}))
PY
)"
  else
    adhoc_host_json="$(python3 - "${NET_NAME}" "${BRIDGE}" <<'PY'
import json, sys
network, bridge = sys.argv[1:]
entry = {"dhcp4": True, "dhcp6": True}
entry["bridge" if bridge else "network"] = bridge or network
print(json.dumps({"ethernets": [entry]}))
PY
)"
  fi
  if [[ -z "${ethernets_json}" ]]; then
    ethernets_json="$(vm_normalize_ethernets "${adhoc_host_json}")"
  fi
  create_vm "${VM_NAME}" "${FQDN}" "${ethernets_json}" \
    "${MEMORY_MB}" "${VCPUS}" "${DISK_GB}" "${NESTED_VIRT}" "${PERF_PROFILE}"
}

main "$@"
