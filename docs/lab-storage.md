# VM storage (lab and production profiles)

Libvirt/QEMU runs as the `qemu` user on system libvirt (`qemu:///system`). VM disks,
cloud images, and cloud-init seed ISOs must be on **local disk** on the hypervisor that
runs the domain (kvm01 or kif).

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

## One-time setup (kvm01 or kif)

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

See [production-runbook.md](production-runbook.md).

## Cross-hypervisor install (`--dry-run`)

Build VM artifacts on a modern hypervisor (for example kvm01) and install on another
host (for example kif) that may lack ansible-inventory, cloud-init tooling, or a full
git checkout with vault access.

On the **build** host:

```bash
./scripts/vm/keys-ensure.sh -i production
sudo ./scripts/vm/dirs-ensure.sh -i production
./scripts/vm/vm-create.sh -i production --dry-run dc02.home.2123studios.com
```

This creates:

| Artifact | Path |
|---|---|
| qcow2 overlay | `production/vms/<vm_name>.qcow2` |
| cloud-init seed | `production/seeds/<vm_name>/seed.iso` (+ `user-data`, `meta-data`) |
| install script | `production/seeds/<vm_name>/install.sh` |
| domain XML | `production/seeds/<vm_name>/domain.xml` (when `virt-install` is available) |
| manifest | `production/seeds/<vm_name>/manifest.txt` |

Copy to the **target** hypervisor (same `VM_DATA_BASE` layout is simplest):

```bash
rsync -av /var/lib/libvirt/images/home-network-v3/images/ \
  kif:/var/lib/libvirt/images/home-network-v3/images/
rsync -av /var/lib/libvirt/images/home-network-v3/production/vms/dc02.qcow2 \
  kif:/var/lib/libvirt/images/home-network-v3/production/vms/
rsync -av /var/lib/libvirt/images/home-network-v3/production/seeds/dc02/ \
  kif:/var/lib/libvirt/images/home-network-v3/production/seeds/dc02/
```

On the target:

```bash
sudo /var/lib/libvirt/images/home-network-v3/production/seeds/dc02/install.sh
./scripts/vm/wait-ssh.sh -i production dc02.home.2123studios.com
```

When `domain.xml` is present, `install.sh` runs `virsh define` + `virsh start` so the
MAC in the XML matches the reservation you created on the router (do not re-run
`virt-install` manually).

If the backing image path differs on the target, rebase before install:

```bash
qemu-img rebase -u -b /var/lib/libvirt/images/home-network-v3/images/noble-server-cloudimg-amd64.img \
  /var/lib/libvirt/images/home-network-v3/production/vms/dc02.qcow2
```

Override paths at install time with `DISK_PATH`, `SEED_ISO`, `BASE_IMAGE`, or
`VM_DATA_BASE` (see `install.sh`).
