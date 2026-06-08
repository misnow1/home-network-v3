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
  if [[ -x "${ROOT}/.venv/bin/ansible-playbook" ]]; then
    export PATH="${ROOT}/.venv/bin:${PATH}"
  fi

  require_cmd virsh
  require_cmd virt-install

  log_info "Ensuring lab storage directories (local disk, not NFS home)"
  "${ROOT}/scripts/lab/dirs-ensure.sh"

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
  lab_slice="$("${ROOT}/scripts/lab/inventory-host-var.sh" "${LAB_HOST}" "lab_slice")"

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
