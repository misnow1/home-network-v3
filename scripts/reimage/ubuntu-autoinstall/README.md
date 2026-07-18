# Ubuntu autoinstall USB (nocloud)

Generate **user-data** / **meta-data** for Ubuntu Server 24.04 autoinstall. Automates
**ansible** user, **SSH authorized key**, and **sudo**; **storage stays manual** via
`interactive-sections: [storage]` so you can preserve LVs such as `cs/libvirt` on kvm01.

## Prerequisites

```bash
./scripts/vm/keys-ensure.sh -i production
```

## Build CIDATA files

Mount or create a VFAT partition labeled **CIDATA** on the installer USB, then:

```bash
./scripts/reimage/ubuntu-autoinstall/build-user-data.sh \
  --profile kvm01 \
  --hostname kvm01 \
  --libvirt-uuid d1b341d8-01bd-4ecb-8545-8bc441826a59 \
  -o /mnt/CIDATA
```

Omit `--libvirt-uuid` if you mount `/var/lib/libvirt` in the installer UI or rely on
Ansible `hypervisor.yml` only.

## Install flow

1. Write Ubuntu 24.04 **Server** ISO to USB.
2. Add **CIDATA** partition with generated `user-data` and `meta-data`.
3. Boot kvm01 from USB; complete **storage** interactively (format `cs/ubuntu-root` only;
   do **not** format `cs/libvirt`).
4. Reboot manually when the installer finishes (interactive autoinstall may not auto-reboot).
5. Verify: `ssh -i scripts/vm/keys/prod_id_ed25519 ansible@<ip> hostname`

See [hypervisor-runbook.md](../../../docs/hypervisor-runbook.md) and
[scripts/reimage/](../) for kvm01 autoinstall helpers.
