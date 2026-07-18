# Samba AD DC runbook (Slice 2)

High-impact playbooks for lab domain controller provisioning on Ubuntu 24.04 with
BIND9_DLZ DNS backend.

See [software.md](software.md) for the full package list (baseline + DC-specific tools
such as `ldb-tools`, `tcpdump`, `nmap`).

## Lab integration (automated)

```bash
./scripts/test-integration.sh
```

Default host is `dc01.lab.test` — creates VM, bootstraps AD, converges, verifies, tears down.

Slice 13 replica integration (two DCs — longer; opt-in locally, nightly in CI):

```bash
INTEGRATION_SLICE=dc_replica ./scripts/test-integration.sh
```

GitHub Actions workflow `Test Integration DC Replica` runs the same test on the kvm01
self-hosted runner (nightly schedule + manual `workflow_dispatch`).

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

### Manual lab workflow — replica DC (Slice 13)

Requires a bootstrapped `dc01.lab.test` first. `dc02` uses
`Default-First-Site-Name` (greenfield bootstrap site) — see
`inventories/lab/host_vars/dc02.lab.test/vars.yml`.

```bash
./scripts/lab/vm-create.sh dc02.lab.test
./scripts/lab/wait-ssh.sh dc02.lab.test

ansible-playbook playbooks/dc-replica-join.yml --limit dc02.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc
ansible-playbook tests/integration/test_dc_replica_converged.yml --limit dc

./scripts/lab/vm-destroy.sh dc02.lab.test
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

# AD migration — replica join (preferred, live legacy DC)
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-replica-join.yml -e allow_production=true \
  --limit dc1.home.2123studios.com

# AD migration — offline backup restore (fallback)
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-restore.yml -e allow_production=true \
  -e samba_dc_backup_archive=backups/home-ad-backup.tar.bz2 \
  --limit dc1.home.2123studios.com
```

**Warning:** Bootstrap creates a new domain. Replica join and restore migrate an
existing domain. Only use break-glass with a documented recovery plan. Normal
production updates use `dc-converge.yml` after initial bootstrap, replica join,
or restore.

See **[dc-runbook.md](dc-runbook.md)** for replica join, restore, and production break-glass.

## What bootstrap does (greenfield)

1. Safety asserts (lab inventory / allow_production)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Masks conflicting services (`smbd`, `systemd-resolved`, etc.)
5. `samba-tool domain provision` with `BIND9_DLZ` and RFC2307 (once — guarded by `sam.ldb`)
6. Configures BIND DLZ, AppArmor, starts `named` and `samba-ad-dc`
7. Copies generated `krb5.conf`

## What replica join does

Used when joining a new DC to an **existing** online domain.

1. Same safety asserts as bootstrap (`allow_production`)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Points resolver at legacy DC; runs `samba-tool domain join` as DC with `BIND9_DLZ`
5. Writes replica join marker to block accidental greenfield bootstrap
6. Configures BIND DLZ via shared `dns_bind_dlz.yml` tasks

Requires in `group_vars/dc/vars.yml`:

```yaml
samba_dc_migration_mode: replica
samba_dc_join_server: dc1.home.2123studios.com
samba_dc_join_nameservers:
  - 192.168.1.10
samba_dc_join_site: FerryCrossing
```

Before join, create AD sites — see [ad-sites.md](ad-sites.md) (FerryCrossing /
Woodbine / Swanhollow).

## What restore does (offline fallback)

Used when no live peer DC is available and you have a backup tarball.

1. Same safety asserts as bootstrap (`allow_production`)
2. `linux_baseline` (packages, hostname, chrony)
3. Installs `samba-ad-dc`, BIND9, supporting packages
4. Masks conflicting services
5. `samba-tool domain backup restore` from tarball (once — guarded by `sam.ldb` absence)
6. Writes restore marker to block accidental greenfield bootstrap
7. Configures BIND DLZ via shared `dns_bind_dlz.yml` tasks

Pass the backup path at runtime and set `samba_dc_migration_mode: restore`:

```bash
-e samba_dc_backup_archive=backups/home-ad-backup.tar
```

Set `samba_dc_migration_host: true` in production `group_vars/dc/vars.yml` on dc1.

## What converge does

1. Ensures `samba-ad-dc` and `named` are running
2. Refreshes `/etc/krb5.conf`
3. Restricts Samba to the primary LAN NIC for DNS self-registration (see
   [dns-architecture.md](dns-architecture.md#dc-hostname-registration-aaaa))
4. Deploys BIND options (`named.conf.options`) with estate-wide query ACLs from
   `dc_trusted_networks` / `samba_dc_dns_allowed_networks` — identical on **every**
   host in the `dc` group (**re-applied every converge**, not only at bootstrap)
5. Extends chrony for MS-SNTP signing (`dc_ntp_allow_cidr` — often narrower than DNS)
6. Optionally configures a **local operator SSH account** (see below)

### Group vars vs host vars (all DCs)

| Variable | Where | Purpose |
|---|---|---|
| `dc_trusted_networks` | `group_vars/dc/vars.yml` | BIND allow-query/recursion CIDRs (all DCs) |
| `samba_dc_dns_allowed_networks` | group (default: above) | Templated into BIND |
| `dc_ntp_allow_cidr` | group | chrony MS-SNTP allow (e.g. VLAN 1 only) |
| `samba_dc_join_site`, reverse zones | `host_vars/<dc>/` | Per-DC join site and local reverse zone |

After any ACL or BIND template change, converge **all** DCs:

```bash
ansible-playbook playbooks/dc-converge.yml --limit dc
# production:
./scripts/prod-run.sh --confirm-production -- playbooks/dc-converge.yml --limit dc
```

See [dns-architecture.md](dns-architecture.md#production--trusted-networks-and-bind-acls).

### Operator SSH (local break-glass)

Domain members use **domain login** via SSSD or winbind — see
[domain-join-runbook.md](domain-join-runbook.md) and
[fileserver-runbook.md](fileserver-runbook.md).

On a Samba AD DC, cloud-init creates only the `ansible` user for automation. The DC does
**not** run `domain_join` or the file-server winbind+PAM stack, but Ubuntu's Samba AD DC
packages still wire **libnss_winbind** into `/etc/nsswitch.conf`. With `samba-ad-dc`
running, domain users (e.g. `misnow1`) resolve via NSS — often as `HOME\misnow1` with
Samba's DC idmap range (e.g. `uid=3000013`), **not** the RFC2307 `uidNumber` members
read via SSSD (`ldap_id_mapping = false`). The repo **masks** the standalone `winbindd`
unit (see `roles/samba_dc/tasks/bootstrap.yml`) to avoid conflicting with `samba-ad-dc`;
that is not the same as "no domain users in NSS."

**Pubkey SSH** still needs a **local** `/etc/passwd` entry (or a homedir `authorized_keys`
for a domain user you authenticate another way). The operator tasks create that local
account by appending to `/etc/group` and `/etc/passwd` directly — `useradd` refuses names
that winbind already exposes via `getpwnam()`, even when absent from `files`.

For day-to-day admin SSH without the ansible key, enable a **local Unix account** in
`group_vars/dc/vars.yml` with the same `uidNumber` / `gidNumber` as your AD user on
joined hosts (keeps file ownership consistent on the DC filesystem):

```yaml
samba_dc_operator_enabled: true
samba_dc_operator_user: misnow1
samba_dc_operator_uid: <uidNumber from getent passwd on a member>
samba_dc_operator_gid: <gidNumber from getent passwd on a member>
samba_dc_operator_ssh_keys:
  - "ssh-ed25519 AAAA... you@laptop"
```

Copy the example from
`inventories/production/group_vars/dc/vars.yml.example`. Public keys are not secrets —
do not put them in vault.

After converge:

```bash
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-converge.yml --limit dc1.home.2123studios.com

ssh misnow1@<dc-ip>
id   # uid/gid should match RFC2307 IDs from members (e.g. 965557), not winbind's 3M range
```

Re-run converge is idempotent. Keep using `ansible` for automation (`prod-run.sh`,
integration tests, migration scripts).

`nsswitch.conf` lists `files` before `winbind`, so after converge `getent passwd misnow1`
should show the **local** account. `id misnow1` after SSH should match your configured
`samba_dc_operator_uid` / `gid`, not `HOME\misnow1` with uid `3000013`.

### Operator SSH troubleshooting

Symptoms after reboot or converge:

| Symptom | Likely cause |
|---|---|
| SSH accepts your key then **Connection closed** | Missing `/etc/shadow` row for the local operator (passwd field `x` with no shadow entry). PAM account checks fail after pubkey auth. |
| `su - misnow1` → **Authentication failure** | Expected — the account is pubkey-only (locked shadow password). From `ansible`, use `sudo -u misnow1 -i` instead. |

From `ansible@<dc>`:

```bash
getent passwd misnow1
sudo grep misnow1 /etc/passwd /etc/shadow
sudo journalctl -u ssh -n 30 --no-pager | grep -i misnow1
```

If `/etc/shadow` has no `misnow1` line, re-run `dc-converge.yml` (operator tasks add a locked
shadow entry) or break-glass append:

```bash
echo 'misnow1:!::0:99999:7:::' | sudo tee -a /etc/shadow
```

Then retry `ssh misnow1@<dc-ip>`.

## LDAP TLS (Slice 10)

Samba AD DC ships with a self-signed LDAP certificate by default. Tools that validate
TLS chains require a publicly trusted (production) or lab-local CA certificate.

Run after `dc-converge.yml`:

```bash
ansible-playbook playbooks/certbot.yml --limit dc01.lab.test

# production
./scripts/prod-run.sh --confirm-production -- \
  playbooks/certbot.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
```

See **[certbot-runbook.md](certbot-runbook.md)** for Dreamhost DNS-01, staging rollout,
renewal, and optional DDNS nginx TLS.

Quick verify (production — public CA):

```bash
openssl s_client -connect dc1.home.2123studios.com:636 \
  -servername dc1.home.2123studios.com </dev/null
ldapsearch -H ldaps://dc1.home.2123studios.com -x -b "" -s base namingContexts
```

## Tags

| Tag | Playbook | Purpose |
|---|---|---|
| `samba_packages` | dc-bootstrap, dc-replica-join, dc-restore | Package install only |
| `samba_provision` | dc-bootstrap, dc-replica-join | Domain provision/join + samba-ad-dc |
| `samba_replica_join` | dc-replica-join | Domain join as replica DC |
| `samba_restore` | dc-restore | Domain restore from backup |
| `samba_dns` | dc-bootstrap, dc-replica-join, dc-restore | BIND9 DLZ + AppArmor |
| `samba_kerberos` | dc-bootstrap, dc-replica-join, dc-restore | krb5.conf copy |
| `samba_converge` | dc-converge | Ongoing idempotent config |

See [docs/dns-architecture.md](dns-architecture.md) for DNS design and DDNS integration.
