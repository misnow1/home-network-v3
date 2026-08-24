#!/usr/bin/env bash
# Managed by Ansible (roles/backup). Do not edit on the host.
# Offline Samba AD backup on the source DC. Restarts directory services on every exit.
# Paths and timeout come from the config file below, so this script stays free of
# templating and can use bash sigils such as ${#array[@]} safely.
# Usage: backup-ad-offline.sh [run|dump|purge]
set -uo pipefail

CONFIG="${BACKUP_AD_OFFLINE_CONFIG:-/etc/default/backup-ad-offline}"
if [ ! -r "$CONFIG" ]; then
  echo "ERROR: missing config $CONFIG" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG"

: "${WORKDIR:?WORKDIR not set in $CONFIG}"
: "${LATEST:?LATEST not set in $CONFIG}"
: "${TIMEOUT_SEC:?TIMEOUT_SEC not set in $CONFIG}"

CMD="${1:-run}"

dump_artifact() {
  [ -f "$LATEST" ] || { echo "ERROR: no artifact at $LATEST" >&2; exit 1; }
  tar -tjf "$LATEST" >/dev/null
  cat "$LATEST"
}

purge_artifact() {
  rm -f "$LATEST"
}

run_backup() {
  mkdir -p "$WORKDIR"
  rm -f "$WORKDIR"/*.tar.bz2 "$WORKDIR"/*.tar 2>/dev/null || true

  restart_ad() {
    systemctl start samba-ad-dc.service || true
    systemctl start named.service || true
  }
  trap restart_ad EXIT

  systemctl stop named.service || true
  systemctl stop samba-ad-dc.service

  timeout --signal=TERM --kill-after=60 "${TIMEOUT_SEC}" \
    samba-tool domain backup offline --targetdir="$WORKDIR"

  shopt -s nullglob
  artifacts=("$WORKDIR"/*.tar.bz2 "$WORKDIR"/*.tar)
  if [ "${#artifacts[@]}" -lt 1 ]; then
    echo "ERROR: samba-tool produced no tarball in $WORKDIR" >&2
    exit 1
  fi

  cp -f "${artifacts[0]}" "${LATEST}.tmp"
  chmod 0600 "${LATEST}.tmp"
  mv -f "${LATEST}.tmp" "$LATEST"
  echo "Wrote $LATEST ($(stat -c %s "$LATEST") bytes)"
}

case "$CMD" in
  run) run_backup ;;
  dump) dump_artifact ;;
  purge) purge_artifact ;;
  *)
    echo "Usage: $0 [run|dump|purge]" >&2
    exit 2
    ;;
esac
