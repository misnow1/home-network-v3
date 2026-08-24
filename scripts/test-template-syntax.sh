#!/usr/bin/env bash
# Tier 1 test: every role template must parse as Jinja2.
# Catches bash sigils that collide with Jinja delimiters, e.g. ${#array[@]}
# which Jinja reads as the start of a comment block.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"
# shellcheck source=lib/ansible.sh
source "${ROOT}/scripts/lib/ansible.sh"

main() {
  ensure_venv_path "${ROOT}"
  require_cmd python3

  python3 - "${ROOT}" <<'PY'
import pathlib
import sys

from jinja2 import Environment

root = pathlib.Path(sys.argv[1])
env = Environment()
failures = []

for template in sorted(root.glob("roles/*/templates/**/*.j2")):
    try:
        env.parse(template.read_text(), filename=str(template))
    except Exception as exc:  # jinja2.TemplateSyntaxError and friends
        failures.append(f"{template.relative_to(root)}: {exc}")

for failure in failures:
    print(f"FAIL {failure}", file=sys.stderr)

if failures:
    sys.exit(1)
PY

  log_info "test-template-syntax.sh passed"
}

main "$@"
