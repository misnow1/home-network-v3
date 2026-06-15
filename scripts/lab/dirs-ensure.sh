#!/usr/bin/env bash
# Lab wrapper — delegates to generic dirs-ensure with lab profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/dirs-ensure.sh" -i lab "$@"
