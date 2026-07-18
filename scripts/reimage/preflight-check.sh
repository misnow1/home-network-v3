#!/usr/bin/env bash
# Read-only pre-flight checks before kif/kvm01 reimage (Slice 19).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

WARNINGS=0

warn() {
  log_warn "$@"
  WARNINGS=$((WARNINGS + 1))
}

pass() {
  log_info "OK: $*"
}

usage() {
  cat <<'EOF'
Usage: preflight-check.sh

Read-only checks from the control node before the reimage maintenance window.
EOF
}

ssh_probe() {
  local user="$1"
  local key="$2"
  local host="$3"

  if ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${key}" "${user}@${host}" 'echo ok' >/dev/null 2>&1; then
    pass "SSH ${user}@${host}"
    return 0
  fi
  warn "SSH failed for ${user}@${host}"
  return 1
}

remote_df_archive() {
  local user="$1"
  local key="$2"
  local host="$3"

  local out
  if ! out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -i "${key}" "${user}@${host}" 'df -h /archive 2>/dev/null || df -h / | tail -1' 2>/dev/null)"; then
    warn "Could not check /archive space on ${host}"
    return 1
  fi
  log_info "${host} storage: ${out}"
}

main() {
  [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage && exit 0

  local capture_script="${ROOT}/scripts/reimage/inventory-capture.sh"

  [[ -x "${capture_script}" ]] && pass "inventory-capture.sh executable" \
    || warn "run chmod +x scripts/reimage/inventory-capture.sh"

  local prod_key="${ROOT}/scripts/vm/keys/prod_id_ed25519"
  [[ -f "${prod_key}" ]] && pass "production SSH key present" \
    || warn "missing ${prod_key} — run ./scripts/vm/keys-ensure.sh -i production"

  local prod_hosts="${ROOT}/inventories/production/hosts.yml"
  if [[ -f "${prod_hosts}" ]] && command -v ansible-inventory >/dev/null 2>&1; then
    ensure_venv_path "${ROOT}" 2>/dev/null || true
    local kif_ip kvm_ip
    kif_ip="$(ansible-inventory -i "${prod_hosts}" --host kif.home.2123studios.com 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ansible_host',''))" 2>/dev/null || true)"
    kvm_ip="$(ansible-inventory -i "${prod_hosts}" --host kvm01.home.2123studios.com 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('ansible_host',''))" 2>/dev/null || true)"
    [[ -n "${kif_ip}" ]] && ssh_probe "misnow1" "${prod_key}" "${kif_ip}" && remote_df_archive "misnow1" "${prod_key}" "${kif_ip}" || true
    [[ -n "${kvm_ip}" ]] && ssh_probe "misnow1" "${prod_key}" "${kvm_ip}" || true
  else
    warn "inventories/production/hosts.yml not found — skipping host SSH probes"
  fi

  if [[ "${WARNINGS}" -gt 0 ]]; then
    log_warn "preflight-check.sh finished with ${WARNINGS} warning(s)"
    exit 1
  fi
  log_info "preflight-check.sh passed"
}

main "$@"
