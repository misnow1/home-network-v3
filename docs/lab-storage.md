# VM storage (lab and production profiles)

Libvirt/QEMU runs as the `qemu` user on system libvirt (`qemu:///system`). VM disks,
cloud images, and cloud-init seed ISOs must be on **local disk** on kvm01.

## NFS home and rootsquash

If your home directory is NFS-mounted from a file server with `rootsquash` (for example
`kif.home.2123studios.com:/home/misnow1`), the `qemu` user on kvm01 cannot open VM disks
under your checkout — even when files are owned by you. Libvirt will fail with
`Permission denied` on `.qcow2` paths under `/home/misnow1/`.

The git checkout can stay on NFS; **cloud images, VM overlays, and seed ISOs must not**.

## Default paths

Base directory (override with `VM_DATA_BASE`):

`/var/lib/libvirt/images/home-network-v3/`

| Path | Purpose |
|---|---|
| `images/` | Shared Ubuntu 24.04 cloud base image (all profiles) |
| `lab/vms/` | Lab profile qcow2 overlays |
| `lab/seeds/` | Lab profile cloud-init seed ISOs |
| `production/vms/` | Production profile qcow2 overlays |
| `production/seeds/` | Production profile cloud-init seed ISOs |

Legacy `LAB_DATA_DIR` is deprecated — use `VM_DATA_BASE` and profile subdirectories.

## One-time setup on kvm01

Lab integration tests:

```bash
cd ~/workspace/home-network-v3
sudo ./scripts/vm/dirs-ensure.sh -i lab
```

Production VMs (Samba AD migration, bastion, etc.):

```bash
sudo ./scripts/vm/dirs-ensure.sh -i production
```

Wrappers `./scripts/lab/dirs-ensure.sh` delegate to `-i lab`.

This creates directories owned by `SUDO_USER:qemu` with mode `775`. When not run
via sudo, set `VM_DIR_OWNER=<user>` so ownership is explicit.

### Without sudo (temporary / dev)

Until `sudo ./scripts/vm/dirs-ensure.sh -i lab` has been run:

```bash
export VM_DATA_BASE=/var/tmp/home-network-v3
mkdir -p "$VM_DATA_BASE/images" "$VM_DATA_BASE/lab/{vms,seeds}"
chmod 777 "$VM_DATA_BASE" "$VM_DATA_BASE"/*
./scripts/test-integration.sh
```

Prefer `/var/lib/libvirt/images/home-network-v3` for anything long-lived.

## SSH keys

Profile keypairs live under `scripts/vm/keys/` (private keys gitignored):

| Profile | Private key | Public key |
|---|---|---|
| lab | `lab_id_ed25519` | `lab_id_ed25519.pub` |
| production | `prod_id_ed25519` | `prod_id_ed25519.pub` |

Generate with `./scripts/vm/keys-ensure.sh -i lab` or `-i production`.

## VM scripts

Generic tooling: `scripts/vm/` (`vm-create.sh`, `vm-destroy.sh`, `wait-ssh.sh`).

Lab wrappers in `scripts/lab/` pass `-i lab` automatically. Production:

```bash
./scripts/vm/vm-create.sh -i production dc1.example.home
./scripts/vm/wait-ssh.sh -i production dc1.example.home
```

See [production-runbook.md](production-runbook.md) and [migration-runbook.md](migration-runbook.md).
