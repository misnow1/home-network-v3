#!/usr/bin/env bash
# Ensure lab SSH keypair exists; commit the public key, keep private key on kvm01.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

KEY_DIR="${ROOT}/scripts/lab/keys"
PRIV_KEY="${KEY_DIR}/lab_id_ed25519"
PUB_KEY="${PRIV_KEY}.pub"

main() {
  require_cmd ssh-keygen
  mkdir -p "${KEY_DIR}"

  if [[ ! -f "${PRIV_KEY}" ]]; then
    log_info "Generating lab ed25519 keypair at ${KEY_DIR}"
    ssh-keygen -t ed25519 -f "${PRIV_KEY}" -N "" -C "home-network-v3-lab"
  else
    log_info "Lab keypair already present"
  fi

  [[ -f "${PUB_KEY}" ]] || die "Missing public key ${PUB_KEY}"
  chmod 600 "${PRIV_KEY}"
  chmod 644 "${PUB_KEY}"
}

main "$@"
