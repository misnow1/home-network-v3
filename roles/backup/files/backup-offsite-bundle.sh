#!/usr/bin/env bash
# Managed by Ansible (roles/backup). Do not edit on the host.
# Copy live restic snapshots (home, docker, AD, compose) plus Kopia trees onto
# a USB (or other) mount. Refuses to run if that path is not a mountpoint or
# shares a device with /archive.
# Usage: backup-offsite-bundle.sh
set -uo pipefail

CONFIG="${BACKUP_OFFSITE_BUNDLE_CONFIG:-/etc/default/backup-offsite-bundle}"
if [ ! -r "$CONFIG" ]; then
  echo "ERROR: missing config $CONFIG" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$CONFIG"

COMMON="${BACKUP_COMMON_SCRIPT:-/usr/local/lib/backup-common.sh}"
if [ ! -r "$COMMON" ]; then
  echo "ERROR: shared backup environment missing: $COMMON" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$COMMON"

: "${BUNDLE_MOUNT:?BUNDLE_MOUNT not set in $CONFIG}"
: "${BUNDLE_REPO:?BUNDLE_REPO not set in $CONFIG}"
: "${SOURCE_REPO:?SOURCE_REPO not set in $CONFIG}"
: "${BUNDLE_COPY_TAGS:?BUNDLE_COPY_TAGS not set in $CONFIG}"

export RESTIC_REPOSITORY="$BUNDLE_REPO"

mail_abort() {
  local reason="$1"
  local guidance="$2"
  backup_mail \
    "[ansible-backup-offsite-bundle] ABORTED on $(hostname -s)" \
    "Live offsite bundle aborted on $(hostname -s) at $(date -Iseconds).

Reason: ${reason}

${guidance}

Nothing was written to ${SOURCE_REPO}. Plug in the disk, mount it at ${BUNDLE_MOUNT},
then rerun:

  ${0}

See docs/backup-runbook.md (offsite live bundle)."
  echo "$reason" >&2
}

exec 9>/run/ansible-backup.lock
if ! flock -n 9; then
  mail_abort \
    "another ansible-backup run holds /run/ansible-backup.lock" \
    "Wait for ansible-backup.service to finish (after ~02:40), then rerun."
  exit 1
fi

if [ ! -d "$BUNDLE_MOUNT" ]; then
  mail_abort \
    "mount directory missing: $BUNDLE_MOUNT" \
    "Create the mountpoint (Ansible does this) and attach the USB disk."
  exit 1
fi

if ! mountpoint -q "$BUNDLE_MOUNT"; then
  mail_abort \
    "$BUNDLE_MOUNT is not a mountpoint (disk not plugged in, or mounted elsewhere)." \
    "Find the device (lsblk), then: mount /dev/sdX1 ${BUNDLE_MOUNT}"
  exit 1
fi

if [ -d /archive ]; then
  archive_dev="$(stat -c %d /archive)"
  bundle_dev="$(stat -c %d "$BUNDLE_MOUNT")"
  if [ "$archive_dev" = "$bundle_dev" ]; then
    mail_abort \
      "$BUNDLE_MOUNT is on the same device as /archive — refusing to fake an offsite copy." \
      "Mount removable media at ${BUNDLE_MOUNT}. Do not point this job at RAID6."
    exit 1
  fi
fi

mkdir -p "$BUNDLE_REPO"
chmod 0700 "$BUNDLE_REPO"

# restic cat config exits 10 when the repo is uninitialized.
if ! restic cat config >/dev/null 2>&1; then
  echo "$(date -Iseconds) | bundle | initializing restic repository $BUNDLE_REPO"
  if ! restic init; then
    mail_abort \
      "restic init failed at $BUNDLE_REPO" \
      "Check disk health, LUKS unlock, and ${RESTIC_PASSWORD_FILE}."
    exit 1
  fi
fi

if ! backup_require_repo_space "offsite live bundle"; then
  exit 1
fi

status=0
for tag in $BUNDLE_COPY_TAGS; do
  echo "$(date -Iseconds) | bundle | restic copy --tag ${tag}"
  if ! restic -r "$BUNDLE_REPO" --password-file "$RESTIC_PASSWORD_FILE" \
    copy --from-repo "$SOURCE_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" \
    --tag "$tag"; then
    echo "$(date -Iseconds) | bundle | ERROR: copy failed for tag ${tag}" >&2
    status=1
  fi
done

KOPIA_LIST="${BUNDLE_KOPIA_LIST:-/etc/ansible-managed/backup-offsite-kopia.paths}"
if [ -f "$KOPIA_LIST" ]; then
  while IFS= read -r kpath || [ -n "$kpath" ]; do
    case "$kpath" in
      ''|\#*) continue ;;
    esac
    if [ ! -d "$kpath" ]; then
      echo "$(date -Iseconds) | bundle | WARNING: kopia path missing, skipping: $kpath" >&2
      continue
    fi
    echo "$(date -Iseconds) | bundle | restic backup ${kpath} (kopia)"
    if ! restic backup "$kpath" --tag kopia --tag offsite-bundle --verbose; then
      echo "$(date -Iseconds) | bundle | ERROR: kopia backup failed: $kpath" >&2
      status=1
    fi
  done < "$KOPIA_LIST"
fi

if [ "$status" -eq 0 ] && [ "${BUNDLE_PRUNE_ENABLED:-false}" = "true" ]; then
  echo "$(date -Iseconds) | bundle | prune"
  if ! restic forget \
    --keep-daily "${BUNDLE_KEEP_DAILY:-7}" \
    --keep-weekly "${BUNDLE_KEEP_WEEKLY:-4}" \
    --keep-monthly "${BUNDLE_KEEP_MONTHLY:-6}" \
    --prune; then
    status=1
  fi
elif [ "$status" -ne 0 ]; then
  echo "$(date -Iseconds) | bundle | prune skipped because copy/backup failed" >&2
fi

if [ "$status" -ne 0 ]; then
  backup_mail \
    "[ansible-backup-offsite-bundle] FAILED on $(hostname -s)" \
    "Live offsite bundle failed on $(hostname -s) at $(date -Iseconds).
Check: journalctl -u ansible-backup-offsite-bundle.service -n 80
Bundle: $BUNDLE_REPO
Source: $SOURCE_REPO"
  exit 1
fi

echo "$(date -Iseconds) | bundle | complete at $BUNDLE_REPO"
exit 0
