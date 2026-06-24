#!/usr/bin/env bash
# Tier 3 integration tests: libvirt lab network and VM lifecycle on kvm01.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/ansible.sh
source "${ROOT}/scripts/lib/ansible.sh"

LAB_HOST="${LAB_HOST:-hv01.lab.test}"
LAB_DC_HOST="${LAB_DC_HOST:-dc01.lab.test}"
LAB_DC2_HOST="${LAB_DC2_HOST:-dc02.lab.test}"
SKIP_VM_TESTS="${SKIP_VM_TESTS:-0}"

run_baseline_integration() {
  log_info "Converging baseline on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Running baseline convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_baseline_converged.yml --limit "${LAB_HOST}"
}

run_dc_integration() {
  log_info "Bootstrapping Samba AD DC on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/dc-bootstrap.yml --limit "${LAB_HOST}"

  log_info "Converging Samba AD DC on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/dc-converge.yml --limit "${LAB_HOST}"

  log_info "Converging Samba AD DC on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/dc-converge.yml --limit "${LAB_HOST}"

  log_info "Running Samba AD DC convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_dc_converged.yml --limit "${LAB_HOST}"
}

run_dc_replica_integration() {
  log_info "Provisioning primary lab DC ${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_DC_HOST}"

  log_info "Bootstrapping Samba AD DC on ${LAB_DC_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/dc-bootstrap.yml --limit "${LAB_DC_HOST}"

  log_info "Converging Samba AD DC on ${LAB_DC_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/dc-converge.yml --limit "${LAB_DC_HOST}"

  log_info "Provisioning replica lab DC ${LAB_DC2_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC2_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_DC2_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_DC2_HOST}"

  log_info "Joining ${LAB_DC2_HOST} as replica DC"
  run_ansible_playbook "${ROOT}" playbooks/dc-replica-join.yml --limit "${LAB_DC2_HOST}"

  log_info "Converging both lab DCs (first run)"
  run_ansible_playbook "${ROOT}" playbooks/dc-converge.yml --limit dc

  log_info "Converging both lab DCs (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/dc-converge.yml --limit dc

  log_info "Running Samba AD DC replica convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_dc_replica_converged.yml --limit dc

  log_info "Destroying replica integration test VMs"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC2_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

provision_lab_dc() {
  log_info "Provisioning lab DC ${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_DC_HOST}"

  run_ansible_playbook "${ROOT}" playbooks/dc-bootstrap.yml --limit "${LAB_DC_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/dc-converge.yml --limit "${LAB_DC_HOST}"
  run_ansible_playbook "${ROOT}" tests/integration/setup_lab_ad_users.yml --limit "${LAB_DC_HOST}"
}

run_domain_join_integration() {
  provision_lab_dc

  log_info "Integration VM lifecycle for member ${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Joining domain on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/domain-join.yml --limit "${LAB_HOST}"

  log_info "Joining domain on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/domain-join.yml --limit "${LAB_HOST}"

  log_info "Running domain join convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_domain_join_converged.yml --limit "${LAB_HOST}"

  log_info "Destroying integration test VMs"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

run_hypervisor_integration() {
  log_info "Integration VM lifecycle for ${LAB_HOST} (slice=hypervisor)"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Converging hypervisor on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/hypervisor.yml --limit "${LAB_HOST}"

  log_info "Converging hypervisor on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/hypervisor.yml --limit "${LAB_HOST}"

  log_info "Running hypervisor convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_hypervisor_converged.yml --limit "${LAB_HOST}"

  log_info "Destroying integration test VM ${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
}

run_fileserver_integration() {
  provision_lab_dc

  log_info "Integration VM lifecycle for ${LAB_HOST} (slice=fileserver)"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Converging file server on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/fileserver.yml --limit "${LAB_HOST}"

  log_info "Converging file server on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/fileserver.yml --limit "${LAB_HOST}"

  log_info "Running file server convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_fileserver_converged.yml --limit "${LAB_HOST}"

  log_info "Destroying integration test VMs"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

run_ddns_integration() {
  provision_lab_dc

  log_info "Integration VM lifecycle for ${LAB_HOST} (slice=ddns)"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Joining domain on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/domain-join.yml --limit "${LAB_HOST}"

  log_info "Converging DDNS client on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/ddns-client.yml --limit "${LAB_HOST}"

  log_info "Converging DDNS client on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/ddns-client.yml --limit "${LAB_HOST}"

  log_info "Running DDNS convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_ddns_converged.yml --limit "${LAB_HOST}"

  log_info "Destroying integration test VMs"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

run_dhcp_ddns_integration() {
  local probe_vm="dhcpprobe-lab-test"
  local probe_fqdn="dhcpprobe.lab.test"
  local dc_ip="192.168.100.10"
  local leased_ip=""
  local attempt dig_ptr

  require_cmd curl
  require_cmd dig

  provision_lab_dc

  log_info "Converging DDNS API on ${LAB_DC_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/ddns-api.yml --limit "${LAB_DC_HOST}"

  log_info "Converging DDNS API on ${LAB_DC_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/ddns-api.yml --limit "${LAB_DC_HOST}"

  log_info "Running DDNS API convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_dhcp_ddns_converged.yml --limit "${LAB_DC_HOST}"

  log_info "Creating DHCP probe VM ${probe_vm}"
  "${ROOT}/scripts/lab/vm-destroy-dhcp.sh" "${probe_vm}" || true
  "${ROOT}/scripts/lab/vm-create-dhcp.sh" "${probe_vm}" "${probe_fqdn}"

  log_info "Waiting for DHCP lease and DDNS registration for ${probe_fqdn}"
  for attempt in $(seq 1 24); do
    leased_ip="$(dig @"${dc_ip}" "${probe_fqdn}" A +short 2>/dev/null | head -1 || true)"
    if [[ -n "${leased_ip}" ]]; then
      log_info "Resolved ${probe_fqdn} -> ${leased_ip} (attempt ${attempt})"
      break
    fi
    sleep 5
  done
  [[ -n "${leased_ip}" ]] || die "Timed out waiting for A record for ${probe_fqdn}"

  dig_ptr="$(dig @"${dc_ip}" -x "${leased_ip}" PTR +short 2>/dev/null | head -1 || true)"
  [[ "${dig_ptr}" == *"${probe_fqdn}"* ]] \
    || die "Expected PTR for ${leased_ip} to reference ${probe_fqdn}, got: ${dig_ptr:-empty}"

  log_info "Destroying DHCP probe VM ${probe_vm}"
  "${ROOT}/scripts/lab/vm-destroy-dhcp.sh" "${probe_vm}"

  log_info "Destroying lab DC ${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

run_certbot_integration() {
  provision_lab_dc

  log_info "Converging Certbot TLS on ${LAB_DC_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/certbot.yml --limit "${LAB_DC_HOST}"

  log_info "Converging Certbot TLS on ${LAB_DC_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/certbot.yml --limit "${LAB_DC_HOST}"

  log_info "Running Certbot / LDAP TLS convergence assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_certbot_converged.yml --limit "${LAB_DC_HOST}"

  log_info "Destroying lab DC ${LAB_DC_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_DC_HOST}"
}

run_backup_integration() {
  log_info "Integration VM lifecycle for ${LAB_HOST} (slice=backup)"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
  "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
  "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"

  log_info "Converging baseline on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/baseline.yml --limit "${LAB_HOST}"

  log_info "Converging hypervisor on ${LAB_HOST}"
  run_ansible_playbook "${ROOT}" playbooks/hypervisor.yml --limit "${LAB_HOST}"

  log_info "Converging backup on ${LAB_HOST} (first run)"
  run_ansible_playbook "${ROOT}" playbooks/backup.yml --limit "${LAB_HOST}"

  log_info "Converging backup on ${LAB_HOST} (idempotency check)"
  assert_ansible_playbook_idempotent "${ROOT}" playbooks/backup.yml --limit "${LAB_HOST}"

  log_info "Running backup restore drill assertions"
  run_ansible_playbook "${ROOT}" tests/integration/test_backup_converged.yml --limit "${LAB_HOST}"

  log_info "Destroying integration test VM ${LAB_HOST}"
  "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
}

main() {
  ensure_venv_path "${ROOT}"

  require_cmd virsh
  require_cmd virt-install

  log_info "Ensuring lab storage directories (local disk, not NFS home)"
  "${ROOT}/scripts/lab/dirs-ensure.sh"

  if [[ "${INTEGRATION_SLICE:-}" == "dhcp_ddns" ]]; then
    log_info "Ensuring dhcp-ddns hook before libvirt network (dhcp-script dependency)"
    "${ROOT}/scripts/lab/ddns-hook-ensure.sh"
  fi

  log_info "Ensuring lab libvirt network"
  "${ROOT}/scripts/lab/network-ensure.sh"

  log_info "Ensuring lab SSH keypair"
  "${ROOT}/scripts/lab/keys-ensure.sh"

  if [[ "${SKIP_VM_TESTS}" == "1" ]]; then
    log_warn "SKIP_VM_TESTS=1 — skipping VM create/destroy cycle"
    log_info "test-integration.sh passed (network and keys only)"
    return 0
  fi

  log_info "Ensuring Ubuntu cloud image"
  "${ROOT}/scripts/lab/image-ensure.sh"

  local lab_slice
  if [[ -n "${INTEGRATION_SLICE:-}" ]]; then
    lab_slice="${INTEGRATION_SLICE}"
  else
    lab_slice="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${LAB_HOST}" "lab_slice")"
  fi

  case "${lab_slice}" in
    baseline)
      log_info "Integration VM lifecycle for ${LAB_HOST} (slice=${lab_slice})"
      "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
      "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
      "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"
      run_baseline_integration
      "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
      ;;
    dc)
      log_info "Integration VM lifecycle for ${LAB_HOST} (slice=${lab_slice})"
      "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}" || true
      "${ROOT}/scripts/lab/vm-create.sh" "${LAB_HOST}"
      "${ROOT}/scripts/lab/wait-ssh.sh" "${LAB_HOST}"
      run_dc_integration
      "${ROOT}/scripts/lab/vm-destroy.sh" "${LAB_HOST}"
      ;;
    dc_replica)
      run_dc_replica_integration
      ;;
    domain_join)
      run_domain_join_integration
      ;;
    hypervisor)
      run_hypervisor_integration
      ;;
    fileserver)
      run_fileserver_integration
      ;;
    ddns)
      run_ddns_integration
      ;;
    dhcp_ddns)
      run_dhcp_ddns_integration
      ;;
    certbot)
      run_certbot_integration
      ;;
    backup)
      run_backup_integration
      ;;
    *)
      die "Unsupported lab_slice '${lab_slice}' for ${LAB_HOST}"
      ;;
  esac

  log_info "test-integration.sh passed"
}

main "$@"
