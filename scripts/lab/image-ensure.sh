#!/usr/bin/env bash
# Lab wrapper — delegates to generic image-ensure.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/image-ensure.sh" "$@"
