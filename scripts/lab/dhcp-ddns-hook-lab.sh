#!/usr/bin/env bash
# Lab wrapper: point dhcp-ddns-hook.sh at env on local disk (rootsquash-safe).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

export DDNS_ENV_FILE="$(lab_data_dir)/home-ddns.env"
exec "${ROOT}/scripts/dhcp-ddns-hook.sh" "$@"
