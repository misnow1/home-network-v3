#!/usr/bin/env bash
# Write home-ddns.env on local lab disk for libvirt dnsmasq (rootsquash-safe).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

LAB_DC_IP="${LAB_DC_IP:-192.168.100.10}"
LAB_DOMAIN="${LAB_DOMAIN:-lab.test}"
ENV_FILE="$(lab_data_dir)/home-ddns.env"

read_vault_var() {
  local key="$1"
  local vault_file vault_pass line
  vault_file="${ROOT}/inventories/lab/group_vars/all/vault.yml"
  vault_pass="$(ensure_vault_password_file "${ROOT}")"
  line="$(ansible-vault view "${vault_file}" --vault-password-file "${vault_pass}" \
    | grep -E "^${key}:" | head -1)"
  [[ -n "${line}" ]] || die "Missing ${key} in lab vault"
  printf '%s' "${line#*: }" | tr -d "'\""
}

main() {
  require_cmd ansible-vault

  local token
  token="$(read_vault_var vault_ddns_shared_secret)"

  mkdir -p "$(lab_data_dir)"
  log_info "Writing ${ENV_FILE}"
  umask 077
  cat > "${ENV_FILE}" <<EOF
DDNS_UPDATE_URL="http://${LAB_DC_IP}:8765/ddns/v1/lease"
DDNS_BEARER_TOKEN="${token}"
DDNS_DNS_DOMAIN="${LAB_DOMAIN}"
EOF
  chmod 0600 "${ENV_FILE}"

  log_info "ddns hook ensure complete"
}

main "$@"
