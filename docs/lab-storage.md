# Lab VM storage

Libvirt/QEMU runs as the `qemu` user on system libvirt (`qemu:///system`). Lab VM disks,
cloud images, and cloud-init seed ISOs must be on **local disk** on kvm01.

## NFS home and rootsquash

If your home directory is NFS-mounted from a file server with `rootsquash` (for example
`kif.home.2123studios.com:/home/misnow1`), the `qemu` user on kvm01 cannot open VM disks
under your checkout — even when files are owned by you. Libvirt will fail with
`Permission denied` on `.qcow2` paths under `/home/misnow1/`.

The git checkout can stay on NFS; **cloud images, VM overlays, and seed ISOs must not**.

## Default paths

| Path | Purpose |
|---|---|
| `/var/lib/libvirt/images/home-network-v3/images/` | Ubuntu 24.04 cloud base image |
| `/var/lib/libvirt/images/home-network-v3/vms/` | Per-VM qcow2 overlays |
| `/var/lib/libvirt/images/home-network-v3/seeds/` | cloud-init seed ISOs |

Override with `LAB_DATA_DIR` if needed.

## One-time setup on kvm01

```bash
cd ~/workspace/home-network-v3
sudo ./scripts/lab/dirs-ensure.sh
```

This creates directories owned by `SUDO_USER:qemu` with mode `775`. When not run
via sudo, set `LAB_DIR_OWNER=<user>` so ownership is explicit (no hardcoded user).

### Without sudo (temporary / dev)

Until `sudo ./scripts/lab/dirs-ensure.sh` has been run, you can use local `/var/tmp`:

```bash
export LAB_DATA_DIR=/var/tmp/home-network-v3
mkdir -p "$LAB_DATA_DIR"/{images,vms,seeds}
chmod 777 "$LAB_DATA_DIR" "$LAB_DATA_DIR"/*
./scripts/test-integration.sh
```

Prefer `/var/lib/libvirt/images/home-network-v3` for anything long-lived.

## SSH keys

Lab SSH keys remain in the repo at `scripts/lab/keys/` (private key gitignored). Only
disk images and seeds use local storage.
