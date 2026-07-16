# kif / kvm01 reimage runbook (Slice 19)

Reimage **kif** and **kvm01** from CentOS to Ubuntu 24.04 with Ansible management.
**Strategy:** parallel Ubuntu install on spare SSD; **do not format** md127 data LVs (`kif2-home`, libvirt/Docker LVs) or raid6 (`/media`, `/archive`).

See [ROADMAP.md](ROADMAP.md) slice **19** (active) and deferred **15+–24+** for post-reimage Ansible work.

## Host roles

| Host | Services | Post-reimage playbooks |
|---|---|---|
| **kif** | NFS, Samba AD member (winbind), Docker, libvirt, NUT, wsdd, mdadm monitor | `baseline.yml` → `domain-join.yml` (mail relay tag) → `nut-converge.yml` → `fileserver.yml` + manual NFS/wsdd until roles land |
| **kvm01** | libvirt hypervisor, integration tests | `baseline.yml` → `domain-join.yml` → `hypervisor.yml` → `backup.yml` |

**kif uses winbind, not sssd** — do not run `domain-join.yml` on kif.

## Storage layout (kif)

| Tier | Device | Contents |
|---|---|---|
| Spare SSD | disposable | `/`, `/boot`, `/boot/efi` only |
| md127 | persistent | `home`, `docker`, `docker-volumes`, `libvirt-images` on `kif2` (Phase 4 **done**) |
| raid6 | persistent | `/media`, `/archive` |

Record UUIDs during backup: `blkid` → save in staging `config/storage.txt`.

## Storage layout (kvm01)

kvm01 has **no spare SSD** — use free extents on the existing NVMe VG instead of a
parallel physical disk. VM qcow2 data lives on a dedicated LV; domain XML lives on
the OS LV and must be captured before wipe.

| Tier | LV / device | Mount | Action |
|---|---|---|---|
| EFI | `nvme0n1p1` | `/boot/efi` | **Keep** — reuse |
| Boot | `nvme0n1p2` (or new `cs/ubuntu-boot`) | `/boot` | Reformat during install |
| OS (new) | `cs/ubuntu-root` (~100 GB) | `/` | `lvcreate` in free VG space; install Ubuntu here |
| OS (old) | `cs/root` | — | Retain during burn-in; `lvremove` after validation |
| Swap | `cs/swap` | swap | Reuse UUID in fstab or recreate |
| Data (persistent) | `cs/libvirt` (1 TB) | `/var/lib/libvirt` | **DO NOT FORMAT** — Ansible mounts via `hypervisor_libvirt_data_volumes` in host_vars |

**Ansible-managed mount:** `hypervisor.yml` mounts `/var/lib/libvirt` from `cs/libvirt`
before libvirt installs. Manual fstab is optional for first boot only; confirm the LV
UUID in staging `config/storage.txt` if you mount before Ansible converge:

```
UUID=d1b341d8-01bd-4ecb-8545-8bc441826a59  /var/lib/libvirt  xfs  defaults  0  2
```

**Must-preserve VMs** (shutdown OK during maintenance; disks on `cs/libvirt`):

| VM | Network | Disk path |
|---|---|---|
| calculon2 | br0 / `external-default` | `/var/lib/libvirt/images/calculon2.qcow2` |
| pihole-2 | br0 / `external-default` | `/var/lib/libvirt/images/pihole-2.qcow2` |
| dc1-home | `external-default` | `.../home-network-v3/production/vms/dc1-home.qcow2` |
| mail-home | `external-default` | `.../home-network-v3/production/vms/mail-home.qcow2` |
| github-runner-1 | `vlan3` | `.../home-network-v3/lab/vms/github-runner-1.qcow2` |

Expirable lab VMs: `cka-cp1`, `cka-sim`.

## Phase 0 — Pre-flight (control node)

```bash
./scripts/reimage/preflight-check.sh
./scripts/vm/keys-ensure.sh -i production
```

## Phase 1 — Tier-1 inventory (on each host, read-only)

On **kif** (as root):

```bash
cd ~/workspace/home-network-v3   # or copy scripts to kif
sudo ./scripts/reimage/inventory-capture.sh
# → /archive/pre-reimage-kif-YYYY-MM-DD/
```

On **kvm01** (NFS `/archive` is rootsquash — capture to local disk, then copy to kif):

```bash
sudo ./scripts/reimage/inventory-capture.sh --host-label kvm01 \
  --staging /var/tmp/pre-reimage-kvm01-YYYY-MM-DD
```

Copy to kif `/archive` (from control node or any host that can write kif `$HOME`):

```bash
rsync -av /var/tmp/pre-reimage-kvm01-YYYY-MM-DD/ \
  kif:~/pre-reimage-kvm01-YYYY-MM-DD/
ssh kif 'sudo mv ~/pre-reimage-kvm01-YYYY-MM-DD /archive/pre-reimage-kvm01-YYYY-MM-DD'
```

Review `MANIFEST.txt` and `config/storage.txt`. Confirm all five must-preserve
domain XMLs exist under `libvirt/domains/`.

**Status (2026-07-15):** Tier-1 capture completed at
`/var/tmp/pre-reimage-kvm01-2026-07-15` on kvm01; copy rsynced to
`kif:~/pre-reimage-kvm01-2026-07-15/` (move to `/archive` when kif sudo is
available: `sudo mv ~/pre-reimage-kvm01-2026-07-15 /archive/...`).

Optional hygiene on kif before heavy backup:

```bash
docker volume rm root_chronograf-storage root_grafana-storage 2>/dev/null || true
docker volume prune -f
```

## Phase 2 — Tier-2 backup (maintenance window)

**Do not start this phase until you are ready for guest downtime.**

### kvm01 maintenance prep

1. **Notify** — calculon2, pihole-2, dc1-home, mail-home, github-runner-1 will be down.
2. **Domain leave** (from control node — run once, immediately before install):
   ```bash
   PROD='./scripts/prod-run.sh --confirm-production --'
   ${PROD} playbooks/domain-leave.yml --limit kvm01.home.2123studios.com
   ```
3. **Stop VMs** — graceful shutdown of the five must-preserve guests (`virsh shutdown`;
   `destroy` only if stuck). `cka-cp1` / `cka-sim` are optional.
4. **Create parallel OS LV** (on CentOS, before USB install):
   ```bash
   sudo lvcreate -L 100G -n ubuntu-root cs
   sudo blkid >> /var/tmp/pre-reimage-kvm01-*/config/storage.txt
   ```

### kif / kvm01 backup

1. Stop VMs: `virsh shutdown …` (wait; `virsh destroy` only if stuck).
2. Stop Docker: `docker compose down` in each `/srv/docker/*` project.
3. Stop Samba/NFS exports on kif during cutover only (not during backup).

```bash
# kif — insurance /home mirror optional if kif2-home LV will be preserved:
sudo ./scripts/reimage/inventory-backup.sh \
  --staging /archive/pre-reimage-kif-YYYY-MM-DD \
  --skip-home

# kvm01
sudo ./scripts/reimage/inventory-backup.sh \
  --staging /archive/pre-reimage-kvm01-YYYY-MM-DD
```

Verify: restore sample qcow2 + one docker volume path; `sha256sum` compare.

## Network cleanup (kif and kvm01)

CentOS/NM today mixes **Docker** bridges (`br-*`, `docker0`), stale inactive profiles, and **libvirt** dynamics (`virbr*`, `vnet*`) with the real uplink. **Do not migrate nmcli profiles to Ubuntu** — use a small **netplan** file and let Docker/libvirt manage their own interfaces.

### Physical layout

| NIC | Role today | Target |
|---|---|---|
| **ens5f0np0** | Only cable to switch (25GbE port 0) | Sole uplink; bridge port only — **no IP on raw NIC** |
| **ens5f1np1** | Mellanox port 1, no switch cable | Down / `optional: true` until LACP or second link |
| **eno1 / eno2** | Onboard 1GbE, unused | Down / optional; reserve for future OOB |

### Logical layout (netplan-managed)

| Interface | VLAN | Purpose |
|---|---|---|
| **br0** | 1 (untagged) | Host L3: NFS, Samba, SSH, route to gateway |
| **br3** | 3 (`ens5f0np0.3` → br3) | Libvirt **vlan3** / CKA VMs |
| **virbr0**, lab NAT | — | Libvirt-only — **not** in netplan |
| **docker0**, **br-*** | — | Docker-only — **not** in netplan |

Re-run `inventory-capture.sh` to refresh `config/network/` (nmcli, routes, `bridge.conf`).

### Target netplan (Ansible-managed)

Production hypervisors use `dhcp4: true` on **br0** (DHCP reservations on the router).
Host L3, gateway, and DNS come from DHCP. **br3** has no address — libvirt VLAN 3 only.

Per-host uplink NIC (`hypervisor_netplan_uplink`) and bridge layout are in
[`group_vars/hypervisors/`](../inventories/production/group_vars/hypervisors/vars.yml.example).

Example rendered shape:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens5f0np0:
      dhcp4: false
      dhcp6: false
  vlans:
    ens5f0np0.3:
      id: 3
      link: ens5f0np0
  bridges:
    br0:
      interfaces: [ens5f0np0]
      dhcp4: true
      dhcp6: false
      nameservers:
        search: [home.2123studios.com]
    br3:
      interfaces: [ens5f0np0.3]
      dhcp4: false
```

`netplan apply` → verify `ip -br addr` on br0 (DHCP lease), gateway ping, VLAN 3 VM DHCP.

### Libvirt (restore from staging `libvirt/networks/*.xml`)

| Network | Bridge | Use |
|---|---|---|
| **external-default** | **br0** | Production VMs on home LAN |
| **vlan3** | **br3** | CKA / VLAN 3 ([cka-runbook.md](cka-runbook.md)) |
| **home-dc-lab** | NAT | Lab integration — libvirt-managed |

For `--bridge br3` mode: `allow br3` in `/etc/qemu/bridge.conf`.

**kvm01:** same pattern if topology matches; confirm from kvm01 `config/network/` capture.

**Leave behind on CentOS:** inactive Docker `br-*` NM profiles; do not preserve `vnet*` taps.

### kvm01 physical NICs

| NIC | Role | Target |
|---|---|---|
| **enp5s0** | Uplink to switch | Sole bridge port — **no IP on raw NIC** |
| **enp6s0** | Second port, no cable | Down / optional |
| **enp7s0f3u5** | USB NIC | Optional |
| **wlp4s0** | WiFi | Down / optional |

Uplink and optional NICs are set in
[`host_vars/kvm01.../vars.yml.example`](../inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example)
(`hypervisor_netplan_uplink: enp5s0`).

## Phase 3 — Parallel Ubuntu install (kif spare SSD)

**Installer rules:**

- Format **spare SSD only** — never sdf/sdg md127 or raid6.
- After first boot: `vgchange -ay`; mount data LVs by **UUID** in `/etc/fstab`.
- Do **not** `mkfs` on `kif2-home`.

**Bring up services before decommissioning CentOS:**

- NFS exports (`/home`, `/media`, `/archive`)
- Samba + winbind (restore from staging `samba/`)
- wsdd
- NUT (`upsc kifups ups.status`; see [nut-runbook.md](nut-runbook.md))
- Docker compose under `/srv/docker`

**Validation gates:**

- [ ] kvm01: NFS home mount, `getent passwd` AD users
- [ ] Windows: `\\KIF\media`, `\\KIF\homes`
- [x] `upsc kifups` (livingroomups SNMP deferred)
- [x] Docker stacks (paperless, guacamole, plex, …)
- [ ] `br0` reachable; `br3` VLAN 3 VMs get DHCP; libvirt networks on correct bridges

## Phase 3b — Parallel Ubuntu install (kvm01, same NVMe)

### Autoinstall USB (recommended)

Automates **ansible** user, **prod SSH key**, and **sudo**; **storage is manual** in the
installer UI so **`cs/libvirt` is never formatted**.

```bash
./scripts/vm/keys-ensure.sh -i production
# Mount VFAT partition labeled CIDATA on the installer USB:
./scripts/reimage/ubuntu-autoinstall/build-user-data.sh \
  --profile kvm01 --hostname kvm01 \
  --libvirt-uuid d1b341d8-01bd-4ecb-8545-8bc441826a59 \
  -o /mnt/CIDATA
```

See [scripts/reimage/ubuntu-autoinstall/README.md](../scripts/reimage/ubuntu-autoinstall/README.md).
Boot Server ISO + CIDATA; at **storage**, format **`cs/ubuntu-root`** only; leave
**`cs/libvirt`** unformatted (mount `/var/lib/libvirt` without format if desired).
Reboot manually when install completes.

### Manual installer (fallback)

**Installer rules (USB media on `sda`):**

- Hostname: **`kvm01.home.2123studios.com`**
- Format **`cs/ubuntu-root`** (and `/boot` / EFI as needed)
- **Do not format `cs/libvirt`** — Ansible mounts it at `/var/lib/libvirt` via
  `hypervisor_libvirt_data_volumes` in host_vars (optional manual fstab for first boot)
- Do not touch qcow2 paths under the libvirt mount
- Create local user **`ansible`** during install:
  - SSH key: [`scripts/vm/keys/prod_id_ed25519.pub`](../scripts/vm/keys/prod_id_ed25519.pub)
  - `authorized_keys` for `ansible`; NOPASSWD sudo (`/etc/sudoers.d/ansible` or group sudo)

**Post-install verification:**

```bash
mount /var/lib/libvirt
ls /var/lib/libvirt/images/calculon2.qcow2
ls /var/lib/libvirt/images/home-network-v3/production/vms/dc1-home.qcow2
ssh -i scripts/vm/keys/prod_id_ed25519 ansible@192.168.1.21 hostname
```

**Domain join:** kvm01 uses **realmd + sssd** (not winbind). If `realm join` fails with
a stale computer account, on dc1: `samba-tool computer delete kvm01$`.

## Phase 4 — md127 data LVs on kif (**done** 2026-07-14, validated 2026-07-15)

Retired `kif2-root`; docker/libvirt LVs live on `kif2` (md127 RAID1). Root stays on
spare SSD (`ubuntu-vg/ubuntu-lv`). Inactive copies on `ubuntu-vg` are retained during
burn-in; remove when satisfied (see below).

| Mount | LV | VG |
|---|---|---|
| `/home` | `home` | `kif2` |
| `/srv/docker` | `docker` | `kif2` |
| `/var/lib/docker/volumes` | `docker-volumes` | `kif2` |
| `/var/lib/libvirt/images` | `libvirt-images` | `kif2` |
| `/` | `ubuntu-lv` | `ubuntu-vg` (spare SSD) |

**Ansible-managed mounts:** `hypervisor.yml` mounts `/var/lib/libvirt/images` from
`kif2/libvirt-images` before libvirt installs. Manual fstab for that path is optional
for first boot only.

```bash
sudo lvremove ubuntu-vg/docker ubuntu-vg/docker-volumes ubuntu-vg/libvirt-images
```

**kvm01 deferred cleanup** — after burn-in on Ubuntu, remove old CentOS root LV:

```bash
sudo lvremove cs/root
```

## Phase 5 — Ansible converge

Copy host_vars from examples before converge. `hypervisor.yml` idempotently ensures libvirt
and Docker LVM mounts on kif and kvm01 — manual `lvcreate` and fstab entries for those
paths are no longer required when `hypervisor_libvirt_data_volumes` and
`docker_engine_data_volumes` are set in host_vars.

- [`inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example`](../inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example)
- [`inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example`](../inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example)

**kif pre-converge:** remove stale netplan drop-ins (especially any file enabling `dhcp4`
on the uplink NIC). The hypervisor role deploys `/etc/netplan/01-hypervisor.yaml` only.

**kif libvirt:** kif is in the `hypervisors` group — run `hypervisor.yml` directly.
`fileserver.yml` also includes the hypervisor role when `hypervisor_libvirt_enabled`
(from `group_vars/hypervisors`). The role defines `external-default` and `vlan3`
but does **not** remove legacy `public-bridge` — migrate attached VMs manually if needed.

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/baseline.yml --limit kvm01.home.2123studios.com
${PROD} playbooks/domain-join.yml --limit kvm01.home.2123studios.com
${PROD} playbooks/nfs-client.yml --limit kvm01.home.2123studios.com
${PROD} playbooks/hypervisor.yml --limit kvm01.home.2123studios.com
${PROD} playbooks/backup.yml --limit kvm01.home.2123studios.com

${PROD} playbooks/baseline.yml --limit kif.example.home
${PROD} playbooks/domain-join.yml --limit kif.example.home --tags domain_mail_relay
${PROD} playbooks/nut-converge.yml --limit kif.example.home

# kif host_vars set fileserver_samba_enabled: false — Ansible does not manage smb.conf yet.
# If fileserver.yml was run before that guard, restore the pre-reimage config:
#   sudo cp /archive/pre-reimage-kif-2026-06-29/samba/smb.conf /etc/samba/smb.conf
#   sudo testparm -s
#   sudo systemctl restart smbd nmbd winbind
${PROD} playbooks/fileserver.yml --limit kif.example.home --check
```

Partial hypervisor on kif:

```bash
${PROD} playbooks/fileserver.yml --limit kif.example.home \
  --tags libvirt,hypervisor_netplan,hypervisor_networks
```

See [`hypervisor-runbook.md`](hypervisor-runbook.md) for role variables.

After `hypervisor.yml` on kvm01, restore must-preserve VM definitions from Tier-1
capture (Ansible does not manage individual domains):

```bash
STAGING=/archive/pre-reimage-kvm01-YYYY-MM-DD   # or /var/tmp/... on kvm01
for vm in pihole-2 dc1-home mail-home calculon2 github-runner-1; do
  sudo virsh define "${STAGING}/libvirt/domains/${vm}.xml"
  sudo virsh autostart "${vm}"    # if previously autostarted
done
# Start order: pihole-2 → dc1-home → mail-home → calculon2 → github-runner-1
sudo virsh start pihole-2
# ... etc.
```

Before `virsh define`, confirm disk paths in XML still exist on the mounted libvirt
LV and network names match Ansible (`external-default`, `vlan3` — not raw `br0`/`br3`
where libvirt network refs are used).

Run `sudo ./scripts/vm/dirs-ensure.sh -i production` if pool directory ownership needs repair.

Remove `ansible_managed: false` from production inventory when burn-in passes (see
[`hosts.yml.example`](../inventories/production/hosts.yml.example)).

## Post-reimage (ROADMAP deferred)

| Slice | Work |
|---|---|
| 15+ | NFS exports Ansible role |
| 19+ | kif custom Samba shares + wsdd in `samba_fileserver` |
| 20+ | Mac Time Machine + avahi |
| 21 | NUT Ansible role | **done** — [nut-runbook.md](nut-runbook.md) |
| 22+ | backup-libvirt.sh |
| 23+ | Restic timers + offsite |
| 24+ | Optional ESP/boot mirror on 2×1TB SSDs |
| 25+ | Hypervisor host netplan (Ansible) | **in progress** — [`hypervisor` role](../roles/hypervisor/); br0 + br3 + `external-default` / `vlan3` |

## Scripts

| Script | Purpose |
|---|---|
| [scripts/reimage/preflight-check.sh](../scripts/reimage/preflight-check.sh) | Control-node checks |
| [scripts/reimage/inventory-capture.sh](../scripts/reimage/inventory-capture.sh) | Tier-1 capture (run on host) |
| [scripts/reimage/inventory-backup.sh](../scripts/reimage/inventory-backup.sh) | Tier-2 rsync (run on host) |
