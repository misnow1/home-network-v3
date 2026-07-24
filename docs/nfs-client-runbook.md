# NFS client runbook

Kerberos NFS client for domain-joined Ubuntu members mounting **kif** (or
`nfs_client_server`): autofs **`/home/%u`**, systemd automount for **`/archive`**
and **`/media`**.

**Playbook:** [`playbooks/nfs-client.yml`](../playbooks/nfs-client.yml)  
**Role:** [`roles/nfs_client`](../roles/nfs_client/)

## Prerequisites

1. [`playbooks/baseline.yml`](../playbooks/baseline.yml) — includes relocating
   **`ansible`** to **`/var/lib/ansible`** (local, not NFS).
2. [`playbooks/domain-join.yml`](../playbooks/domain-join.yml) — **required** for
   `sec=krb5i` and `rpc-gssd`.

**Not** for bastion — local homedirs only ([bastion-runbook.md](bastion-runbook.md)).

## Enable

```yaml
# inventories/production/group_vars/hypervisors/vars.yml
nfs_client_enabled: true
```

Optional overrides: `nfs_client_server`, `nfs_client_static_mounts`,
`nfs_client_homedir_autofs: false`.

## Production apply (kvm01)

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
HOST=kvm01.home.2123studios.com

${PROD} playbooks/baseline.yml --limit "${HOST}"
${PROD} playbooks/domain-join.yml --limit "${HOST}"
${PROD} playbooks/nfs-client.yml --limit "${HOST}"
${PROD} playbooks/hypervisor.yml --limit "${HOST}"
```

kif **exports** are managed by [`playbooks/nfs-server.yml`](../playbooks/nfs-server.yml)
when `nfs_server_enabled: true` — see [nfs-server-runbook.md](nfs-server-runbook.md).
Client config must match kif `/etc/exports` (`sec=krb5i`, paths).

## When kif is down

- **Boot:** `/archive` and `/media` use `nofail` + `x-systemd.automount` — boot
  should reach multi-user without kif.
- **Access:** `soft,timeo=600,retrans=2` on data mounts and autofs `/home` — I/O
  fails instead of hanging indefinitely (EIO risk during outages).

## Troubleshooting: `mount.nfs: Network is unreachable`

Symptom: `ping kif` (IPv4) works but the mount fails with `Network is
unreachable`. Cause: `kif` has a **stale `AAAA`** in AD DNS pointing at an old
ISP GUA prefix (e.g. `2600:...`) that the host no longer holds. `mount.nfs`
resolves the name, reaches for the dead IPv6 address, and errors before falling
back to IPv4.

The DDNS pipeline (`dhcp-ddns-hook → ddns-nsupdate → BIND`) publishes client
`AAAA` records from DHCPv6 leases; after an ISP prefix change the old records
become orphans. Diagnose and remove them:

```bash
dig +short kif.home.2123studios.com A       # LAN address, e.g. 192.168.1.152
dig +short kif.home.2123studios.com AAAA    # stale GUA if the mount fails

# On/against a DC (AD is multi-master; deleting on one replicates):
samba-tool dns delete dc1.home.2123studios.com home.2123studios.com \
  kif AAAA 2600:xxxx:xxxx:xxxx::xx -U Administrator
dig +short kif.home.2123studios.com AAAA    # must be empty
```

Check the other infra hosts for the same orphaned prefix
(`dig +short <host> AAAA`) and delete as needed. See
[dns-architecture.md](dns-architecture.md) ("Stale client AAAA after prefix
change") and [dc-runbook.md](dc-runbook.md) for replica join procedure
applied to the DCs.

## Troubleshooting: `mount.nfs: access denied by server`

The client reached kif but was refused. If the export ACL already allows the
client subnet and `sec` (check `sudo exportfs -v` on kif), the denial is at the
**server-side GSS layer** — kif can't accept the Kerberos context.

First confirm Kerberos even initializes on kif. If `klist`/`kinit` fail with
`Included profile directory could not be read while initializing krb5`, then
`/etc/krb5.conf` has an `includedir` pointing at a missing directory (a common
RHEL→Ubuntu reimage leftover — the `crypto-policies` `includedir /etc/krb5.conf.d/`
line). This breaks *all* krb5 on the host, so `rpc-svcgssd` dies and every
`krb5*` mount is denied. Create it:

```bash
sudo mkdir -p /etc/krb5.conf.d
sudo klist -ke /etc/krb5.keytab   # should now list principals
```

Then continue diagnosing on **kif**:

```bash
sudo exportfs -v                                   # subnet + sec=...krb5i... present?
sudo klist -ke /etc/krb5.keytab | grep -iE 'nfs/|host/'   # need nfs/<fqdn>
systemctl is-active gssproxy rpc-svcgssd            # one must be running
journalctl -u rpc-svcgssd -b --no-pager | tail -30 # why it failed
```

Isolate client vs server (on a failing client, e.g. kvm01):

```bash
# Export/routing OK if this succeeds:
sudo mount -t nfs -o vers=4.1,sec=sys kif.home.2123studios.com:/archive /mnt/t && sudo umount /mnt/t

# krb5 path — machine TGT then NFS service ticket for kif:
sudo kinit -k 'KVM01$@HOME.2123STUDIOS.COM'    # use client short name + $
sudo kvno nfs/kif.home.2123studios.com
```

If `kvno` fails with **Server not found in Kerberos database**, the **`nfs/` SPN is
missing on kif's AD computer object** (`KIF$`). A local `net ads keytab add nfs`
can populate `/etc/krb5.keytab` without registering the SPN — clients still cannot
get a ticket. On **kif**:

```bash
sudo net ads setspn list | grep -i nfs    # expect nfs/kif... and nfs/KIF
sudo net ads setspn add nfs/kif.home.2123studios.com -U Administrator
sudo net ads setspn add nfs/KIF -U Administrator
sudo net ads keytab add nfs -U Administrator
sudo modprobe rpcsec_gss_krb5
sudo systemctl restart rpc-svcgssd nfs-server
```

Re-test `kvno` from the client, then `mount ... sec=krb5i`.

kif's NFS/Kerberos server config is managed by the **`nfs_server` role** when
`nfs_server_enabled: true` — see [nfs-server-runbook.md](nfs-server-runbook.md).
After a kif reimage, run `nfs-server.yml` before any `krb5*` client mount can succeed.

## Troubleshooting: `Stale file handle` with `sec=krb5*`

Symptom: `sec=sys` mounts and `ls` work; `sec=krb5`, `krb5i`, or `krb5p` mount
without error but `ls` fails with **Stale file handle**. Often seen when testing
as the local **`ansible`** user (uid 1000, not in AD).

Kerberos NFS ties data RPCs to the **calling user's** Kerberos credentials.
`rpc-gssd` upcalls with that uid; if there is no ticket (e.g. `FILE:/tmp/krb5cc_1000`
missing), gssd returns `GSS_S_NO_CRED` and the client surfaces ESTALE.

Validate as an **AD user** with a TGT (or as root for machine-cred checks):

```bash
kinit your_ad_user@HOME.2123STUDIOS.COM
klist
ls /media /archive
ls ~your_ad_user    # autofs /home
```

For playbook-driven mounts, Ansible uses **root** (machine credentials). A green
`nfs-client.yml` does not prove an unprivileged local account can read krb5 mounts.

Debug: `sudo systemctl stop rpc-gssd` then `sudo rpc.gssd -f -vvv` in another
session while reproducing `ls`.

SSH login with NFS homedirs (cloud-init password lockout, pubkey on NFS, VPN without
client `kinit`): see [domain-join-runbook.md](domain-join-runbook.md) — enable
`domain_member_sshd_enabled` on hypervisors. AD user pubkey provisioning:
[ad-ssh-public-keys.md](ad-ssh-public-keys.md).

## Validation checklist

- [ ] `systemctl is-active autofs rpc-gssd`
- [ ] `cat /etc/auto.master.d/home-nfs.autofs` and `/etc/auto.home`
- [ ] `grep archive /etc/fstab` shows `nofail` and `x-systemd.automount`
- [ ] kif up: **AD user** (not local `ansible`) with `klist`: `cd ~` mounts homedir;
      `ls /archive` and `ls /media` list exports
- [ ] kif down: reboot kvm01, `ansible` SSH works; `timeout 10 ls /archive` fails quickly

## Related

- [hypervisor-runbook.md](hypervisor-runbook.md) — production hypervisor converge
- [scripts/reimage/ubuntu-autoinstall/README.md](../scripts/reimage/ubuntu-autoinstall/README.md) — autoinstall USB
