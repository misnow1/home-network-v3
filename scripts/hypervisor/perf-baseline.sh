#!/usr/bin/env bash
# Read-only hypervisor performance baseline report (host + libvirt summary).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

OUTPUT=""
HOST="$(hostname -f 2>/dev/null || hostname)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--output FILE]

Dump a read-only performance baseline for the current hypervisor host.
No configuration is changed.

Examples:
  $(basename "$0")
  $(basename "$0") --output /tmp/hypervisor-baseline.txt
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output|-o)
        OUTPUT="$2"
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

section() {
  printf '\n=== %s ===\n' "$1"
}

run_cmd() {
  local label="$1"
  shift
  printf '\n--- %s ---\n' "${label}"
  if "$@" 2>&1; then
    :
  else
    local rc=$?
    printf '(command failed with exit %s)\n' "${rc}"
  fi
}

maybe_cmd() {
  local label="$1"
  shift
  if command -v "$1" >/dev/null 2>&1; then
    run_cmd "${label}" "$@"
  else
    printf '\n--- %s ---\n(not installed: %s)\n' "${label}" "$1"
  fi
}

read_sysfs() {
  local label="$1"
  local path="$2"
  printf '\n--- %s ---\n' "${label}"
  if [[ -r "${path}" ]]; then
    cat "${path}"
  else
    printf '(not readable: %s)\n' "${path}"
  fi
}

collect_report() {
  section "Hypervisor performance baseline"
  printf 'timestamp: %s\n' "$(date -Is)"
  printf 'host: %s\n' "${HOST}"
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    printf 'os: %s %s\n' "${NAME:-unknown}" "${VERSION_ID:-}"
  fi

  section "CPU and NUMA"
  run_cmd "lscpu" lscpu
  maybe_cmd "numactl hardware" numactl -H

  section "Memory and THP"
  run_cmd "free -h" free -h
  read_sysfs "THP enabled" /sys/kernel/mm/transparent_hugepage/enabled
  read_sysfs "THP defrag" /sys/kernel/mm/transparent_hugepage/defrag
  read_sysfs "nr_hugepages" /proc/sys/vm/nr_hugepages

  section "Kernel sysctl (virt-relevant)"
  for key in vm.swappiness vm.dirty_ratio vm.dirty_background_ratio; do
    printf '%s = ' "${key}"
    sysctl -n "${key}" 2>/dev/null || printf '(unavailable)\n'
  done

  section "Tuned"
  maybe_cmd "tuned active profile" tuned-adm active

  section "Virtualization modules"
  run_cmd "lsmod kvm/vhost" bash -c 'lsmod | grep -E "kvm|vhost" || true'
  read_sysfs "/dev/kvm" /dev/kvm
  if [[ -c /dev/kvm ]]; then
    printf 'character device present\n'
  elif [[ -e /dev/kvm ]]; then
    printf 'path exists (not a char device?)\n'
  else
    printf 'missing\n'
  fi

  section "Libvirt"
  maybe_cmd "virsh uri" virsh -c qemu:///system uri
  maybe_cmd "virsh list --all" virsh -c qemu:///system list --all
  maybe_cmd "virsh pool-list --all" virsh -c qemu:///system pool-list --all

  section "Block devices and schedulers"
  local dev
  for dev in /sys/block/*; do
    [[ -d "${dev}" ]] || continue
    local name
    name="$(basename "${dev}")"
    [[ "${name}" == loop* ]] && continue
    printf '\n--- %s ---\n' "${name}"
    if [[ -r "${dev}/queue/scheduler" ]]; then
      printf 'scheduler: '
      cat "${dev}/queue/scheduler"
    fi
    if [[ -r "${dev}/queue/nr_requests" ]]; then
      printf 'nr_requests: '
      cat "${dev}/queue/nr_requests"
    fi
    if command -v lsblk >/dev/null 2>&1; then
      lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "/dev/${name}" 2>/dev/null || true
    fi
  done

  section "Libvirt and Docker mount points"
  maybe_cmd "findmnt libvirt tree" findmnt -R /var/lib/libvirt
  maybe_cmd "findmnt docker" findmnt /var/lib/docker
  maybe_cmd "findmnt srv docker" findmnt /srv/docker

  section "Docker"
  maybe_cmd "docker info (summary)" docker info --format '{{.Driver}} storage driver; {{.LoggingDriver}} logging'
  maybe_cmd "docker ps" docker ps --format 'table {{.Names}}\t{{.Status}}'
}

main() {
  parse_args "$@"

  if [[ -n "${OUTPUT}" ]]; then
    mkdir -p "$(dirname "${OUTPUT}")"
    collect_report | tee "${OUTPUT}"
    log_info "Wrote ${OUTPUT}"
  else
    collect_report
  fi
}

main "$@"
