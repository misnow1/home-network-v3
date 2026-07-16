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

kif **exports** remain manual until ROADMAP slice 15+; client config must match
kif `/etc/exports` (`sec=`, paths).

## When kif is down

- **Boot:** `/archive` and `/media` use `nofail` + `x-systemd.automount` — boot
  should reach multi-user without kif.
- **Access:** `soft,timeo=600,retrans=2` on data mounts and autofs `/home` — I/O
  fails instead of hanging indefinitely (EIO risk during outages).

## Validation checklist

- [ ] `systemctl is-active autofs rpc-gssd`
- [ ] `cat /etc/auto.master.d/home-nfs.autofs` and `/etc/auto.home`
- [ ] `grep archive /etc/fstab` shows `nofail` and `x-systemd.automount`
- [ ] kif up: AD user `cd ~` mounts homedir; `ls /archive` mounts export
- [ ] kif down: reboot kvm01, `ansible` SSH works; `timeout 10 ls /archive` fails quickly

## Related

- [kif-kvm01-reimage-runbook.md](kif-kvm01-reimage-runbook.md) — imaging and converge order
- [scripts/reimage/ubuntu-autoinstall/README.md](../scripts/reimage/ubuntu-autoinstall/README.md) — autoinstall USB
