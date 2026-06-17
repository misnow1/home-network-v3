#!/usr/bin/env bash
# Lab wrapper — delegates to generic VM create with lab inventory profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/vm-create.sh" -i lab "$@"
