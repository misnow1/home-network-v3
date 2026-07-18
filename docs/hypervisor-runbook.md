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
| `hypervisor_libvirt_networks` | `[]` | Bridge networks (`external-default`, `vlan3`) |
| `hypervisor_libvirt_pools` | `default`, `vms` | Base dir pools |
| `hypervisor_libvirt_pools_extra` | `[]` | Host-specific pools (e.g. kif `boot`) |
| `hypervisor_libvirt_users` | `[ansible]` | Users in `libvirt`/`kvm` groups |
| `hypervisor_libvirt_volume_group` | `""` | LVM VG name (required when `data_volumes` set) |
| `hypervisor_libvirt_data_volumes` | `[]` | Opt-in libvirt mounts: `lv`, `mount`, `size` per entry |
| `docker_engine_enabled` | `true` | Include `docker_engine` role |

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
Per-host `host_vars` set `hypervisor_netplan_uplink` and optional NICs only.

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

## Nested virtualization

`hv01.lab.test` is created with `vm_nested_virt: true` (CPU host-passthrough) and
`vm_disk_gb: 32` (libvirt + Docker need more space than the cloud image overlay).
Integration tests assert `/dev/kvm` exists and `virsh -c qemu:///system list` succeeds.

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
