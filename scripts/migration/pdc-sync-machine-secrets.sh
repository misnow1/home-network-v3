#!/usr/bin/env bash
# Sync secrets.ldb machine password from sam.ldb on the local Samba AD DC.
#
# Required after `samba-tool user setpassword 'PDC$'` — that updates AD (sam.ldb)
# but NOT secrets.ldb, so --machine-pass and samba_dnsupdate keep failing.
#
# Samba upstream tool: source4/scripting/devel/chgtdcpass (Andrew Bartlett).
#
#   sudo ./scripts/migration/pdc-sync-machine-secrets.sh --on-pdc
#   ./scripts/migration/pdc-sync-machine-secrets.sh --remote pdc.home.2123studios.com
#
# After sync, refresh keytabs and restart:
#   sudo rm -f /var/lib/samba/private/secrets.keytab /etc/krb5.keytab
#   sudo samba-tool domain exportkeytab /var/lib/samba/private/secrets.keytab
#   sudo samba-tool domain exportkeytab /etc/krb5.keytab
#   sudo systemctl restart samba
#   sudo net ads testjoin -P
set -euo pipefail

ON_PDC=0
REMOTE_HOST=""

usage() {
  grep '^#' "$0" | head -18 | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --on-pdc) ON_PDC=1; shift ;;
    --remote) REMOTE_HOST="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

sync_secrets() {
  [[ -f /var/lib/samba/private/sam.ldb ]] || {
    echo "sam.ldb not found — run on the Samba AD DC" >&2
    exit 1
  }

  python3 <<'PY'
import samba
from samba.auth import system_session
from samba import param
from samba.provision import find_provision_key_parameters
from samba.upgradehelpers import get_paths, get_ldbs, update_machine_account_password

lp = param.LoadParm()
lp.load('/etc/samba/smb.conf')
paths = get_paths(param, smbconf='/etc/samba/smb.conf')
session = system_session()
ldbs = get_ldbs(paths, None, session, lp)
ldbs.startTransactions()
names = find_provision_key_parameters(
    ldbs.sam, ldbs.secrets, ldbs.idmap, paths, '/etc/samba/smb.conf', lp)
update_machine_account_password(ldbs.sam, ldbs.secrets, names)
ldbs.groupedCommit()
print('secrets.ldb synced from sam.ldb')
PY

  local kvno
  kvno="$(ldbsearch -H /var/lib/samba/private/secrets.ldb \
    -b 'flatname=HOME,cn=Primary Domains' -s base msDS-KeyVersionNumber 2>/dev/null \
    | awk '/^msDS-KeyVersionNumber: / {print $2; exit}')"
  echo "secrets.ldb msDS-KeyVersionNumber=${kvno:-unknown}"

  if command -v net >/dev/null; then
    net ads testjoin -P
  fi
}

dispatch_remote() {
  local root key user
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  key="${PDC_AUDIT_SSH_KEY:-${root}/scripts/vm/keys/prod_id_ed25519}"
  user="${PDC_AUDIT_SSH_USER:-ansible}"
  ssh -i "${key}" -o StrictHostKeyChecking=no "${user}@${REMOTE_HOST}" \
    "sudo bash -s -- --on-pdc" <"$0"
}

if [[ -n "${REMOTE_HOST}" ]]; then
  dispatch_remote
elif [[ "${ON_PDC}" -eq 1 ]] || [[ -f /var/lib/samba/private/sam.ldb ]]; then
  sync_secrets
else
  echo "Use --on-pdc or --remote HOST" >&2
  exit 2
fi
