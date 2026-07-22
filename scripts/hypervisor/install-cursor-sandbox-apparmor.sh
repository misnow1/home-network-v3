#!/usr/bin/env bash
# Install bubblewrap + AppArmor profile for Cursor Remote SSH terminal sandbox.
# Idempotent; safe to re-run after Cursor upgrades.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
profile_src="${repo_root}/roles/hypervisor/files/cursor-sandbox-remote"
profile_dest="/etc/apparmor.d/cursor-sandbox-remote"

if [[ ! -f "${profile_src}" ]]; then
  echo "error: missing profile template: ${profile_src}" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Re-run with sudo: sudo $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get install -y bubblewrap

install -m 0644 -o root -g root "${profile_src}" "${profile_dest}"
apparmor_parser -r "${profile_dest}"

if aa-status 2>/dev/null | grep -q cursor_sandbox_remote; then
  echo "AppArmor profile cursor_sandbox_remote is loaded."
else
  echo "warning: cursor_sandbox_remote not listed in aa-status (AppArmor may be disabled)" >&2
fi

echo "Installed ${profile_dest} and loaded cursor_sandbox_remote profile."
echo "Reload the Cursor window, then confirm remoteexthost.log shows:"
echo "  Sandbox support detected: true"
