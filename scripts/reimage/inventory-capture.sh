#!/usr/bin/env bash
# Tier-1 read-only inventory capture for kif/kvm01 reimage (Slice 19).
# Run on the target host as root during the maintenance window.
#
#   sudo ./scripts/reimage/inventory-capture.sh
#   sudo ./scripts/reimage/inventory-capture.sh --staging /archive/pre-reimage-kif-2026-06-29
#   sudo ./scripts/reimage/inventory-capture.sh --host-label kvm01
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=reimage-lib.sh
source "${ROOT}/scripts/reimage/reimage-lib.sh"

STAGING=""
HOST_LABEL=""
KIF_SERVICES=0

usage() {
  cat <<'EOF'
Usage: inventory-capture.sh [options]

Capture Tier-1 config and service definitions to a staging directory on /archive.

Options:
  --staging PATH       Staging root (default: /archive/pre-reimage-<host>-<date>)
  --host-label NAME    Label for MANIFEST (default: short hostname)
  --kif-services       Also capture Samba/winbind, NUT, wsdd (auto on hostname kif)
  --help               Show this help

Does not stop VMs/Docker or copy qcow2/volumes — use inventory-backup.sh for Tier-2.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging)
      STAGING="$2"
      shift 2
      ;;
    --host-label)
      HOST_LABEL="$2"
      shift 2
      ;;
    --kif-services)
      KIF_SERVICES=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

reimage_require_root

short_host="$(hostname -s | tr '[:upper:]' '[:lower:]')"
[[ -z "${HOST_LABEL}" ]] && HOST_LABEL="${short_host}"
[[ "${short_host}" == kif ]] && KIF_SERVICES=1

[[ -z "${STAGING}" ]] && STAGING="$(reimage_default_staging_dir "${HOST_LABEL}")"

if ! reimage_staging_writable "${STAGING}"; then
  echo "/archive not writable (NFS rootsquash?) — use --staging under local disk" >&2
  echo "Example: --staging /var/tmp/pre-reimage-${HOST_LABEL}-$(date +%Y-%m-%d)" >&2
  exit 1
fi

echo "Staging: ${STAGING}"
reimage_mkdir_staging "${STAGING}"

reimage_capture_storage "${STAGING}"
reimage_capture_libvirt "${STAGING}"
reimage_capture_docker "${STAGING}"
reimage_capture_config_common "${STAGING}"

if [[ "${KIF_SERVICES}" -eq 1 ]]; then
  reimage_capture_kif_services "${STAGING}"
fi

reimage_write_manifest "${STAGING}" "${HOST_LABEL}"

echo "Tier-1 capture complete: ${STAGING}"
echo "Next: review MANIFEST.txt; run inventory-backup.sh for Tier-2 heavy copies when ready."
