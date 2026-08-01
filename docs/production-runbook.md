# Production convergence runbook

How to apply home-network-v3 playbooks against real hosts using the production
inventory and `scripts/prod-run.sh` guardrails.

Lab development and integration tests use `inventories/lab/` only — never point
CI or `./scripts/test-integration.sh` at production.

## Prerequisites

1. Control node with repo checkout, Python venv, and collections installed
   (`requirements.txt`, `requirements.yml`).
2. SSH access as `ansible` (or override `remote_user`) to production hosts.
3. Production vault password in `.vault_pass` (mode `600`) — see
   [vault-schema.md](vault-schema.md). Do **not** reuse `.vault_pass_lab`.
4. Production inventory copied from templates:

```bash
cp inventories/production/hosts.yml.example inventories/production/hosts.yml
cp inventories/production/group_vars/all/ansible.yml.example \
   inventories/production/group_vars/all/ansible.yml
# Copy and edit group_vars/*.example → group_vars/*/vars.yml as needed
# Create inventories/production/group_vars/all/vault.yml with real secrets
```

5. Hostnames, groups, and `ansible_host` values filled in for your fleet.

## Production wrapper (required)

Never run `ansible-playbook -i inventories/production` directly. The wrapper:

- Requires `--confirm-production`
- Verifies `inventories/production/hosts.yml` exists
- Forces production vault (`.vault_pass`) — refuses lab vault fallback
- Logs stdout/stderr to `logs/prod-run-*.log`

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit nas.example.home
```

Dry validation (wrapper refuses without confirmation):

```bash
./scripts/test-prod-safety.sh
```

## Apply order

Run playbooks in this order for a **greenfield** site. Re-run individual converge
playbooks idempotently after initial bootstrap.

For **joining an existing Samba AD domain** (replica DC or offline restore), use
`dc-replica-join.yml` or `dc-restore.yml` instead of step 2 — see
[Joining additional DCs](#joining-additional-dcs) below.

| Step | Host group | Playbook | Notes |
|---|---|---|---|
| 1 | All Linux | `baseline.yml` | Chrony before Kerberos-sensitive work |
| 1s | All Linux | `security-updates.yml` | Fleet unattended security patching; also the needrestart/systemd re-exec guard on hypervisors — [security-updates-runbook.md](security-updates-runbook.md) |
| 2 | `dc` | `dc-bootstrap.yml` | **Greenfield only** — once; break-glass |
| 2m | `dc` | `dc-replica-join.yml` | Join existing domain — replica DC |
| 2r | `dc` | `dc-restore.yml` | Join existing domain — offline backup restore |
| 3 | `dc` | `dc-converge.yml` | Ongoing DC + BIND + dnsupdater |
| 4 | `dc` | `ddns-api.yml` | Optional Docker DDNS API for dnsmasq hooks |
| 4p | `pihole` | `pihole-converge.yml` | Config-only Pi-hole → dc1/dc2 forwarding — [pihole-runbook.md](pihole-runbook.md) |
| 5 | `hypervisors` | `hypervisor.yml` | libvirt + Docker (Ubuntu only); optional `host_firewall` when enabled |
| 6 | `hypervisors` | `backup.yml` | restic client + scope manifest + optional systemd timer/offsite copy |
| 7 | `fileservers` | `fileserver.yml` | Samba member + winbind; kif multi-share when `fileserver_samba_enabled: true` — [fileserver-runbook.md](fileserver-runbook.md) |
| 7n | `fileservers` (opt-in) | `nfs-server.yml` | Kerberos NFS exports on kif when `nfs_server_enabled` — [nfs-server-runbook.md](nfs-server-runbook.md); run **before** step 8n |
| 8 | `linux:!dc` | `domain-join.yml` | realmd + sssd members (`domain_join_enabled: false` on proxy01; EL bastion skips AD tasks) |
| 8n | `linux:!dc` (opt-in) | `nfs-client.yml` | After domain-join when `nfs_client_enabled` — [nfs-client-runbook.md](nfs-client-runbook.md) |
| 9 | `bastion` | `bastion.yml` | Edge hardening (after domain-join) — [bastion-runbook.md](bastion-runbook.md) |
| 10 | `ddns_clients` | `ddns-client.yml` | Optional GSS-TSIG update clients |

Example **greenfield** sequence after inventory is ready:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/baseline.yml
${PROD} playbooks/dc-bootstrap.yml -e allow_production=true --limit dc1.example.home
${PROD} playbooks/dc-converge.yml -e allow_production=true --limit dc1.example.home
${PROD} playbooks/hypervisor.yml --limit kvm01.example.home
${PROD} playbooks/backup.yml --limit kvm01.example.home
${PROD} playbooks/fileserver.yml --limit kif.example.home
${PROD} playbooks/domain-join.yml --limit bastion.example.home
${PROD} playbooks/bastion.yml --limit bastion.example.home
```

Adjust `--limit` to match your inventory. Use `--check` for dry runs where safe
(not for first DC bootstrap or restore).

## Joining additional DCs

When adding a DC to an **existing** Samba AD domain (remote site, dc2, disaster
recovery), use replica join or offline restore — not `dc-bootstrap.yml`.

| Path | Playbook | When |
|---|---|---|
| Greenfield | `dc-bootstrap.yml` | No existing domain — new `sam.ldb` |
| **Replica join** | **`dc-replica-join.yml`** | Live peer DC — DRS replication |
| **Offline restore** | **`dc-restore.yml`** | No live peer — backup tarball |

See **[dc-runbook.md](dc-runbook.md)** and **[ad-sites.md](ad-sites.md)**.

Pre-flight (read-only):

```bash
./scripts/migration/preflight-check.sh
```

Replica join sequence:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/dc-replica-join.yml -e allow_production=true \
  --limit dc2.home.2123studios.com
${PROD} playbooks/dc-converge.yml -e allow_production=true --limit dc2.home.2123studios.com
```

Offline restore — set `samba_dc_migration_mode: restore` in `group_vars/dc/vars.yml`:

```bash
${PROD} playbooks/dc-restore.yml -e allow_production=true \
  -e samba_dc_backup_archive=backups/home-ad-backup.tar.bz2 \
  --limit dc1.home.2123studios.com
```

Ubuntu members can be reprovisioned and converged with `baseline.yml` → `domain-join.yml`.
Optional `domain-leave.yml` before in-place reprovision. Non-Ubuntu VMs (e.g. Pi-hole)
will be **repaved as Ubuntu** and converged — not in-place migrated.

**Never** run `dc-bootstrap.yml` on a host with `samba_dc_migration_host: true`.

## Break-glass (destructive DC playbooks)

`dc-bootstrap.yml`, `dc-restore.yml`, and `dc-converge.yml` refuse non-lab inventory unless you pass
`-e allow_production=true`. Read [dc-runbook.md](dc-runbook.md) before first
production DC work.

```bash
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-bootstrap.yml -e allow_production=true --limit dc1.example.home
```

Normal converge playbooks (`baseline.yml`, `hypervisor.yml`, `fileserver.yml`,
etc.) do **not** require `allow_production` — only the wrapper confirmation.

## DNS on members and file servers

**Domain join (sssd members):** By default the role does **not** touch
`/etc/resolv.conf`. Hypervisors and other members that get AD DNS from DHCP
(systemd-resolved) should keep `domain_join_manage_resolv_conf: false` (default).

Set `domain_join_manage_resolv_conf: true` and `domain_join_dns_servers` only when
the host cannot resolve the domain yet (e.g. lab nested VMs, or bootstrap before a
new DC is reachable on the LAN).

**Samba file servers (winbind):** When `fileserver_manage_resolv_conf` is true and
`fileserver_dns_servers` is set, the fileserver role may replace the resolved stub
with a static `/etc/resolv.conf` pointing at AD DNS.

Netplan-managed or resolved-aware DNS for production is a future enhancement.

## VM provisioning on kvm01

Production VMs are created on the hypervisor with generic scripts in `scripts/vm/`.
They attach to the pre-existing libvirt network `external-default` (home LAN
192.168.1.0/24). `vm_network` in `group_vars/all/vars.yml` is the default libvirt
network. A per-NIC `network` value overrides it for VM attachment only; it is never
written into guest Netplan.

One-time on kvm01:

```bash
./scripts/vm/keys-ensure.sh -i production
sudo ./scripts/vm/dirs-ensure.sh -i production
```

### Static IP VMs (dc1, dc2, mail, …)

Host entries need `vm_name`, matching `ansible_host`, and an `ethernets` list:

```yaml
ethernets:
  - network: external-default      # optional; defaults to vm_network
    macaddress: 52:54:00:ab:cd:ef  # optional libvirt-only MAC pin
    dhcp6: true
    addresses: [192.168.1.10/24]
    nameservers: [192.168.1.1]
    routes:
      - to: default
        via: 192.168.1.1
```

`network` and `macaddress` are consumed by libvirt and deliberately omitted from
the guest Netplan file.

```bash
./scripts/vm/vm-create.sh -i production dc1.example.home
./scripts/vm/wait-ssh.sh -i production dc1.example.home
```

### Reserved DHCP VMs (bastion, build hosts, …)

Set `ansible_host` to the **intended reservation IP** (not the live lease). Omit
`ethernets` for the traditional default of one `dhcp4` + `dhcp6` NIC on
`vm_network`, or specify it explicitly. Optional `macaddress` pins the NIC;
otherwise virt-install generates it and the create manifest prints an
inventory-ready `ethernets` block.

```bash
# 1. Define VM with fixed MAC — does not boot
./scripts/vm/vm-create.sh -i production --prepare bastion.example.home
# Optional: pause until you create the UniFi reservation
./scripts/vm/vm-create.sh -i production --prepare --wait-reservation bastion.example.home

# 2. Create DHCP reservation on router: MAC (printed) -> ansible_host IP

# 3. Boot and wait for cloud-init
./scripts/vm/vm-start.sh -i production bastion.example.home
./scripts/vm/wait-ssh.sh -i production bastion.example.home
```

Immediate boot without `--prepare` still works for lab-style hosts but warns on
production DHCP entries (race with router reservations). Pass
`--force-boot` to suppress the warning.

### Ephemeral DHCP (IP does not matter)

Boot first, discover the lease, then update inventory (not recommended for bastion —
DDNS registers the first lease):

```bash
./scripts/vm/vm-create.sh -i production --force-boot build01.example.home
./scripts/vm/wait-ssh.sh -i production build01.example.home
./scripts/vm/inventory-set-host.sh -i production --fqdn build01.example.home --discover
```

Then apply playbooks via `prod-run.sh` as below. Destroy when retiring a test VM:

```bash
./scripts/vm/vm-destroy.sh -i production dc1.example.home
```

Host entries need `vm_name`. Omitted `ethernets` means dual-stack DHCP; static or
multi-NIC hosts define `ethernets`. The `vm_network` libvirt default lives in
`group_vars/all/vars.yml`. `wait-ssh.sh` reports every address returned by
`virsh domifaddr <name> --source agent`. See [lab-storage.md](lab-storage.md).

The libvirt network `external-default` must already exist on kvm01 — these scripts
do not define it (unlike lab `home-dc-lab`).

## Inventory conventions

| Group | Purpose |
|---|---|
| `dc` | Samba AD DC — name **must** be `dc` (roles assert on `groups['dc']`); hosts named `dc1`, `dc2`, … |
| `hypervisors` | KVM + Docker + backup client |
| `fileservers` | Samba member file servers |
| `bastion` | Edge jump hosts — sshd/GSSAPI, UFW, fail2ban; security updates via shared role |
| `ddns_clients` | Hosts that run GSS-TSIG nsupdate |
| `linux` | Parent of Ubuntu apt-managed groups — `baseline.yml`, `security-updates.yml` |
| `deferred` | Legacy or transitional hosts — not targeted by default apt playbooks (empty post-migration) |

See `inventories/production/hosts.yml.example` and `group_vars/*/vars.yml.example`.

## Related runbooks

| Topic | Doc |
|---|---|
| DC | [dc-runbook.md](dc-runbook.md) |
| AD sites | [ad-sites.md](ad-sites.md) |
| Domain join | [domain-join-runbook.md](domain-join-runbook.md) |
| AD user SSH keys | [ad-ssh-public-keys.md](ad-ssh-public-keys.md) |
| Hypervisor | [hypervisor-runbook.md](hypervisor-runbook.md) |
| Host firewall | [host-firewall-runbook.md](host-firewall-runbook.md) |
| File server | [fileserver-runbook.md](fileserver-runbook.md) |
| Bastion | [bastion-runbook.md](bastion-runbook.md) |
| Security updates | [security-updates-runbook.md](security-updates-runbook.md) |
| Pi-hole | [pihole-runbook.md](pihole-runbook.md) |
| Mail relay | [mail-relay-runbook.md](mail-relay-runbook.md) |
| Reverse proxy | [reverse-proxy-runbook.md](reverse-proxy-runbook.md) |
| Edge access model | [edge-access-model.md](edge-access-model.md) |
| DDNS | [ddns-runbook.md](ddns-runbook.md) |
| Certbot / LDAP TLS | [certbot-runbook.md](certbot-runbook.md) |
| Backups | [backup-runbook.md](backup-runbook.md) |

See [ROADMAP.md](ROADMAP.md) for slice status and deferred work.
