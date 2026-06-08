# Backup runbook (lab)

Slice 7 configures **restic** backups on hypervisors with a declarative **backup scope
manifest** and an automated restore drill in integration tests.

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

Scope is declared in `inventories/lab/host_vars/hv01.lab.test/vars.yml`:

- `backup_docker_volumes` — volume name + `backup_class`
- `backup_libvirt_vms` — optional VM disk policies (`snapshot`, `offline_copy`, `exclude`)

## Manual backup test

On a converged hypervisor:

```bash
docker volume create lab_backup_test
docker run --rm -v lab_backup_test:/data alpine sh -c 'echo test > /data/sample.txt'
/usr/local/bin/backup-docker.sh
restic -r /var/lib/restic/lab-backup snapshots
```

## Integration test

```bash
LAB_HOST=hv01.lab.test ./scripts/test-integration.sh
```

Provisions `hv01`, converges hypervisor + backup, seeds a docker volume, runs backup,
restores the latest snapshot, and verifies file integrity via sha256.

## Production notes

Lab uses a **local** restic repository. Production inventory templates and apply order
are documented in `docs/production-runbook.md`. SFTP/NAS repositories and systemd
timers remain a future enhancement.
