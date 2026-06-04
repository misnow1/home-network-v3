# Hypervisor runbook (Slice 4)

Lab hypervisor hosts run **libvirt/KVM** and **Docker** on Ubuntu 24.04. Slice 4 proves
the stack inside nested `hv01.lab.test` on kvm01 — no production inventory required.

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
| **libvirt** | `qemu-kvm`, libvirtd, default dir pool at `/var/lib/libvirt/images` |
| **Docker** | `docker.io` + Compose v2 plugin |
| **Groups** | `ansible` user added to `libvirt` and `docker` groups |

## Nested virtualization

`hv01.lab.test` is created with `lab_nested_virt: true` (CPU host-passthrough) and
`lab_vm_disk_gb: 32` (libvirt + Docker need more space than the cloud image overlay).
Integration tests assert `/dev/kvm` exists and `virsh -c qemu:///system list` succeeds.

Group membership (`libvirt`, `docker`) takes effect after a new login. Integration tests
use `become` for `virsh`/`docker run` and separately assert the `ansible` user is in
those groups.

## Apply order

1. `baseline.yml` — chrony and base packages
2. `hypervisor.yml` — libvirt + Docker

Domain join is optional for hypervisors and is not part of Slice 4 integration.

## Production

Hypervisor hosts use the `hypervisors` inventory group. Per-host VM/disk declarations
for backups land in Slice 7.
