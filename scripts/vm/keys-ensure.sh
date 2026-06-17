#!/usr/bin/env bash
# Ensure VM SSH keypair exists for an inventory profile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROFILE="lab"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-i PROFILE]

Options:
  -i, --inventory PROFILE   Key profile: lab or production (default: lab)
  -h, --help                Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--inventory)
        PROFILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  require_cmd ssh-keygen
  local key_dir priv_key pub_key key_label
  key_dir="${ROOT}/scripts/vm/keys"
  priv_key="${key_dir}/$(vm_profile_key_basename "${PROFILE}")"
  pub_key="${priv_key}.pub"
  key_label="home-network-v3-${PROFILE}"

  mkdir -p "${key_dir}"

  if [[ ! -f "${priv_key}" ]]; then
    log_info "Generating ${PROFILE} ed25519 keypair at ${key_dir}"
    ssh-keygen -t ed25519 -f "${priv_key}" -N "" -C "${key_label}"
  else
    log_info "${PROFILE} keypair already present"
  fi

  [[ -f "${pub_key}" ]] || die "Missing public key ${pub_key}"
  chmod 600 "${priv_key}"
  chmod 644 "${pub_key}"
}

main "$@"
