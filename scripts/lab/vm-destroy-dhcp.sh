#!/usr/bin/env bash
# Destroy an ephemeral DHCP lab VM by libvirt domain name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VM_NAME="${1:?libvirt domain name required}"
exec "${ROOT}/scripts/vm/vm-destroy.sh" -i lab --name "${VM_NAME}"
