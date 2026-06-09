#!/usr/bin/env bash
# Destroy an ephemeral DHCP probe VM by libvirt name.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

VM_NAME="${1:-dhcpprobe-lab-test}"

exec "${ROOT}/scripts/lab/vm-destroy.sh" --name "${VM_NAME}"
