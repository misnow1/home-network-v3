# Ubuntu autoinstall USB (nocloud)

Generate **user-data** / **meta-data** for Ubuntu Server 24.04 autoinstall.

Two builders:

| Script | When | Network | Storage |
|---|---|---|---|
| [`../cloud-init-from-inventory.sh`](../cloud-init-from-inventory.sh) | Simple bare metal (e.g. k8s workers) | From inventory `ethernets` (MAC match) | Whole disk (`lvm` or `direct`) |
| [`build-user-data.sh`](build-user-data.sh) | Hypervisor reimage (kvm01/kif) | Ansible `hypervisor.yml` after first boot | Interactive (`interactive-sections: [storage]`) |

VMs still use [`scripts/vm/vm-create.sh`](../../vm/vm-create.sh) (cloud image + seed ISO).

## Prerequisites

```bash
./scripts/vm/keys-ensure.sh -i production
```

## Bare metal simple (inventory → CIDATA)

Inventory host must have `ethernets` with a real `macaddress` (not `tbd`), and must **not**
have `vm_name`. Optional: `install_profile: bare_metal_simple`.

```bash
./scripts/reimage/cloud-init-from-inventory.sh \
  -i production \
  k8s-node-1.home.2123studios.com \
  -o /mnt/CIDATA

# Preview without a USB mount:
./scripts/reimage/cloud-init-from-inventory.sh \
  -i production \
  k8s-node-1.home.2123studios.com \
  --dry-run
```

## Hypervisor reimage (identity only)

```bash
./scripts/reimage/ubuntu-autoinstall/build-user-data.sh \
  --profile kvm01 \
  --hostname kvm01 \
  --libvirt-uuid d1b341d8-01bd-4ecb-8545-8bc441826a59 \
  -o /mnt/CIDATA
```

Omit `--libvirt-uuid` if you mount `/var/lib/libvirt` in the installer UI or rely on
Ansible `hypervisor.yml` only.

## Install flow (USB)

1. Write Ubuntu 24.04 **Server** ISO to USB.
2. Add **CIDATA** partition (VFAT, label `CIDATA`) with generated `user-data` and `meta-data`.
3. Boot from USB.
   - **bare_metal_simple:** unattended through storage; reboots with static IP from inventory.
   - **hypervisor:** complete **storage** interactively (format `cs/ubuntu-root` only;
     do **not** format `cs/libvirt`); reboot manually if needed.
4. Verify: `ssh -i scripts/vm/keys/prod_id_ed25519 ansible@<ip> hostname`

See [hypervisor-runbook.md](../../../docs/hypervisor-runbook.md) and
[scripts/reimage/](../) for kvm01 autoinstall helpers.
