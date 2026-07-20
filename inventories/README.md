# Inventories

Ansible inventory layout for lab, production, and CKA environments.

## Environments

| Path | Purpose | Committed |
|---|---|---|
| [`lab/`](lab/) | Integration tests, CI, `./scripts/test-integration.sh` | Yes — living inventory |
| [`production/`](production/) | Real fleet — `scripts/prod-run.sh` only | Templates only (`*.example`); live files gitignored |
| [`cka/`](cka/) | Ad-hoc CKA practice VMs on vlan3 | `hosts.yml.example` only; live `hosts.yml` gitignored |

Default inventory in [`ansible.cfg`](../ansible.cfg): `inventories/lab`.

See [docs/ROADMAP.md](../docs/ROADMAP.md) for slice status and
[docs/production-runbook.md](../docs/production-runbook.md) for apply order.

## Production bootstrap

```bash
cp inventories/production/hosts.yml.example inventories/production/hosts.yml
cp inventories/production/group_vars/all/ansible.yml.example \
   inventories/production/group_vars/all/ansible.yml
# Copy group_vars/*/vars.yml.example → vars.yml as needed
# Create inventories/production/group_vars/all/vault.yml — see docs/vault-schema.md
```

Never commit `hosts.yml`, `vars.yml`, `vault.yml`, or `ansible.yml` under
`inventories/production/` (enforced by structural tests).

## Inventory groups

| Group | Purpose | Playbooks |
|---|---|---|
| `dc` | Samba AD DC — name **must** be `dc` | `dc-bootstrap.yml`, `dc-replica-join.yml`, `dc-converge.yml`, `ddns-api.yml` |
| `hypervisors` | KVM + Docker + backup client | `hypervisor.yml`, `backup.yml` |
| `fileservers` | Samba member file servers (winbind) | `fileserver.yml` |
| `nut_servers` | NUT UPS monitoring | `nut-converge.yml` |
| `bastion` | Edge jump hosts | `bastion.yml` (after domain-join) |
| `reverse_proxy` | nginx + Authelia edge proxy | `reverse-proxy.yml`, `certbot.yml` |
| `mail_relay` | Internal Postfix relay VM | `mail-relay.yml`, `certbot.yml` |
| `pihole` | Pi-hole DNS forwarders (config-only) | `pihole-converge.yml` |
| `certbot` | Hosts needing DNS-01 certificates | `certbot.yml` |
| `linux_members` | Domain-joined members (sssd) | `domain-join.yml`, `nfs-client.yml` |
| `windows` | Windows guests (not Ansible-managed) | `vm-create.sh` (`vm_perf_profile: windows11`) |
| `linux` | Parent of Ubuntu apt-managed groups | `baseline.yml` |
| `deferred` | Legacy/transitional — empty post-migration | None by default |

Pi-hole hosts are **not** in `linux` — they use curl-installed Pi-hole on
CentOS/Rocky today and will be **repaved as Ubuntu** rather than in-place migrated.

## Template → runbook index

| Template | Runbook |
|---|---|
| `hosts.yml.example` | [production-runbook.md](../docs/production-runbook.md) |
| `group_vars/dc/vars.yml.example` | [dc-runbook.md](../docs/dc-runbook.md), [ad-sites.md](../docs/ad-sites.md) |
| `group_vars/linux/vars.yml.example` | [domain-join-runbook.md](../docs/domain-join-runbook.md), [bastion-runbook.md](../docs/bastion-runbook.md) |
| `group_vars/hypervisors/vars.yml.example` | [hypervisor-runbook.md](../docs/hypervisor-runbook.md), [nfs-client-runbook.md](../docs/nfs-client-runbook.md) |
| `group_vars/pihole/*.example` | [pihole-runbook.md](../docs/pihole-runbook.md) |
| `group_vars/reverse_proxy/vars.yml.example` | [reverse-proxy-runbook.md](../docs/reverse-proxy-runbook.md) |
| `group_vars/mail_relay/vars.yml.example` | [mail-relay-runbook.md](../docs/mail-relay-runbook.md) |
| `group_vars/fileservers/vars.yml.example` | [fileserver-runbook.md](../docs/fileserver-runbook.md) |
| `host_vars/kif.../vars.yml.example` | [nut-runbook.md](../docs/nut-runbook.md), [hypervisor-runbook.md](../docs/hypervisor-runbook.md) |
| `host_vars/kvm01.../vars.yml.example` | [hypervisor-runbook.md](../docs/hypervisor-runbook.md) |
| `host_vars/cka-sim.../vars.yml.example` | [software.md](../docs/software.md), [cka-runbook.md](../docs/cka-runbook.md) |
## Platform policy

- **Ubuntu 24.04 LTS** for all apt-managed `linux` hosts
- Remaining non-Ubuntu VMs → repave as Ubuntu, then converge with existing playbooks
- Production hypervisors **kif** and **kvm01** are Ubuntu-managed (Slice 19 complete)
- **kvm01** and **kif** are development hypervisors — repo checkout + `.venv` + `hypervisor.yml` dev tools
- Legacy **pdc** is retired; dc1/dc2 are authoritative
