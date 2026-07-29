# NFS server runbook (Slice 15+)

Kerberos NFS server on **kif** (or other `fileservers` hosts): exports `/home`,
`/media`, and `/archive` for domain-joined Linux clients with **`sec=krb5i` only**.

**Playbook:** [`playbooks/nfs-server.yml`](../playbooks/nfs-server.yml)  
**Role:** [`roles/nfs_server`](../roles/nfs_server/)  
**Client counterpart:** [`docs/nfs-client-runbook.md`](nfs-client-runbook.md)

## Prerequisites

1. [`playbooks/baseline.yml`](../playbooks/baseline.yml)
2. **Winbind AD join** on the NFS host — kif is joined via hand-maintained winbind
   (not `domain_join`/sssd). Verify with `net ads testjoin`.
3. Export paths exist on disk: `/home`, `/media`, `/archive`
4. Vault join credentials when `nfs_server_manage_spn: true` (default):
   `vault_ad_join_user`, `vault_ad_join_password`

Samba shares on the same paths are Ansible-managed via `fileserver.yml` when
`fileserver_samba_enabled: true` — see [fileserver-runbook.md](fileserver-runbook.md).

## Enable

```yaml
# inventories/production/host_vars/kif.home.2123studios.com/vars.yml
nfs_server_enabled: true
nfs_server_client_networks:
  - 192.168.1.0/24
```

Optional overrides: `nfs_server_exports`, `nfs_server_export_sec`,
`nfs_server_manage_spn: false` (SPN/keytab already correct).

## Production apply (kif)

Run **before** client validation on kvm01 (`nfs-client.yml`).

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
HOST=kif.home.2123studios.com

${PROD} playbooks/baseline.yml --limit "${HOST}"
${PROD} playbooks/nfs-server.yml --limit "${HOST}"
```

If migrating from hand-maintained exports, capture the current `/etc/exports` first
(reimage staging or `sudo cp /etc/exports /root/exports.pre-ansible`). The role
**replaces** `/etc/exports` — do **not** restore `/var/lib/nfs/etab` from an old OS;
use `exportfs -rav` after converge.

Re-run twice — second run must report `changed=0` (idempotency proof for ROADMAP 15+).

## What the role delivers

| Component | Purpose |
|---|---|
| **`/etc/exports`** | `/home`, `/media`, `/archive` with `sec=krb5i`, `root_squash`, stable `fsid` |
| **`NEED_SVCGSSD=yes`** | Server-side GSS for Kerberos mounts |
| **NFS SPNs** | `nfs/<fqdn>` and `nfs/<HOST>` on the computer object + keytab |
| **`rpc-svcgssd` + `nfs-server`** | GSS-aware NFSv4.1 server |

Default export lines (192.168.1.0/24):

```text
/home   192.168.1.0/24(rw,async,root_squash,sec=krb5i,fsid=1)
/media  192.168.1.0/24(rw,async,root_squash,sec=krb5i,fsid=2)
/archive 192.168.1.0/24(rw,async,root_squash,sec=krb5i,fsid=3)
```

## Validation checklist

On **kif**:

- [ ] `net ads testjoin` succeeds
- [ ] `sudo exportfs -v` shows all three paths with `sec=krb5i`
- [ ] `sudo klist -ke /etc/krb5.keytab | grep -i nfs`
- [ ] `systemctl is-active rpc-svcgssd nfs-server`
- [ ] `grep NEED_SVCGSSD /etc/default/nfs-kernel-server` → `yes`

On a **client** (e.g. kvm01) after `nfs-client.yml`:

- [ ] AD user with `klist`: `ls /archive`, `ls /media`, `cd ~` (autofs)

## Troubleshooting

Most client-side symptoms are documented in [nfs-client-runbook.md](nfs-client-runbook.md).
Server-side checks:

### `Included profile directory could not be read` (krb5)

`/etc/krb5.conf` references `includedir /etc/krb5.conf.d/` but the directory is
missing (RHEL→Ubuntu leftover). The role creates it when detected; or manually:

```bash
sudo mkdir -p /etc/krb5.conf.d
```

### `Cannot contact any KDC` / kinit hits the legacy `pdc`

`dns_lookup_kdc = true` is ignored when `[realms]` still pins
`kdc = pdc.home.2123studios.com`. The retired PDC answers ICMP/SSH but is not a
KDC, so machine `kinit` and NFS GSS fail even though `dc1`/`dc2` SRV records are
healthy.

The role strips hostnames in `nfs_server_krb5_retired_kdcs` (default: `pdc…`).
Verify after converge:

```bash
grep -E '^\s*(kdc|admin_server)\s*=' /etc/krb5.conf   # no pdc lines
KRB5_TRACE=/dev/stderr kinit -k -t /etc/krb5.keytab 'KIF$@HOME.2123STUDIOS.COM'
# expect: Resolving hostname dc1… / dc2…
```

### `access denied by server` with correct export ACL

Server GSS layer failure — see nfs-client runbook SPN/keytab/`rpc-svcgssd` section.
With `nfs_server_manage_spn: true`, the role registers SPNs and runs
`net ads keytab add nfs`.

### Rollback

```bash
sudo cp /root/exports.pre-ansible /etc/exports
sudo exportfs -rav
sudo systemctl restart rpc-svcgssd nfs-server
```

## Related

- [nfs-client-runbook.md](nfs-client-runbook.md) — kvm01 mounts and troubleshooting
- [fileserver-runbook.md](fileserver-runbook.md) — kif Samba multi-share + wsdd
- [production-runbook.md](production-runbook.md) — fleet apply order
