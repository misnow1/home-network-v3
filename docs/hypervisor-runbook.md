# Hypervisor runbook (Slice 4 / 25+)

Lab and production hypervisor hosts run **libvirt/KVM** and optionally **Docker** on
Ubuntu 24.04. Slice 4 proves the stack inside nested `hv01.lab.test` on kvm01.
Slice 25+ adds **netplan host bridges** and **libvirt bridge networks** for production
kif/kvm01.

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
| **Docker** | `docker.io` + Compose v2 plugin (optional, default on) |
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
| `docker_engine_enabled` | `true` | Include `docker_engine` role |

Production bridge networks and netplan (including DHCP on br0 and DNS search domain on
br0 via `vm_dns_search`) are set in
[`inventories/production/group_vars/hypervisors/`](../inventories/production/group_vars/hypervisors/vars.yml.example).
Per-host `host_vars` set `hypervisor_netplan_uplink` and optional NICs only.

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
2. `hypervisor.yml` — netplan, libvirt pools/networks, Docker
3. `backup.yml`

See [`host_vars/kvm01.../vars.yml.example`](../inventories/production/host_vars/kvm01.home.2123studios.com/vars.yml.example).

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
