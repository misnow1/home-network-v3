#!/usr/bin/env bash
# Build nocloud CIDATA files for Ubuntu Server autoinstall (identity + SSH; storage manual).
#
#   ./scripts/reimage/ubuntu-autoinstall/build-user-data.sh --profile kvm01 -o /mnt/CIDATA
#
# Copy Ubuntu 24.04 Server ISO to USB, add a VFAT partition labeled CIDATA, run this
# script with -o pointing at that mount. See README.md in this directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

PROFILE="kvm01"
OUTPUT_DIR=""
HOSTNAME=""
LIBVIRT_UUID=""
INSTANCE_ID=""

usage() {
  cat <<'EOF'
Usage: build-user-data.sh [options]

Write user-data and meta-data for Ubuntu autoinstall (nocloud).

Options:
  --profile NAME       Profile: kvm01 (default)
  -o, --output DIR     Output directory (CIDATA mount; required)
  --hostname NAME      Short hostname (default: profile name)
  --libvirt-uuid UUID  Optional: append fstab line for /var/lib/libvirt in late-commands
  --instance-id ID     meta-data instance-id (default: reimage-<hostname>-<date>)
  -h, --help           Show this help
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="$2"
        shift 2
        ;;
      -o | --output)
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --hostname)
        HOSTNAME="$2"
        shift 2
        ;;
      --libvirt-uuid)
        LIBVIRT_UUID="$2"
        shift 2
        ;;
      --instance-id)
        INSTANCE_ID="$2"
        shift 2
        ;;
      -h | --help)
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

  [[ -n "${OUTPUT_DIR}" ]] || die "Required: -o /path/to/CIDATA"
  require_cmd envsubst
  require_cmd openssl

  local pub_key pub_key_file tmpl_dir password_hash late_fstab
  pub_key_file="${ROOT}/scripts/vm/keys/prod_id_ed25519.pub"
  [[ -f "${pub_key_file}" ]] || die "Missing ${pub_key_file} — run scripts/vm/keys-ensure.sh -i production"

  pub_key="$(tr -d '\n' < "${pub_key_file}")"
  [[ -n "${HOSTNAME}" ]] || HOSTNAME="${PROFILE}"
  [[ -n "${INSTANCE_ID}" ]] || INSTANCE_ID="reimage-${HOSTNAME}-$(date +%Y%m%d)"

  # Subiquity requires identity.password; lock account via late-command passwd -l.
  password_hash="$(openssl passwd -6 "$(openssl rand -hex 16)")"

  late_fstab=""
  if [[ -n "${LIBVIRT_UUID}" ]]; then
    late_fstab="    - curtin in-target --target=/target -- bash -c 'grep -q /var/lib/libvirt /etc/fstab || echo \"UUID=${LIBVIRT_UUID} /var/lib/libvirt xfs defaults 0 2\" >> /etc/fstab'"
  fi

  tmpl_dir="${ROOT}/scripts/reimage/ubuntu-autoinstall"
  mkdir -p "${OUTPUT_DIR}"

  export AUTOINSTALL_HOSTNAME="${HOSTNAME}"
  export AUTOINSTALL_PASSWORD_HASH="${password_hash}"
  export AUTOINSTALL_SSH_PUBKEY="${pub_key}"
  export AUTOINSTALL_INSTANCE_ID="${INSTANCE_ID}"
  export AUTOINSTALL_LATE_FSTAB="${late_fstab}"

  envsubst '${AUTOINSTALL_HOSTNAME} ${AUTOINSTALL_PASSWORD_HASH} ${AUTOINSTALL_SSH_PUBKEY} ${AUTOINSTALL_INSTANCE_ID} ${AUTOINSTALL_LATE_FSTAB}' \
    < "${tmpl_dir}/user-data.tmpl" > "${OUTPUT_DIR}/user-data"

  envsubst '${AUTOINSTALL_HOSTNAME} ${AUTOINSTALL_INSTANCE_ID}' \
    < "${tmpl_dir}/meta-data.tmpl" > "${OUTPUT_DIR}/meta-data"

  log_info "Wrote ${OUTPUT_DIR}/user-data and meta-data (profile=${PROFILE}, hostname=${HOSTNAME})"
  log_info "Label USB partition CIDATA and boot Ubuntu Server ISO; confirm storage manually in the installer."
}

main "$@"
