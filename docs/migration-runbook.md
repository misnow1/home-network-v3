# AD migration runbook

Migrate an existing **Samba Active Directory** domain to the Ansible-managed
**dc1/dc2** architecture while preserving users, groups, computer SIDs, and
passwords. This path uses **`samba-tool domain backup` / `restore`** — not
greenfield `dc-bootstrap.yml`.

**Domain:** `home.2123studios.com` (realm `HOME.2123STUDIOS.COM`, workgroup `HOME`)

**Do not run migration playbooks against production until your maintenance window.**
Use `./scripts/migration/preflight-check.sh` from the control node beforehand.

See also:

- [production-runbook.md](production-runbook.md) — wrapper and apply order
- [dc-runbook.md](dc-runbook.md) — bootstrap vs restore vs converge
- [run-order.md](run-order.md) — migration apply order
- [vault-schema.md](vault-schema.md) — production secrets

## Host roles in this migration

| Host | IP (example) | Treatment |
|---|---|---|
| **dc1** | `192.168.1.10` | Restore AD backup; rename from legacy `pdc` → `dc1` |
| **dc2** | (Phase 2) | Replica — not in initial cutover |
| **pdc** (old) | `192.168.1.2` | Stop after validation |
| **kvm01** | `192.168.1.21` | CentOS — manual DNS only (deferred) |
| **kif** | `192.168.1.152` | CentOS — manual DNS only (deferred) |
| **bastion** | TBD | Reprovision Ubuntu 24.04 → `baseline` + `domain-join` |
| Windows devices | few | Manual DNS to dc1 |

Production DC naming: **`dc1`**, **`dc2`**, … (`dc1.home.2123studios.com`). Retire
`pdc` / `sdc` hostnames.

---

## Pre-flight checklist

Run from the Ansible control node before the maintenance window:

```bash
./scripts/migration/preflight-check.sh
```

Manual checks:

1. **Samba version** — on old pdc and dc1, run `samba -V`. Ubuntu 24.04 Samba must
   be **≥** Fedora pdc version or restore may fail.
2. **Production inventory** — copy templates, fill real IPs/hostnames, create vault.
3. **SSH** — copy `group_vars/all/ansible.yml.example` → `ansible.yml` (user
   `ansible`, key `scripts/vm/keys/prod_id_ed25519`); verify with preflight or
   `ssh -i scripts/vm/keys/prod_id_ed25519 ansible@192.168.1.10`.
4. **Old pdc stays running** until dc1 is validated (rollback depends on this).
5. **Backup path** — plan where the tarball lives on the control node for
   `-e samba_dc_backup_archive=...`.
6. **kvm01 VM storage** — on kvm01, ensure libvirt network `external-default` is
   active, then run once: `./scripts/vm/keys-ensure.sh -i production` and
   `sudo ./scripts/vm/dirs-ensure.sh -i production` (see [lab-storage.md](lab-storage.md)).

Set in production `group_vars/dc/vars.yml`:

```yaml
samba_dc_migration_host: true
samba_dc_target_server_name: dc1
```

This blocks accidental `dc-bootstrap.yml` on the migration host.

---

## Phase 0 — Backup on old pdc (manual)

On the **existing** Fedora Samba DC (`pdc`, `192.168.1.2`):

```bash
# Creates a samba-backup-*.tar.bz2 file inside --targetdir (Samba 4.10+ syntax).
# Optional: stop samba-ad-dc first for extra safety during maintenance.
sudo systemctl stop samba-ad-dc
sudo samba-tool domain backup offline \
  --targetdir=/tmp/ad-backup-migration \
  --configfile=/etc/samba/smb.conf
sudo systemctl start samba-ad-dc
```

List the tarball Samba wrote under the target directory (name includes a UTC timestamp):

```bash
ls -la /tmp/ad-backup-migration/samba-backup-*.tar.bz2
sha256sum /tmp/ad-backup-migration/samba-backup-*.tar.bz2
```

Copy the **latest** backup to the Ansible control node, keeping the `.tar.bz2`
extension (or rename consistently — restore accepts bzip2-compressed tarballs):

```bash
mkdir -p backups
scp 'pdc.home.2123studios.com:/tmp/ad-backup-migration/samba-backup-2026-06-15T19-05-44.266616.tar.bz2' \
  ./backups/home-ad-backup.tar.bz2
sha256sum ./backups/home-ad-backup.tar.bz2
# expect: 4f3d1bbab1021ebbc0a48ecba2ea56260953783abbfbef15b3df77c7e17114d2
```

Verify tarball size (~9–10 MiB for this domain) and checksum before proceeding.

---

## Phase 1 — Restore and converge dc1

Production wrapper:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
```

| Step | Action |
|---|---|
| 1 | Restore AD on dc1 |
| 2 | Converge DC (BIND, dnsupdater, chrony) |
| 3 | Deploy DDNS API |
| 4 | Verify AD and DNS locally on dc1 |
| 5 | Cut over router DHCP/DNS |
| 6 | Manual DNS on CentOS hosts |

### Provision dc1 VM (new Ubuntu guest on kvm01)

If dc1 is not already running, create it on kvm01 against libvirt network
`external-default` (static IP from inventory):

```bash
./scripts/vm/vm-create.sh -i production dc1.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production dc1.home.2123studios.com
```

Host must have `vm_name`, `vm_ip`, and network defaults in production inventory
(see `hosts.yml.example` and [production-runbook.md](production-runbook.md)).

### Step 1 — Restore

```bash
${PROD} playbooks/dc-restore.yml -e allow_production=true \
  -e samba_dc_backup_archive=backups/home-ad-backup.tar.bz2 \
  --limit dc1.home.2123studios.com
```

The playbook:

- Installs Samba AD DC + BIND packages
- Restores the backup with `--newservername=DC1` and `--host-ip=192.168.1.10`
- Wires BIND9_DLZ and starts `named` + `samba-ad-dc`

### Step 2 — Converge

```bash
${PROD} playbooks/dc-converge.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
```

Creates reverse zone, `dnsupdater` service account, MS-SNTP chrony settings.

### Step 3 — DDNS API

```bash
${PROD} playbooks/ddns-api.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
```

### Step 4 — Verify on dc1

```bash
sudo samba-tool domain info 127.0.0.1
sudo samba-tool user list | head
sudo samba-tool fsmo show
dig @127.0.0.1 home.2123studios.com SOA +short
dig @127.0.0.1 -x 192.168.1.10 +short
kinit Administrator@HOME.2123STUDIOS.COM
```

Update DNS if the restored server still advertises as `pdc`:

```bash
# On dc1 — adjust host/DNS records as needed after restore
sudo samba-tool computer rename PDC DC1 --configfile=/etc/samba/smb.conf
# Or update A/PTR records via samba-tool dns ...
```

Confirm `dc1.home.2123studios.com` resolves to `192.168.1.10`.

### Step 5 — Router cutover (manual)

1. Set DHCP option 6 (DNS servers) to **`192.168.1.10`** only.
2. Install lease-driven DDNS hook — see [ddns-runbook.md](ddns-runbook.md):

```sh
# /etc/home-ddns.env (mode 0600, root-owned)
DDNS_UPDATE_URL="http://192.168.1.10:8765/ddns/v1/lease"
DDNS_BEARER_TOKEN="<vault_ddns_shared_secret>"
DDNS_DNS_DOMAIN="home.2123studios.com"
```

```conf
# dnsmasq
dhcp-script=/usr/local/sbin/dhcp-ddns-hook.sh
```

Copy `scripts/dhcp-ddns-hook.sh` to `/usr/local/sbin/dhcp-ddns-hook.sh`.

### Step 6 — CentOS deferred hosts (manual)

On **kvm01** and **kif**, point resolver at dc1 (computer accounts remain valid
after restore — same SIDs):

```bash
sudo tee /etc/resolv.conf <<'EOF'
nameserver 192.168.1.10
search home.2123studios.com
EOF
```

Verify:

```bash
getent passwd misnow1
su - misnow1   # or kinit + test login
```

If kif SSH hangs on NSS, flush winbind cache or reboot after DNS change — out of
Ansible scope for CentOS hosts.

---

## Phase 2 — Reprovision Ubuntu members

For hosts like **bastion-el9** → fresh **Ubuntu 24.04**:

1. Optionally leave the old domain before wipe (in-place reprovision only):

```bash
${PROD} playbooks/domain-leave.yml --limit bastion.home.2123studios.com
```

2. Reinstall Ubuntu 24.04 (cloud-init or manual).
3. Delete stale computer account in AD if hostname unchanged (`samba-tool computer delete ...` on dc1).
4. Converge with Ansible:

```bash
${PROD} playbooks/baseline.yml --limit bastion.home.2123studios.com
${PROD} playbooks/domain-join.yml --limit bastion.home.2123studios.com
${PROD} playbooks/ddns-client.yml --limit bastion.home.2123studios.com   # optional
```

---

## Phase 3 — Validation and decommission old pdc

Validation checklist:

- [ ] `kinit user@HOME.2123STUDIOS.COM` succeeds for domain users
- [ ] SSH to bastion with domain credentials
- [ ] `getent passwd` on kvm01/kif returns domain users
- [ ] DHCP clients receive dc1 as DNS
- [ ] DDNS hook creates A/PTR records (`dig` after lease renew)
- [ ] Windows clients resolve `home.2123studios.com` (manual DNS if needed)

When satisfied:

```bash
# On old pdc — only after dc1 is fully validated
sudo systemctl stop samba-ad-dc named
sudo systemctl disable samba-ad-dc named
```

Remove stale DNS forwarders pointing at `192.168.1.2`. Retire `pdc` hostname in
documentation and inventory.

---

## Phase 4 — dc2 replica (future maintenance window)

Not part of the initial migration. When ready:

1. Provision `dc2.home.2123studios.com` (Ubuntu 24.04, e.g. `192.168.1.11`).
2. Add to `dc` group in production inventory.
3. Implement `dc-replica-join.yml` (ROADMAP slice 13) — `samba-tool domain join DC`.
4. Optional: set `DDNS_UPDATE_URL_FALLBACK` on the router hook to dc2.
5. Transfer FSMO roles if required.

---

## Rollback

If restore or validation fails **before** router cutover:

1. Do not change DHCP/DNS on the router.
2. Stop services on dc1 if partially configured.
3. Old pdc continues serving the domain unchanged.

If failure **after** router cutover:

1. Re-point DHCP option 6 back to old pdc (`192.168.1.2`).
2. Restore `/etc/resolv.conf` on members to previous DNS servers.
3. Restart `samba-ad-dc` on old pdc if it was stopped.
4. Investigate restore logs on dc1 before retrying.

---

## Greenfield vs restore (decision table)

| Scenario | Playbook |
|---|---|
| New lab domain | `dc-bootstrap.yml` |
| New production domain (no existing AD) | `dc-bootstrap.yml` + `allow_production=true` |
| **Migrate existing Samba AD (this runbook)** | **`dc-restore.yml`** + `dc-converge.yml` |
| Ongoing DC config | `dc-converge.yml` |

**Never** run `dc-bootstrap.yml` against a host with `samba_dc_migration_host: true`
or an existing restore marker — the playbook refuses to run.

---

## Vault notes for migration

| Variable | Migration guidance |
|---|---|
| `vault_samba_admin_password` | Existing `Administrator` password (unchanged after restore) |
| `vault_ad_join_user` | Dedicated join account (create new or reuse existing) |
| `vault_dnsupdater_password` | New — `dc-converge` creates `dnsupdater` (retire legacy `dns-updater`) |
| `vault_ddns_shared_secret` | New bearer token for DDNS API |

See [vault-schema.md](vault-schema.md).
