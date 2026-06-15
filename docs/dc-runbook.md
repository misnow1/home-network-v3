# Samba AD DC runbook (Slice 2)

High-impact playbooks for lab domain controller provisioning on Ubuntu 24.04 with
BIND9_DLZ DNS backend.

## Lab integration (automated)

```bash
./scripts/test-integration.sh
```

Default host is `dc01.lab.test` — creates VM, bootstraps AD, converges, verifies, tears down.

Override for Slice 1 regression:

```bash
LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

## Manual lab workflow

```bash
./scripts/lab/vm-create.sh dc01.lab.test
./scripts/lab/wait-ssh.sh dc01.lab.test

ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook tests/integration/test_dc_converged.yml --limit dc01.lab.test

./scripts/lab/vm-destroy.sh dc01.lab.test
```

Re-run `dc-converge.yml` twice — second run must report `changed=0`.

## Prerequisites

1. Lab vault contains `vault_samba_admin_password` (AD complexity requirements apply).
2. `dc01.lab.test` is in both `lab` and `dc` inventory groups.
3. `linux_baseline` runs inside `dc-bootstrap.yml` before Samba provision (chrony first).

## Production break-glass

`dc-bootstrap.yml` and `dc-restore.yml` refuse non-lab inventory unless explicitly opted in:

```bash
# Greenfield only
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-bootstrap.yml -e allow_production=true --limit dc1.example.home

# AD migration — preserves existing domain DB
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-restore.yml -e allow_production=true \
  -e samba_dc_backup_archive=backups/home-ad-backup.tar.bz2 \
  --limit dc1.home.2123studios.com
```

**Warning:** Bootstrap creates a new domain. Restore migrates an existing backup.
Only use break-glass with a documented recovery plan. Normal production updates
use `dc-converge.yml` after initial bootstrap or restore.

See **[migration-runbook.md](migration-runbook.md)** for the full AD migration procedure.

## What bootstrap does (greenfield)

1. Safety asserts (lab inventory / allow_production)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Masks conflicting services (`smbd`, `systemd-resolved`, etc.)
5. `samba-tool domain provision` with `BIND9_DLZ` and RFC2307 (once — guarded by `sam.ldb`)
6. Configures BIND DLZ, AppArmor, starts `named` and `samba-ad-dc`
7. Copies generated `krb5.conf`

## What restore does (migration)

Used when migrating from an existing Samba AD DC — see [migration-runbook.md](migration-runbook.md).

1. Same safety asserts as bootstrap (`allow_production`)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Masks conflicting services
5. `samba-tool domain backup restore` from tarball (once — guarded by `sam.ldb` absence)
6. Writes restore marker to block accidental greenfield bootstrap
7. Configures BIND DLZ via shared `dns_bind_dlz.yml` tasks

Pass the backup path at runtime:

```bash
-e samba_dc_backup_archive=backups/home-ad-backup.tar
```

Set `samba_dc_migration_host: true` in production `group_vars/dc/vars.yml` on dc1.

## What converge does

1. Ensures `samba-ad-dc` and `named` are running
2. Refreshes `/etc/krb5.conf`
3. Extends chrony for MS-SNTP signing to domain members

## Tags

| Tag | Playbook | Purpose |
|---|---|---|
| `samba_packages` | dc-bootstrap, dc-restore | Package install only |
| `samba_provision` | dc-bootstrap | Domain provision + samba-ad-dc |
| `samba_restore` | dc-restore | Domain restore from backup |
| `samba_dns` | dc-bootstrap, dc-restore | BIND9 DLZ + AppArmor |
| `samba_kerberos` | dc-bootstrap, dc-restore | krb5.conf copy |
| `samba_converge` | dc-converge | Ongoing idempotent config |

See [docs/dns-architecture.md](dns-architecture.md) for DNS design and deferred DDNS work.
