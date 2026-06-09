# CKA practice VM runbook

Create ad-hoc Ubuntu 24.04 VMs on kvm01 attached to **vlan3** for Kubernetes / CKA
lab work. These VMs use DHCP on your home VLAN (unlike isolated `192.168.100.0/24`
lab.test integration VMs).

Use **`--network vlan3`** when `vlan3` is a libvirt network (`virsh net-list`).
Use **`--bridge vlan3`** only when `vlan3` is a raw Linux bridge (`ip link show vlan3`)
and you are not using a libvirt network definition.

## Prerequisites (kvm01)

1. **Local lab storage** — see [lab-storage.md](lab-storage.md):

   ```bash
   sudo ./scripts/lab/dirs-ensure.sh
   ```

2. **vlan3 network** must exist — either as a libvirt network or a host bridge:

   ```bash
   virsh net-info vlan3          # libvirt network (--network vlan3)
   ip link show vlan3            # host bridge (--bridge vlan3)
   ```

3. **QEMU bridge access** (only needed for `--bridge`, not `--network`):

   ```bash
   grep -q 'allow vlan3' /etc/qemu/bridge.conf \
     || echo 'allow vlan3' | sudo tee -a /etc/qemu/bridge.conf
   sudo systemctl restart libvirtd
   ```

4. Your user must be in the `libvirt` group (or run via root).

5. Repo dependencies: `virsh`, `virt-install`, `qemu-img`, `cloud-localds` or
   `genisoimage`, `envsubst`.

## Create a CKA node

Libvirt network (typical when `virsh net-list` shows `vlan3`):

```bash
./scripts/lab/vm-create.sh \
  --name cka-cp1 \
  --network vlan3 \
  --dhcp \
  --memory 4096 \
  --vcpus 2 \
  --disk-gb 20
```

Host Linux bridge (when not using a libvirt network definition):

```bash
./scripts/lab/vm-create.sh \
  --name cka-cp1 \
  --bridge vlan3 \
  --memory 4096 \
  --vcpus 2 \
  --disk-gb 20
```

| Flag | Suggested CKA value | Notes |
|---|---|---|
| `--name` | `cka-cp1`, `cka-worker1`, … | libvirt domain name |
| `--network` | `vlan3` | libvirt network; use with `--dhcp` |
| `--bridge` | `vlan3` | Host bridge; implies DHCP cloud-init |
| `--memory` | `4096` | 4 GB minimum for control plane / worker |
| `--vcpus` | `2` | |
| `--disk-gb` | `20`–`30` | Kubernetes needs more than the base cloud image |
| `--hostname` | (optional) | Defaults to `--name` |

## Wait for SSH

The VM receives an IP via DHCP on vlan3. `wait-ssh.sh` discovers it through the
QEMU guest agent:

```bash
./scripts/lab/wait-ssh.sh --name cka-cp1
```

Or pass a known address:

```bash
./scripts/lab/wait-ssh.sh --name cka-cp1 --ip 10.x.x.x
```

Connect manually:

```bash
ssh -i scripts/lab/keys/lab_id_ed25519 ansible@<ip>
```

The `ansible` user has passwordless sudo (same key as lab integration VMs).

## Example: three-node practice cluster

```bash
for node in cka-cp1 cka-worker1 cka-worker2; do
  ./scripts/lab/vm-create.sh \
    --name "${node}" \
    --network vlan3 \
    --dhcp \
    --memory 4096 \
    --vcpus 2 \
    --disk-gb 20
  ./scripts/lab/wait-ssh.sh --name "${node}"
done
```

Install Kubernetes with your course materials (`kubeadm`, `containerd`, etc.) — not
automated in this repo.

## Converge with Ansible

After a VM is running, configure baseline packages, chrony, dev tools, and a personal
local user (named after `$USER` on the machine running ansible-playbook).

### One-time setup

1. Copy the inventory template:

   ```bash
   cp inventories/cka/hosts.yml.example inventories/cka/hosts.yml
   ```

2. Add your SSH public key to [`inventories/cka/group_vars/cka/vars.yml`](../inventories/cka/group_vars/cka/vars.yml):

   ```yaml
   cka_local_user_ssh_keys:
     - "ssh-ed25519 AAAA... you@laptop"
   ```

### Per-node workflow

```bash
# 1. Create and wait for cloud-init
./scripts/lab/vm-create.sh --name cka-cp1 --network vlan3 --dhcp --memory 4096 --vcpus 2 --disk-gb 20
./scripts/lab/wait-ssh.sh --name cka-cp1

# 2. Record discovered IP in CKA inventory
./scripts/cka/inventory-set-host.sh --name cka-cp1 --discover
# or: ./scripts/cka/inventory-set-host.sh --name cka-cp1 --ip 192.168.x.x

# 3. Converge (connects as ansible user; creates your $USER account)
ansible-playbook -i inventories/cka playbooks/cka-converge.yml --limit cka-cp1

# 4. Optional post-converge checks
ansible-playbook -i inventories/cka tests/integration/test_cka_converged.yml --limit cka-cp1

# 5. SSH as yourself
ssh "$(whoami)@$(ansible-inventory -i inventories/cka --host cka-cp1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["ansible_host"])')"
```

The converge playbook applies [`linux_baseline`](../roles/linux_baseline/) (packages,
hostname, chrony) then [`cka_node`](../roles/cka_node/) (zsh, fzf, htop, etc. + local
user with passwordless sudo). Domain join is not used.

Override the local username when `$USER` is unset (e.g. CI):

```bash
ansible-playbook -i inventories/cka playbooks/cka-converge.yml -e cka_local_user=misnow1
```

## Destroy a node

```bash
./scripts/lab/vm-destroy.sh --name cka-cp1
```

Removes the libvirt domain, qcow2 overlay, and cloud-init seed under
`/var/lib/libvirt/images/home-network-v3/`.

## Relationship to lab.test VMs

| | lab.test (inventory) | CKA (adhoc / vlan3) |
|---|---|---|
| Script | `./scripts/lab/vm-create.sh dc01.lab.test` | `./scripts/lab/vm-create.sh --name … --network vlan3 --dhcp` |
| Network | Isolated libvirt NAT `home-dc-lab` | libvirt network or host bridge `vlan3` |
| IP | Static via cloud-init | DHCP on home VLAN |
| Ansible | `baseline.yml` + domain stack | `cka-converge.yml` (baseline + dev user) |
| DNS search | `lab.test` | None (non-home-dc-lab networks) |

Existing integration tests and inventory hosts are unchanged.

## Troubleshooting

- **Bridge not found** — confirm `ip link show vlan3` on kvm01.
- **Permission denied attaching to bridge** — check `/etc/qemu/bridge.conf` and
  libvirtd restart.
- **wait-ssh times out discovering IP** — guest agent may not be ready; verify the VM
  booted and `qemu-guest-agent` is installed (included in DHCP cloud-init template).
- **No DHCP address** — confirm your VLAN DHCP server is reachable from `vlan3`.
