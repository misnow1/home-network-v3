# Hypervisor runbook (Slice 4 / 25+)

Lab and production hypervisor hosts run **libvirt/KVM** and optionally **Docker** on
Ubuntu 24.04. Slice 4 proves the stack inside nested `hv01.lab.test` on a development
hypervisor (kvm01 or kif). Slice 25+ adds **netplan host bridges** and **libvirt bridge
networks** for production kif/kvm01.

## Lab integration (automated)

```bash
./scripts/test-integration.sh
```

Default host is `hv01.lab.test` (requires nested virtualization on kvm01).

## Manual lab workflow

```bash
./scripts/lab/vm-create.sh hv01.lab.test
./scripts/lab/wait-ssh.sh hv01.lab.test
ansible-playbook playbooks/baseline.yml --limit hv01.lab.test
ansible-playbook playbooks/hypervisor.yml --limit hv01.lab.test
ansible-playbook tests/integration/test_hypervisor_converged.yml --limit hv01.lab.test
./scripts/lab/vm-destroy.sh hv01.lab.test
```

Re-run `hypervisor.yml` twice — second run must report `changed=0`.

## What the role delivers

| Component | Purpose |
|---|---|
| **libvirt** | `qemu-kvm`, libvirtd, storage pools, optional bridge networks |
| **Python deps** | `python3-libvirt`, `python3-lxml` (required by `community.libvirt` on the host) |
| **netplan** | Host `br0` + VLAN bridges (production only, when enabled) |
| **Docker** | Docker CE (`docker-ce` + compose plugin) from Docker's apt repo (optional, default on) |
| **Groups** | `hypervisor_libvirt_users` added to `libvirt` and `kvm` groups |

## Role variables (high level)

| Variable | Default | Purpose |
|---|---|---|
| `hypervisor_libvirt_enabled` | `true` | Master gate — set in `group_vars/hypervisors` for production |
| `hypervisor_netplan_enabled` | `false` | Enable host bridge/VLAN netplan |
| `hypervisor_netplan_bridges` | `{}` | Per-bridge config; production uses `dhcp4: true` on br0 |
| `hypervisor_libvirt_networks` | `[]` | Bridge networks (`external-default`, `vlan3`, `vlan4`) |
| `hypervisor_netplan_br4_address` | `""` | Static br4 address per host (e.g. `192.168.7.152/24`) |
| `hypervisor_libvirt_pools` | `default`, `vms` | Base dir pools |
| `hypervisor_libvirt_pools_extra` | `[]` | Host-specific pools (e.g. kif `boot`) |
| `hypervisor_libvirt_users` | `[ansible]` | Users in `libvirt`/`kvm` groups |
| `hypervisor_libvirt_volume_group` | `""` | LVM VG name (required when `data_volumes` set) |
| `hypervisor_libvirt_data_volumes` | `[]` | Opt-in libvirt mounts: `lv`, `mount`, `size` per entry |
| `hypervisor_perf_tuning_enabled` | `false` | Enable tuned/sysctl/THP host tuning (see [`hypervisor-performance.md`](hypervisor-performance.md)) |
| `hypervisor_grub_manage` | `false` | Deploy `/etc/default/grub.d/99-home-network-hypervisor.cfg` (timeout + cmdline) |
| `hypervisor_grub_timeout` | `5` | GRUB menu timeout seconds (when managed) |
| `hypervisor_grub_timeout_style` | `menu` | `menu` / `countdown` / `hidden` |
| `hypervisor_grub_cmdline_linux_extra` | `[]` | Kernel cmdline tokens (e.g. `intel_iommu=on`, `iommu=pt`) |
| `docker_engine_enabled` | `true` | Include `docker_engine` role |

### GRUB menu timeout (kif + kvm01)

Both production hypervisors enable a 5s **menu** timeout (replacing Ubuntu's hidden/0
default) so IPMI/console can pick a kernel or edit cmdline:

```yaml
hypervisor_grub_manage: true
hypervisor_grub_timeout: 5
hypervisor_grub_timeout_style: menu
```

**kif only** also sets IOMMU passthrough (X10SRi-F is EOL; latest BIOS still reports a
broken RMRR for the ASMedia USB controller, which collided with KVM `vhost_net` →
Mellanox DMA — `DMAR: ERROR: DMA PTE for vPFN … already set`):

```yaml
# kif host_vars only — do not set on kvm01
hypervisor_grub_cmdline_linux_extra:
  - intel_iommu=on
  - iommu=pt
```

`iommu=pt` keeps VT-d available but identity-maps devices. **Reboot required** after
first converge for cmdline changes to apply (timeout alone is written immediately to
`grub.cfg`).

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/hypervisor.yml \
  --limit kif.home.2123studios.com,kvm01.home.2123studios.com --tags hypervisor_grub
# after kif reboot:
#   cat /proc/cmdline   # expect intel_iommu=on iommu=pt
#   dmesg | grep -iE 'DMA PTE|RMRR|iommu=pt'
```

### Console break-glass root (baseline)

Root has no password after Ubuntu reimage (`shadow` `*`). For physical/IPMI console
when AD/SSH is wedged, kif and kvm01 enable:

```yaml
linux_baseline_root_console_enabled: true   # host_vars
# vault_root_password in group_vars/all/vault.yml (shared secret)
```

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml \
  --limit kif.home.2123studios.com,kvm01.home.2123studios.com --tags root_console
```

This sets the root password only — it does **not** enable SSH `PermitRootLogin`.
Retrieve the secret with `ansible-vault view …/vault.yml` (never commit plaintext).

### Libvirt storage host profiles

`hypervisor_libvirt_data_volumes` is opt-in — set only in `host_vars` for production
hypervisors with dedicated libvirt LVs. Empty list (default) keeps libvirt on the root
filesystem (lab `hv01`).

| Profile | Example hosts | `hypervisor_libvirt_data_volumes` |
|---|---|---|
| **Root FS** | hv01.lab.test | `[]` (default) |
| **Whole libvirt tree** | kvm01 | `cs/libvirt` → `/var/lib/libvirt` |
| **Images only** | kif | `kif2/libvirt-images` → `/var/lib/libvirt/images` |

Workload hosts mount libvirt paths from dedicated LVs **before** libvirt packages install
and `libvirtd` starts. LVs are created only when missing; existing filesystems are never
reformatted. See [`roles/hypervisor`](../roles/hypervisor/) and host_vars examples for
kvm01 and kif.

### Docker host profiles

`docker_engine_enabled` and dedicated Docker LVM storage are **independent**. Set storage
only in `host_vars` for compose/workload hosts — never in `group_vars/dc` or
`group_vars/hypervisors`.

| Profile | Example hosts | `docker_engine_data_volumes` |
|---|---|---|
| **Lightweight docker** | dc01 (DDNS API) | `[]` (default) — Docker on root FS |
| **Docker workload** | kif, kvm01 | host_vars: VG + `docker` / `docker-volumes` LVs |
| **Hypervisor lab** | hv01.lab.test | `[]` — integration tests only |
| **Future compose host** | TBD | Same as workload — add `host_vars` when provisioned |

### `docker_engine` role variables

| Variable | Default | Purpose |
|---|---|---|
| `docker_engine_volume_group` | `""` | LVM VG name (required when `data_volumes` set) |
| `docker_engine_data_volumes` | `[]` | Opt-in mounts: `lv`, `mount`, `size` per entry |
| `docker_engine_nvidia_runtime` | `auto` | `auto` / `true` / `false` — Container Toolkit |
| `docker_engine_nvidia_install_driver` | `false` | Install GPU driver (kvm01); reboot if a new kernel was installed. Also pulls `nvidia-utils-<branch>-server` for `nvidia-smi` |
| `docker_engine_nvidia_driver_package` | `""` | Pin an exact driver metapackage (e.g. `nvidia-headless-no-dkms-580-server-open`). Empty = auto via `ubuntu-drivers`, run only when no `-server` driver is installed |
| `docker_engine_nvidia_auto_reboot` | `false` | When the driver needs a new kernel: `false` stops the play for a manual reboot; `true` reboots and continues |

**Driver install idempotency:** `ubuntu-drivers install --recommended` is not
idempotent when more than one `-server` branch is "recommended" — it flips branches
on each run, reinstalling packages and requiring a reboot every time. The role only
runs the auto installer when **no** NVIDIA `-server` driver is present. To force a
specific branch (recommended when the host offers several), set
`docker_engine_nvidia_driver_package` to the exact metapackage; it installs via apt
and is fully idempotent.

Workload hosts mount `/srv/docker` and `/var/lib/docker/volumes` from separate LVs before
Docker starts. LVs are created only when missing; existing filesystems are never
reformatted. See [`roles/docker_engine`](../roles/docker_engine/) and
[`host_vars/kvm01.../vars.yml.example`](../inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example).

Production bridge networks and netplan (including DHCP on br0 and DNS search domain on
br0 via `vm_dns_search`) are set in
[`inventories/production/group_vars/hypervisors/`](../inventories/production/group_vars/hypervisors/vars.yml.example).
Per-host `host_vars` set `hypervisor_netplan_uplink`, optional NICs, and
`hypervisor_netplan_br4_address`.

### VLAN 4 — Docker edge network (br4)

VLAN 4 (`192.168.7.0/24`) is an **L2-only** segment for proxy-facing Docker backends.
It extends across kif and kvm01 via tagged trunks — **no UniFi gateway, DHCP, or DNS**.

| Host | br4 address | libvirt network |
|---|---|---|
| kif | `192.168.7.152/24` | `vlan4` → `br4` |
| kvm01 | `192.168.7.21/24` | `vlan4` → `br4` |
| proxy01 (VM) | `192.168.7.23/24` | second NIC on `vlan4` |

Set the static address per hypervisor in `host_vars`:

```yaml
hypervisor_netplan_br4_address: 192.168.7.152/24   # kif — mirrored from 192.168.1.152
```

UniFi: create VLAN 4, tag hypervisor uplinks, **do not** assign a gateway or DHCP pool.
See [unifi-gateway-dns.md](unifi-gateway-dns.md#vlan-4-docker-edge) and
[adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md).

### Netplan apply and bridge MAC / DHCP reservation

`netplan.yml` deploys `/etc/netplan/{{ hypervisor_netplan_config_file }}` (mode `0600`),
then applies it whenever the config **changed** or a managed bridge is **missing**
(so a host whose config is on disk but was never applied still converges). The apply
runs `async` with a following `wait_for_connection`, because enslaving the uplink into
`br0` briefly resets SSH.

**Keeping the host IP when first bridging the uplink:** `br0` takes a
systemd-networkd-derived MAC by default, so the router's DHCP reservation (keyed to the
raw uplink NIC's MAC) no longer matches and the host gets a **new IP** — the converge
then loses the host at its `ansible_host`. Choose one:

- **Pin br0's MAC to the uplink** (recommended) — set the uplink NIC's MAC per host so
  the existing reservation still returns the same IP. Use the dedicated variable so you
  do **not** have to redefine the shared `hypervisor_netplan_bridges` dict:

  ```yaml
  # host_vars/<host>/vars.yml  (per host — each uplink MAC differs)
  hypervisor_netplan_br0_macaddress: "aa:bb:cc:dd:ee:ff"   # `ip link show enp5s0`
  ```

- **Or update the router reservation** to br0's new MAC after the first apply.

If the host goes unreachable after the first `hypervisor.yml`, find its new lease on the
router, update `ansible_host` (or fix the reservation/MAC), then re-run.

### Host resolvers (br0 DNS)

Production `br0` uses DHCP for the host address but **must not** inherit DNS from the
lease or from IPv6 Router Advertisements:

| Source | What it offers | Problem |
|---|---|---|
| DHCPv4 (UCG) | Pi-hole `.18` + `.22` | Correct — but not the only source |
| RDNSS / DHCPv6 (UCG) | Gateway GUA `2600:…::1` | Router is not an AD-aware resolver |
| Static netplan | Pi-hole `.18` + `.22` | Required steady-state |

When `systemd-resolved` selects the router's IPv6 address as **Current DNS Server**, AD
SRV queries (`_kerberos._udp`, `_ldap._tcp`) fail. Kerberos cannot locate a KDC, and
winbind `getpwnam` fails with `WBC_ERR_DOMAIN_NOT_FOUND` — even though both DCs serve
correct RFC2307 attributes and Pi-hole answers the same queries.

`hypervisor_netplan_bridges.br0` in
[`group_vars/hypervisors/vars.yml.example`](../inventories/production/group_vars/hypervisors/vars.yml.example)
sets:

- `nameservers.addresses` → Pi-hole pair
- `dhcp4-overrides.use-dns: false`, `dhcp6-overrides.use-dns: false`, `ra-overrides.use-dns: false`

After converge, verify on each hypervisor:

```bash
resolvectl status br0 | grep -E 'Current DNS Server|DNS Servers'
dig +short SRV _kerberos._udp.home.2123studios.com
getent passwd <ad-user>
```

Expected: current server is `.18` or `.22` (never the gateway GUA); SRV records list
dc1/dc2; `getent` returns a passwd line.

## Nested virtualization

`hv01.lab.test` is created with `vm_nested_virt: true` (CPU host-passthrough) and
`vm_disk_gb: 32` (libvirt + Docker need more space than the cloud image overlay).
Integration tests assert `/dev/kvm` exists and `virsh -c qemu:///system list` succeeds.

When `hypervisor_perf_tuning_enabled: true`, integration tests also assert `tuned` is
active with the `virtual-host` profile, `vm.swappiness` is lowered, and THP is set to
`madvise`. Lab hypervisors enable this by default — see
[`hypervisor-performance.md`](hypervisor-performance.md) for measurement and production rollout.

Group membership (`libvirt`, `docker`) takes effect after a new login. Integration tests
use `become` for `virsh`/`docker run` and separately assert the `ansible` user is in
those groups.

## Apply order

### Lab nested hypervisor (`hv01.lab.test`)

1. `baseline.yml` — chrony and base packages
2. `hypervisor.yml` — libvirt + Docker (no netplan / bridge networks)

### Production kvm01

1. `baseline.yml`
2. `domain-join.yml` — realmd + sssd (after Ubuntu reimage)
3. `hypervisor.yml` — netplan, libvirt pools/networks, Docker
4. `backup.yml`

See [`host_vars/kvm01.../vars.yml.example`](../inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example) and
Restore must-preserve VM definitions from Tier-1 capture after hypervisor converge —
see [`hypervisor-runbook.md`](hypervisor-runbook.md).

### Production kif (hypervisor + fileserver)

kif is in both `hypervisors` and `fileservers`. Shared libvirt and netplan bridge
settings live in `group_vars/hypervisors/`; kif `host_vars` set the uplink NIC and
`boot` pool only.

1. `baseline.yml`
2. `hypervisor.yml --limit kif.home.2123studios.com` — netplan, libvirt, Docker
3. `fileserver.yml` — Samba (also runs hypervisor role when `hypervisor_libvirt_enabled`)
4. `nut-converge.yml`

Partial hypervisor runs on kif:

```bash
./scripts/prod-run.sh -- playbooks/fileserver.yml --limit kif.home.2123studios.com \
  --tags libvirt,hypervisor_netplan,hypervisor_networks
```

## Production notes

- Libvirt bridge network for the home LAN is **`external-default`** (not legacy `public-bridge`).
- **`home-dc-lab`** NAT network remains in [`scripts/lab/network-ensure.sh`](../scripts/lab/network-ensure.sh).
- The role never removes existing libvirt networks or pools — migrate VMs manually if renaming networks.
- Per-host backup scope is declared in `host_vars/{hostname}/vars.yml` and rendered by
  `playbooks/backup.yml` (Slice 7). See [`docs/backup-runbook.md`](backup-runbook.md).

Domain join is optional for hypervisors and is not part of Slice 4 integration.
