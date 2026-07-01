#!/usr/bin/env bash
# Tier-2 heavy backup for kif/kvm01 reimage (Slice 19).
# Stop VMs/Docker first. Run on target host as root.
#
#   sudo ./scripts/reimage/inventory-backup.sh --staging /archive/pre-reimage-kif-2026-06-29
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=reimage-lib.sh
source "${ROOT}/scripts/reimage/reimage-lib.sh"

STAGING=""
HOST_LABEL=""
SKIP_HOME=0
SKIP_LIBVIRT=0
SKIP_DOCKER=0

usage() {
  cat <<'EOF'
Usage: inventory-backup.sh [options]

Tier-2 rsync of heavy state into an existing Tier-1 staging directory.
Run inventory-capture.sh first (or ensure staging exists).

Options:
  --staging PATH     Required — Tier-1 staging root on /archive
  --host-label NAME  Label for log messages (default: short hostname)
  --skip-home        Skip /home mirror (when kif2-home LV is preserved)
  --skip-libvirt     Skip /var/lib/libvirt/images rsync
  --skip-docker      Skip active docker named volume rsync
  --help             Show this help

Prerequisites: stop VMs and docker compose stacks before libvirt/docker copies.
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
    --skip-home)
      SKIP_HOME=1
      shift
      ;;
    --skip-libvirt)
      SKIP_LIBVIRT=1
      shift
      ;;
    --skip-docker)
      SKIP_DOCKER=1
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

[[ -n "${STAGING}" ]] || { echo "--staging required" >&2; usage >&2; exit 1; }
[[ -d "${STAGING}" ]] || { echo "staging not found: ${STAGING}" >&2; exit 1; }

[[ -z "${HOST_LABEL}" ]] && HOST_LABEL="$(hostname -s | tr '[:upper:]' '[:lower:]')"

if [[ "${SKIP_LIBVIRT}" -eq 0 && -d /var/lib/libvirt/images ]]; then
  echo "Rsync libvirt images → ${STAGING}/libvirt/images/"
  mkdir -p "${STAGING}/libvirt/images"
  rsync -aHAXx --info=progress2 /var/lib/libvirt/images/ "${STAGING}/libvirt/images/"
fi

if [[ "${SKIP_DOCKER}" -eq 0 ]] && command -v docker >/dev/null 2>&1; then
  mkdir -p "${STAGING}/docker/volumes"
  local_vol=""
  while IFS= read -r local_vol; do
    [[ -z "${local_vol}" ]] && continue
    [[ "${local_vol}" =~ ^[0-9a-f]{64}$ ]] && continue
    mp="$(docker volume inspect -f '{{ .Mountpoint }}' "${local_vol}" 2>/dev/null)" || continue
    echo "Rsync docker volume ${local_vol}"
    rsync -aHAXx "${mp}/" "${STAGING}/docker/volumes/${local_vol}/"
  done < <(docker volume ls -q 2>/dev/null)
fi

if [[ "${SKIP_HOME}" -eq 0 && -d /home ]]; then
  echo "Rsync /home mirror → ${STAGING}/home-mirror/ (insurance copy)"
  mkdir -p "${STAGING}/home-mirror"
  rsync -aHAXx --info=progress2 /home/ "${STAGING}/home-mirror/"
fi

{
  echo "tier=2"
  echo "completed=$(date -Iseconds)"
  du -sh "${STAGING}"/* 2>/dev/null || true
} >> "${STAGING}/MANIFEST.txt"

echo "Tier-2 backup complete: ${STAGING}"
