# kif / kvm01 reimage runbook (Slice 19)

Reimage **kif** and **kvm01** from CentOS to Ubuntu 24.04 with Ansible management.
**Strategy:** parallel Ubuntu install on spare SSD; **do not format** md127 data LVs (`kif2-home`, libvirt/Docker LVs) or raid6 (`/media`, `/archive`).

See [ROADMAP.md](ROADMAP.md) slice **19** (active) and deferred **15+–24+** for post-reimage Ansible work.

## Host roles

| Host | Services | Post-reimage playbooks |
|---|---|---|
| **kif** | NFS, Samba AD member (winbind), Docker, libvirt, NUT, wsdd | `baseline.yml` → `fileserver.yml` + manual NFS/NUT/wsdd until roles land |
| **kvm01** | libvirt hypervisor, integration tests | `baseline.yml` → `hypervisor.yml` → `backup.yml` |

**kif uses winbind, not sssd** — do not run `domain-join.yml` on kif.

## Storage layout (kif)

| Tier | Device | Contents |
|---|---|---|
| Spare SSD | disposable | `/`, `/boot`, `/boot/efi` only |
| md127 | persistent | `kif2-home`, `kif2-libvirt`, `kif2-docker`, `kif2-srv` (after removing `kif2-root`) |
| raid6 | persistent | `/media`, `/archive` |

Record UUIDs during backup: `blkid` → save in staging `config/storage.txt`.

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

Review `MANIFEST.txt` and `config/storage.txt`.

Optional hygiene on kif before heavy backup:

```bash
docker volume rm root_chronograf-storage root_grafana-storage 2>/dev/null || true
docker volume prune -f
```

## Phase 2 — Tier-2 backup (maintenance window)

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

### Target netplan (kif — adjust IP/gateway/DNS)

`/etc/netplan/01-hypervisor.yaml`:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ens5f0np0:
      dhcp4: false
      dhcp6: false
    ens5f1np1:
      optional: true
      dhcp4: false
    eno1:
      optional: true
      dhcp4: false
    eno2:
      optional: true
      dhcp4: false
  vlans:
    ens5f0np0.3:
      id: 3
      link: ens5f0np0
  bridges:
    br0:
      interfaces: [ens5f0np0]
      addresses: [192.168.1.152/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.10, 192.168.1.11]
    br3:
      interfaces: [ens5f0np0.3]
      dhcp4: false
```

`netplan apply` → verify `ip -br addr`, gateway ping, VLAN 3 VM DHCP.

### Libvirt (restore from staging `libvirt/networks/*.xml`)

| Network | Bridge | Use |
|---|---|---|
| **external-default** | **br0** | Production VMs on home LAN |
| **vlan3** | **br3** | CKA / VLAN 3 ([cka-runbook.md](cka-runbook.md)) |
| **home-dc-lab** | NAT | Lab integration — libvirt-managed |

For `--bridge br3` mode: `allow br3` in `/etc/qemu/bridge.conf`.

**kvm01:** same pattern if topology matches; confirm from kvm01 `config/network/` capture.

**Leave behind on CentOS:** inactive Docker `br-*` NM profiles; do not preserve `vnet*` taps.

## Phase 3 — Parallel Ubuntu install (kif spare SSD)

**Installer rules:**

- Format **spare SSD only** — never sdf/sdg md127 or raid6.
- After first boot: `vgchange -ay`; mount data LVs by **UUID** in `/etc/fstab`.
- Do **not** `mkfs` on `kif2-home`.

**Bring up services before decommissioning CentOS:**

- NFS exports (`/home`, `/media`, `/archive`)
- Samba + winbind (restore from staging `samba/`)
- wsdd
- NUT (`upsc -l` shows both UPS)
- Docker compose under `/srv/docker`

**Validation gates:**

- [ ] kvm01: NFS home mount, `getent passwd` AD users
- [ ] Windows: `\\KIF\media`, `\\KIF\homes`
- [ ] `upsc` both UPS units
- [ ] Docker stacks (paperless, guacamole, plex, …)
- [ ] `br0` reachable; `br3` VLAN 3 VMs get DHCP; libvirt networks on correct bridges

## Phase 4 — Remove kif2-root (after validation)

```bash
# Only after spare-SSD Ubuntu + md127 mounts confirmed for several days
sudo lvremove kif2/kif2-root
# Create kif2-libvirt, kif2-docker, kif2-srv; lvextend kif2-home as needed
```

## Phase 5 — Ansible converge

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/baseline.yml --limit kvm01.example.home
${PROD} playbooks/hypervisor.yml --limit kvm01.example.home
${PROD} playbooks/backup.yml --limit kvm01.example.home

${PROD} playbooks/baseline.yml --limit kif.example.home
${PROD} playbooks/domain-join.yml --limit kif.example.home --tags domain_mail_relay
${PROD} playbooks/nut-converge.yml --limit kif.example.home
# Restore smb.conf manually first, then:
${PROD} playbooks/fileserver.yml --limit kif.example.home --check
```

Remove `ansible_managed: false` from production inventory when ready.

## Post-reimage (ROADMAP deferred)

| Slice | Work |
|---|---|
| 15+ | NFS exports Ansible role |
| 19+ | kif custom Samba shares + wsdd in `samba_fileserver` |
| 20+ | Mac Time Machine + avahi |
| 21+ | NUT Ansible role | **in progress** — [nut-runbook.md](nut-runbook.md) |
| 22+ | backup-libvirt.sh |
| 23+ | Restic timers + offsite |
| 24+ | Optional ESP/boot mirror on 2×1TB SSDs |
| 25+ | Hypervisor host netplan (Ansible) | br0 + br3 + libvirt network defs |

## Scripts

| Script | Purpose |
|---|---|
| [scripts/reimage/preflight-check.sh](../scripts/reimage/preflight-check.sh) | Control-node checks |
| [scripts/reimage/inventory-capture.sh](../scripts/reimage/inventory-capture.sh) | Tier-1 capture (run on host) |
| [scripts/reimage/inventory-backup.sh](../scripts/reimage/inventory-backup.sh) | Tier-2 rsync (run on host) |
