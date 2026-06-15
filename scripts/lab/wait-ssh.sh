#!/usr/bin/env bash
# Lab wrapper — delegates to generic wait-ssh with lab inventory profile.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "${ROOT}/scripts/vm/wait-ssh.sh" -i lab "$@"
