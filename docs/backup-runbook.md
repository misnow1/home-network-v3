# Backup runbook

Slice 7 configures **restic** backups on hypervisors with a declarative **backup scope
manifest** and an automated restore drill in integration tests.

Slice 23 adds **scheduled backups**, **host path backups**, **retention pruning**, and
optional `restic copy`. Production kif stores the **primary repo on the archive RAID6**
(`/archive/restic/prod-backup`). A second copy on the same array is **not** used;
true off-host remains ROADMAP Slice 23+.

## Lab host

| Host | Role |
|---|---|
| `hv01.lab.test` | Hypervisor + local restic repo + docker volume backups |

## Prerequisites

- Slice 4 hypervisor stack (`hypervisor.yml`) — Docker required for restore drill
- Vault variable `vault_backup_repository_key` set (keep a copy in 1Password)
- AD job: kif `ansible` user must SSH to dc1 (`backup_ad_ssh_identity` points at the
  prod VM key). That user needs passwordless sudo for `/usr/local/bin/backup-ad-offline.sh`
  and `tar`/`cat`/`rm` of the tarball. The orchestrator runs as root under systemd with
  `BatchMode=yes`, so the role seeds `/root/.ssh/known_hosts` from dc1's host key read
  over Ansible's own connection — no manual first-time `ssh` needed.

## Converge order

```bash
ansible-playbook playbooks/baseline.yml --limit hv01.lab.test
ansible-playbook playbooks/hypervisor.yml --limit hv01.lab.test
ansible-playbook playbooks/backup.yml --limit hv01.lab.test
```

## What Ansible configures

| Component | Path / detail |
|---|---|
| restic package | distro package |
| Repository password | `/root/.restic-password` (from vault) |
| Lab restic repo | `/var/lib/restic/lab-backup` |
| Production kif repo | `/archive/restic/prod-backup` |
| Scope manifest | `/etc/ansible-managed/backup_scope.yml` |
| Shared env + space guard | `/usr/local/lib/backup-common.sh` (sourced by every script) |
| restic cache | `/var/cache/restic` (`RESTIC_CACHE_DIR`; systemd sets no `HOME`) |
| Docker backup script | `/usr/local/bin/backup-docker.sh` |
| Path backup script | `/usr/local/bin/backup-paths.sh` |
| Scheduled wrapper (opt-in) | `/usr/local/bin/backup-run.sh` + `ansible-backup.timer` |
| AD orchestrator (kif, opt-in) | `/usr/local/bin/backup-ad.sh` + `ansible-backup-ad.timer` (01:15) |
| AD helper (dc1) | `/usr/local/bin/backup-ad-offline.sh` + `/etc/default/backup-ad-offline` |

Scope is declared in host_vars:

- `backup_docker_volumes` — volume name + `backup_class`
- `backup_host_paths` — filesystem paths + restic tags/excludes
- `backup_libvirt_vms` — optional VM disk policies (manifest only; no qcow2 job)

Scheduling variables (defaults off in lab):

| Variable | Default | Purpose |
|---|---|---|
| `backup_schedule_enabled` | `false` | Enable systemd timer |
| `backup_schedule_on_calendar` | `daily` | systemd `OnCalendar` expression |
| `backup_offsite_repository` | `""` | Second restic repo path |
| `backup_offsite_copy_enabled` | `false` | Run `restic copy` after backup |
| `backup_prune_enabled` | `true` | Apply retention after backup |
| `backup_min_free_percent` | `15` | Abort (and mail) when repo filesystem is this low |
| `backup_ad_enabled` | `false` | Kif AD orchestrator + timer |
| `backup_ad_source` | `false` | Deploy offline helper on that DC |

`backup-run.sh` fails the systemd unit if docker or path backups fail, skips prune/copy
on failure, and mails `root`. Judge health by **snapshot ages**, not a green timer.

## Manual backup test

On a converged hypervisor:

```bash
docker volume create lab_backup_test
docker run --rm -v lab_backup_test:/data alpine sh -c 'echo test > /data/sample.txt'
/usr/local/bin/backup-docker.sh
restic -r /var/lib/restic/lab-backup snapshots
```

Or run the full scheduled wrapper (includes prune):

```bash
/usr/local/bin/backup-run.sh
```

## Integration test

```bash
LAB_HOST=hv01.lab.test ./scripts/test-integration.sh
```

Provisions `hv01`, converges hypervisor + backup, seeds a docker volume, runs backup,
restores the latest snapshot, and verifies file integrity via sha256.

## Production (kif)

See also [edge-access-model.md](edge-access-model.md) — backups are the primary
ransomware recovery control for NFS/Samba/Docker data on kif.

### Inventory

kif host_vars (see `vars.yml.example`):

- Repo: `/archive/restic/prod-backup` (RAID6). `backup_offsite_copy_enabled: false`.
- Paths: `/home`, `/archive` (exclude `restic`, `*/kopia`, `pre-reimage-*`),
  `/media/software`, `/media/teslausb`, `/srv/docker`, `/var/backups/ad`.
- Docker named volumes for Guacamole/Paperless DBs (crash-consistent stop/start).
- Authelia Valkey/Plex/Transmission config live under `/srv/docker` bind mounts.
- KopiaUI on calculon2 writes `/archive/<user>/kopia/<hostname>` — restic excludes it.
- AD: `backup_ad_enabled: true` on kif; `backup_ad_source: true` on dc1.

### Converge

Store `vault_backup_repository_key` in 1Password before first `restic init`.

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/backup.yml --limit 'kif.home.2123studios.com:dc1.home.2123studios.com' \
  -e allow_production=true
```

(`backup.yml` does not assert `allow_production`; `prod-run.sh` is still required.)

After converge, run one AD backup so the 02:30 restic run has an artifact:

```bash
sudo /usr/local/bin/backup-ad.sh
```

First full restic of `/home` + `/archive` takes hours (measured 2026-08-21: `/home`
425 GiB in 1h05, `/archive` 1.85 TiB in 5h25). The unit timeout is 12h. Do not treat a
green timer as success — check snapshots.

### Capacity

The repository lives on the same 5 TB `/archive` volume it backs up, so usable repo
space is total minus `/archive`'s own data — roughly 3.1 TB. Current scope needs about
2.45 TB.

`/media/projects` (1.9 TB of video projects) does **not** fit and is excluded from this
repo. It is RAID6-protected but **not backed up**; it needs its own repository on
separate storage (tracked in [issue #54](https://github.com/misnow1/home-network-v3/issues/54)).
Video dedupes and compresses poorly, so restic will not rescue the math.

`backup_min_free_percent` (default 15) makes every backup script re-check free space
before each volume and each path. Below the threshold the run aborts, mails `root`, and
still runs `restic forget --prune`, since pruning is how space comes back. A backup can
therefore never be what fills the array.

Growing the scope means adding storage first. Check headroom with:

```bash
df -h /archive
sudo du -sh /archive/restic/prod-backup
```

### Verify

```bash
systemctl status ansible-backup.timer ansible-backup-ad.timer
systemctl list-timers 'ansible-backup*'
journalctl -u ansible-backup.service -n 50
journalctl -u ansible-backup-ad.service -n 50
sudo RESTIC_PASSWORD_FILE=/root/.restic-password restic -r /archive/restic/prod-backup snapshots
```

### Windows (KopiaUI)

Install is out of band. Repo layout: `\\kif\archive\<user>\kopia\<hostname>`
(example: `/archive/misnow1/kopia/calculon2`). Restore with KopiaUI, not restic.

### Quarterly restore drill

1. Pick a non-production path or staging volume.
2. `restic restore latest --target /tmp/restic-restore-test --path <source-path>`
3. Verify file contents (sha256 or spot-check).
4. Document date and result in your ops log.
5. AD restore is `playbooks/dc-restore.yml` from the staged tarball — **only on an
   isolated network** (a restored DC on the LAN is a rogue DC).

### True 3-2-1 offsite (manual)

The RAID6 restic repo is **on-host**. Periodically copy it to media unreachable from
the LAN. ROADMAP Slice 23+ tracks SFTP/object-storage automation.

## Nightly window (America/New_York)

| Time | What |
|---|---|
| 01:15 | `ansible-backup-ad.timer` — LDAP preflight dc2, offline backup dc1, stage on kif |
| 02:00 | dc2 unattended-upgrades reboot |
| 02:30 | `ansible-backup.timer` — restic paths/docker/prune (up to 30 min jitter) |
| 02:45 | dc1 unattended-upgrades reboot |
