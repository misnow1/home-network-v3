#!/usr/bin/env bash
# Create repo .venv with pyenv-aware Python and install dev dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

SKIP_GALAXY=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--skip-galaxy]

Creates .venv using pyenv's Python when available, installs requirements.txt,
and optionally installs Ansible Galaxy collections from requirements.yml.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-galaxy)
      SKIP_GALAXY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1 (try --help)" >&2
      exit 1
      ;;
  esac
done

if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init -)"
fi

PY="${PY:-$(command -v python3.12 || command -v python3)}"
[[ -n "${PY}" && -x "${PY}" ]] || { echo "Python 3.12+ required"; exit 1; }

echo "Using Python: ${PY} ($("${PY}" --version))"

rm -rf .venv
"${PY}" -m venv .venv
.venv/bin/pip install -U pip
.venv/bin/pip install -r requirements.txt

if [[ "${SKIP_GALAXY}" -eq 0 ]]; then
  .venv/bin/ansible-galaxy collection install -r requirements.yml
fi

echo "Done. Tools: ${ROOT}/.venv/bin/ansible-lint"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "Note: install shellcheck for ./scripts/test-quick.sh (e.g. dnf install shellcheck)"
fi
