#!/usr/bin/env bash
# Ansible command wrappers with consistent inventory and vault settings.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ansible_env() {
  local root="$1"
  export ANSIBLE_CONFIG="${root}/ansible.cfg"
  export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-local}"
  export ANSIBLE_REMOTE_TEMP="${ANSIBLE_REMOTE_TEMP:-/tmp/ansible-remote}"
}

ansible_lab_inventory() {
  local root="$1"
  printf '%s/inventories/lab' "${root}"
}

run_ansible_playbook() {
  local root="$1"
  shift
  ensure_venv_path "${root}"
  ansible_env "${root}"
  local vault_file
  vault_file="$(ensure_vault_password_file "${root}")"
  ansible-playbook \
    -i "$(ansible_lab_inventory "${root}")" \
    --vault-password-file "${vault_file}" \
    "$@"
}

run_ansible_syntax_check() {
  local root="$1"
  ensure_venv_path "${root}"
  ansible_env "${root}"
  local vault_file
  vault_file="$(ensure_vault_password_file "${root}")"
  local playbook inventory
  for playbook in "${root}"/playbooks/*.yml; do
    [[ -f "${playbook}" ]] || continue
    log_info "syntax-check ${playbook}"
    ansible-playbook \
      -i "$(ansible_lab_inventory "${root}")" \
      --vault-password-file "${vault_file}" \
      --syntax-check "${playbook}"
  done
}

assert_ansible_playbook_idempotent() {
  local root="$1"
  shift
  local output recap
  output="$(run_ansible_playbook "${root}" "$@" 2>&1)"
  printf '%s\n' "${output}" >&2
  recap="$(printf '%s\n' "${output}" | awk '/^PLAY RECAP/,0')"
  if printf '%s\n' "${recap}" | grep -qE 'failed=[1-9]|unreachable=[1-9]'; then
    die "Playbook reported failures or unreachable hosts"
  fi
  # Idempotent means no host reports any change. Checking for changed=[1-9]
  # correctly catches a changed host even in multi-host recaps (the previous
  # 'grep changed=0' passed as long as any one host was unchanged).
  if printf '%s\n' "${recap}" | grep -qE 'changed=[1-9]'; then
    die "Expected idempotent run (changed=0)"
  fi
}
