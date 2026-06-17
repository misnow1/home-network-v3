#!/usr/bin/env bash
# Lab wrapper — delegates to generic inventory-host-var with lab profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/inventory-host-var.sh" -i lab "$@"
