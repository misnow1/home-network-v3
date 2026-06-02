#!/usr/bin/env bash
# Run quick tests then integration tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

main() {
  "${ROOT}/scripts/test-quick.sh"
  "${ROOT}/scripts/test-integration.sh"
  log_info "test-all.sh passed"
}

main "$@"
