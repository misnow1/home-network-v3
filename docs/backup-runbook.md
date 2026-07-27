# Backup runbook (lab)

Slice 7 configures **restic** backups on hypervisors with a declarative **backup scope
manifest** and an automated restore drill in integration tests.

Slice 23 adds **scheduled backups**, **retention pruning**, and **offsite restic copy**
for production hypervisors (especially kif Docker workloads).

## Lab host

| Host | Role |
|---|---|
| `hv01.lab.test` | Hypervisor + local restic repo + docker volume backups |

## Prerequisites

- Slice 4 hypervisor stack (`hypervisor.yml`) — Docker required for restore drill
- Vault variable `vault_backup_repository_key` set in lab vault

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
| Local restic repo | `/var/lib/restic/lab-backup` |
| Scope manifest | `/etc/ansible-managed/backup_scope.yml` |
| Docker backup script | `/usr/local/bin/backup-docker.sh` |
| Scheduled wrapper (opt-in) | `/usr/local/bin/backup-run.sh` + `ansible-backup.timer` |

Scope is declared in `inventories/lab/host_vars/hv01.lab.test/vars.yml`:

- `backup_docker_volumes` — volume name + `backup_class`
- `backup_libvirt_vms` — optional VM disk policies (`snapshot`, `offline_copy`, `exclude`)

Scheduling variables (defaults off in lab):

| Variable | Default | Purpose |
|---|---|---|
| `backup_schedule_enabled` | `false` | Enable systemd timer |
| `backup_schedule_on_calendar` | `daily` | systemd `OnCalendar` expression |
| `backup_offsite_repository` | `""` | Second restic repo path |
| `backup_offsite_copy_enabled` | `false` | Run `restic copy` after backup |
| `backup_prune_enabled` | `true` | Apply retention after backup |

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

## Production

See also [edge-access-model.md](edge-access-model.md) — backups are the primary
ransomware recovery control for NFS/Samba/Docker data on kif.

### Inventory

1. Copy hypervisor group vars and kif host_vars examples.
2. Declare `backup_docker_volumes` matching `docker volume ls` on kif.
3. Enable scheduling and offsite copy on kif:

```yaml
backup_schedule_enabled: true
backup_schedule_on_calendar: "02:30"
backup_offsite_repository: /archive/restic/prod-backup-offsite
backup_offsite_copy_enabled: true
```

Primary repo: `/var/lib/restic/prod-backup` (local LV). Offsite mirror:
`/archive/restic/prod-backup-offsite` (archive disk tier on kif — separate from Docker
volumes but still on-host; copy to true air-gap media quarterly).

### Converge

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/backup.yml --limit kif.home.2123studios.com -e allow_production=true
```

### Verify timer

On kif after converge:

```bash
systemctl status ansible-backup.timer
systemctl list-timers ansible-backup.timer
journalctl -u ansible-backup.service -n 50
restic -r /var/lib/restic/prod-backup snapshots
restic -r /archive/restic/prod-backup-offsite snapshots
```

### Quarterly restore drill

1. Pick a non-production path or staging volume.
2. `restic restore latest --target /tmp/restic-restore-test --path <volume-path>`
3. Verify file contents (sha256 or spot-check).
4. Document date and result in your ops log.

### True 3-2-1 offsite (manual)

Automated copy to `/archive/restic/` is **on-host redundancy**, not air-gap. Periodically
copy the offsite repository to media unreachable from the LAN (external drive, cloud
object storage with immutability, or SFTP to a remote host). ROADMAP still tracks
SFTP/NAS backend automation for Slice 23+.

## Production notes (legacy)

Lab uses a **local** restic repository. Production inventory templates and apply order
are documented in `docs/production-runbook.md`.
