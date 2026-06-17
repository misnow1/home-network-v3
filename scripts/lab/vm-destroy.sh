#!/usr/bin/env bash
# Lab wrapper — delegates to generic VM destroy with lab inventory profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/vm-destroy.sh" -i lab "$@"
