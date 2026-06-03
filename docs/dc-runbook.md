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

`dc-bootstrap.yml` refuses non-lab inventory unless explicitly opted in:

```bash
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-bootstrap.yml -e allow_production=true --limit dc.example.home
```

**Warning:** Bootstrap is destructive on first run. Only use break-glass with a documented
recovery plan. Normal production updates use `dc-converge.yml` after initial bootstrap.

## What bootstrap does

1. Safety asserts (lab inventory / allow_production)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Masks conflicting services (`smbd`, `systemd-resolved`, etc.)
5. `samba-tool domain provision` with `BIND9_DLZ` and RFC2307 (once — guarded by `sam.ldb`)
6. Configures BIND DLZ, AppArmor, starts `named` and `samba-ad-dc`
7. Copies generated `krb5.conf`

## What converge does

1. Ensures `samba-ad-dc` and `named` are running
2. Refreshes `/etc/krb5.conf`
3. Extends chrony for MS-SNTP signing to domain members

## Tags

| Tag | Playbook | Purpose |
|---|---|---|
| `samba_packages` | dc-bootstrap | Package install only |
| `samba_provision` | dc-bootstrap | Domain provision + samba-ad-dc |
| `samba_dns` | dc-bootstrap | BIND9 DLZ + AppArmor |
| `samba_kerberos` | dc-bootstrap | krb5.conf copy |
| `samba_converge` | dc-converge | Ongoing idempotent config |

See [docs/dns-architecture.md](dns-architecture.md) for DNS design and deferred DDNS work.
