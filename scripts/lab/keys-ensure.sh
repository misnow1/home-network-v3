#!/usr/bin/env bash
# Lab wrapper — delegates to generic keys-ensure with lab profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/keys-ensure.sh" -i lab "$@"
