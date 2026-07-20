#!/usr/bin/env bash
# Smoke test for vm-create.sh --dry-run (no libvirt define).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=vm/vm-lib.sh
source "${ROOT}/scripts/vm/vm-lib.sh"

main() {
  vm_name="dry-run-test-$$"
  tmp_base="${ROOT}/.tmp-vm-create-dry-run-$$"
  trap 'rm -rf "${tmp_base}"' EXIT
  mkdir -p "${tmp_base}"

  export VM_DATA_BASE="${tmp_base}/vm-data"
  mkdir -p "${VM_DATA_BASE}/images" "${VM_DATA_BASE}/lab/vms" "${VM_DATA_BASE}/lab/seeds"
  qemu-img create -f qcow2 "${VM_DATA_BASE}/images/noble-server-cloudimg-amd64.img" 16M >/dev/null

  "${ROOT}/scripts/vm/keys-ensure.sh" -i lab >/dev/null
  "${ROOT}/scripts/vm/vm-create.sh" -i lab --dry-run \
    --name "${vm_name}" \
    --fqdn "${vm_name}.lab.test" \
    --ip 192.168.122.50 \
    --disk-gb 2

  seed_dir="$(vm_seeds_dir lab)/${vm_name}"
  disk_path="$(vm_vms_dir lab)/${vm_name}.qcow2"

  [[ -f "${disk_path}" ]] || die "missing disk ${disk_path}"
  [[ -f "${seed_dir}/seed.iso" ]] || die "missing seed ISO"
  [[ -f "${seed_dir}/install.sh" ]] || die "missing install.sh"
  [[ -x "${seed_dir}/install.sh" ]] || die "install.sh not executable"
  [[ -f "${seed_dir}/manifest.txt" ]] || die "missing manifest.txt"
  grep -q "vm_name=${vm_name}" "${seed_dir}/manifest.txt" \
    || die "manifest missing vm_name"
  grep -q '^ethernets_json=' "${seed_dir}/manifest.txt" \
    || die "manifest missing ethernets_json"
  grep -q 'macaddress:' "${seed_dir}/manifest.txt" \
    || die "manifest missing generated MAC (must work without virt-install)"
  ! grep -q 'home-dc-lab' "${seed_dir}/user-data" \
    || die "libvirt network leaked into guest netplan"
  ! grep -q 'macaddress' "${seed_dir}/user-data" \
    || die "libvirt MAC leaked into guest netplan"

  # CI has no virt-install; MAC assignment must not depend on domain XML.
  ensured_macs="$(vm_ensure_ethernets_macs \
    '[{"network":"default","dhcp4":true,"dhcp6":true}]')"
  grep -q 'macaddress' <<< "${ensured_macs}" \
    || die "vm_ensure_ethernets_macs did not assign a MAC"
  grep -Eq '52:54:00:[0-9a-f]{2}:[0-9a-f]{2}:[0-9a-f]{2}' <<< "${ensured_macs}" \
    || die "vm_ensure_ethernets_macs MAC is not in the qemu OUI range"
  pinned_macs="$(vm_ensure_ethernets_macs \
    '[{"network":"default","dhcp4":true,"macaddress":"52:54:00:aa:bb:cc"}]')"
  grep -q '52:54:00:aa:bb:cc' <<< "${pinned_macs}" \
    || die "vm_ensure_ethernets_macs overwrote a pinned MAC"

  "${ROOT}/scripts/vm/vm-create.sh" -i lab --dry-run \
    --name "${vm_name}-dhcp" \
    --fqdn "${vm_name}-dhcp.lab.test" \
    --dhcp \
    --disk-gb 2

  dhcp_seed_dir="$(vm_seeds_dir lab)/${vm_name}-dhcp"
  grep -q 'macaddress:' "${dhcp_seed_dir}/manifest.txt" \
    || die "missing generated MAC in DHCP dry-run manifest"
  grep -q 'dhcp4: true' "${dhcp_seed_dir}/user-data" \
    || die "DHCP user-data missing dhcp4"
  grep -q 'dhcp6: true' "${dhcp_seed_dir}/user-data" \
    || die "DHCP user-data missing dhcp6"

  normalized="$(vm_normalize_ethernets \
    '{"vm_network":"default-net","ethernets":[{"dhcp4":true},{"network":"vlan3","macaddress":"52:54:00:12:34:56"}]}')"
  mapfile -t network_args < <(vm_network_args "${normalized}" 2 lab)
  [[ "${#network_args[@]}" -eq 2 ]] || die "expected two libvirt network args"
  [[ "${network_args[0]}" == "network=default-net,model=virtio" ]]
  [[ "${network_args[1]}" == "network=vlan3,model=virtio,mac=52:54:00:12:34:56" ]]

  mapfile -t balanced_network_args < <(vm_network_args "${normalized}" 4 balanced)
  [[ "${balanced_network_args[0]}" == "network=default-net,model=virtio,driver.queues=4" ]]
  disk_arg="$(vm_disk_virt_install_arg balanced /tmp/test.qcow2)"
  [[ "${disk_arg}" == *"cache=none"* ]] || die "balanced disk arg missing cache=none"
  [[ "${disk_arg}" == *"io=native"* ]] || die "balanced disk arg missing io=native"

  win_disk="$(vm_disk_virt_install_arg windows11 /tmp/win.qcow2)"
  [[ "${win_disk}" == *"cache=none"* ]] || die "windows11 disk arg missing cache=none"
  vm_perf_profile_validate windows11
  read -r win_cores win_threads <<< "$(vm_parse_cpu_topology 6,1)"
  [[ "${win_cores}" == "6" && "${win_threads}" == "1" ]] || die "topology parse failed"

  # Windows domain enrichment (synthetic XML)
  win_xml="${tmp_base}/win11.xml"
  cat > "${win_xml}" <<'XML'
<domain type='kvm'>
  <name>win-test</name>
  <features>
    <hyperv>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
    </hyperv>
  </features>
  <cpu mode='host-passthrough' migratable='off'>
    <topology sockets='1' dies='1' cores='6' threads='1'/>
  </cpu>
</domain>
XML
  vm_enrich_windows11_domain_xml "${win_xml}" win11
  grep -q 'vpindex' "${win_xml}" || die "windows enrich missing vpindex"
  grep -q 'tlbflush' "${win_xml}" || die "windows enrich missing tlbflush"
  grep -q 'topoext' "${win_xml}" || die "windows enrich missing topoext"
  grep -q 'microsoft.com/win/11' "${win_xml}" || die "windows enrich missing win/11 metadata"
  netplan="$(vm_build_netplan_yaml "${normalized}")"
  ! grep -q 'default-net\|vlan3\|macaddress' <<< "${netplan}" \
    || die "libvirt-only metadata leaked into generated netplan"

  log_info "test-vm-create-dry-run.sh passed"
}

main "$@"
