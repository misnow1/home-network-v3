#!/usr/bin/env bash
# Create an ephemeral lab VM that uses DHCP (for dhcp-ddns integration tests).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

VM_NAME="${1:-dhcpprobe-lab-test}"
FQDN="${2:-dhcpprobe.lab.test}"
HOST_SHORT="${FQDN%%.*}"

exec "${ROOT}/scripts/lab/vm-create.sh" \
  --name "${VM_NAME}" \
  --hostname "${HOST_SHORT}" \
  --fqdn "${FQDN}" \
  --dhcp \
  --memory "${LAB_VM_MEMORY_MB:-2048}" \
  --vcpus "${LAB_VM_VCPUS:-2}"
