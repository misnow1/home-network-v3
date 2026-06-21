# Production convergence runbook (Slice 8)

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

For **migrating an existing Samba AD domain**, use `dc-replica-join.yml` (live pdc)
or `dc-restore.yml` (offline backup) instead of step 2 — see
[Migrating existing AD](#migrating-existing-ad) below.

| Step | Host group | Playbook | Notes |
|---|---|---|---|
| 1 | All Linux | `baseline.yml` | Chrony before Kerberos-sensitive work |
| 2 | `dc` | `dc-bootstrap.yml` | **Greenfield only** — once; break-glass |
| 2m | `dc` | `dc-replica-join.yml` | **Migration (preferred)** — join live domain |
| 2r | `dc` | `dc-restore.yml` | **Migration (fallback)** — offline backup |
| 3 | `dc` | `dc-converge.yml` | Ongoing DC + BIND + dnsupdater |
| 4 | `dc` | `ddns-api.yml` | Optional Docker DDNS API for dnsmasq hooks |
| 5 | `hypervisors` | `hypervisor.yml` | libvirt + Docker (Ubuntu only) |
| 6 | `hypervisors` | `backup.yml` | restic client + scope manifest |
| 7 | `fileservers` | `fileserver.yml` | Samba member + winbind |
| 8 | `linux:!dc` | `domain-join.yml` | realmd + sssd members |
| 9 | `ddns_clients` | `ddns-client.yml` | Optional GSS-TSIG update clients |

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
```

Adjust `--limit` to match your inventory. Use `--check` for dry runs where safe
(not for first DC bootstrap or restore).

## Migrating existing AD

When moving from an existing Samba AD DC (e.g. legacy `pdc`) to **dc1/dc2** naming
while keeping `home.2123studios.com` identities:

| Path | Playbook | When |
|---|---|---|
| Greenfield | `dc-bootstrap.yml` | No existing domain — new `sam.ldb` |
| **Migration (preferred)** | **`dc-replica-join.yml`** | Live legacy DC — DRS replication |
| **Migration (fallback)** | **`dc-restore.yml`** | Legacy DC dead — offline backup |

Full phased procedure: **[migration-runbook.md](migration-runbook.md)**.

Pre-flight (read-only):

```bash
./scripts/migration/preflight-check.sh
```

Migration DC sequence (replica join):

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/dc-replica-join.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
${PROD} playbooks/dc-converge.yml -e allow_production=true --limit dc1.home.2123studios.com
${PROD} playbooks/ddns-api.yml -e allow_production=true --limit dc1.home.2123studios.com
${PROD} playbooks/certbot.yml -e allow_production=true --limit dc1.home.2123studios.com
```

Offline restore fallback — set `samba_dc_migration_mode: restore` in `group_vars/dc/vars.yml`:

```bash
${PROD} playbooks/dc-restore.yml -e allow_production=true \
  -e samba_dc_backup_archive=backups/home-ad-backup.tar.bz2 \
  --limit dc1.home.2123studios.com
```

CentOS hosts (`kvm01`, `kif`) are **deferred** — manual DNS cutover only. Ubuntu
members can be reprovisioned and converged with `baseline.yml` → `domain-join.yml`.
Optional `domain-leave.yml` before in-place reprovision.

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

Domain members and file servers receive a static `/etc/resolv.conf` pointing at
AD DNS (`domain_join_dns_servers` / `fileserver_dns_servers`). This replaces the
systemd-resolved stub symlink and persists across reboots.

Netplan-managed or resolved-aware DNS for production is a future enhancement;
until then, declare DC IPs in group/host vars and keep DCs reachable before join
playbooks.

## VM provisioning on kvm01

Production VMs are created on the hypervisor with generic scripts in `scripts/vm/`.
They attach to the pre-existing libvirt network `external-default` (home LAN
192.168.1.0/24). DC hosts use static IPs from inventory; other hosts use DHCP on
that network (DHCP reservations are outside this repo).

One-time on kvm01:

```bash
./scripts/vm/keys-ensure.sh -i production
sudo ./scripts/vm/dirs-ensure.sh -i production
```

Provision a host defined in `inventories/production/hosts.yml` (copy from example).
Production inventory includes encrypted vault vars — `vm-create.sh` needs
`.vault_pass` (same file as `prod-run.sh`):

```bash
./scripts/vm/vm-create.sh -i production dc1.example.home
./scripts/vm/wait-ssh.sh -i production dc1.example.home
```

Then apply playbooks via `prod-run.sh` as below. Destroy when retiring a test VM:

```bash
./scripts/vm/vm-destroy.sh -i production dc1.example.home
```

Host entries need `vm_name` and either `vm_ip` (static) or `vm_use_dhcp: true`.
Network defaults (`vm_gateway`, `vm_dns_servers`, etc.) live in
`group_vars/all/vars.yml`. See [lab-storage.md](lab-storage.md).

The libvirt network `external-default` must already exist on kvm01 — these scripts
do not define it (unlike lab `home-dc-lab`).

## Inventory conventions

| Group | Purpose |
|---|---|
| `dc` | Samba AD DC — name **must** be `dc` (roles assert on `groups['dc']`); hosts named `dc1`, `dc2`, … |
| `hypervisors` | KVM + Docker + backup client |
| `fileservers` | Samba member file servers |
| `ddns_clients` | Hosts that run GSS-TSIG nsupdate |
| `linux` | Parent of member groups (optional organizational group) |
| `deferred` | CentOS/RHEL hosts tracked for migration — not targeted by apt playbooks |

See `inventories/production/hosts.yml.example` and `group_vars/*/vars.yml.example`.

## Slice-specific runbooks

| Slice | Doc |
|---|---|
| DC | [dc-runbook.md](dc-runbook.md) |
| AD migration | [migration-runbook.md](migration-runbook.md) |
| Domain join | [domain-join-runbook.md](domain-join-runbook.md) |
| Hypervisor | [hypervisor-runbook.md](hypervisor-runbook.md) |
| File server | [fileserver-runbook.md](fileserver-runbook.md) |
| DDNS | [ddns-runbook.md](ddns-runbook.md) |
| Certbot / LDAP TLS | [certbot-runbook.md](certbot-runbook.md) |
| Backups | [backup-runbook.md](backup-runbook.md) |

## Deferred (post–Slice 8)

- SFTP/NAS restic repositories and systemd backup timers (lab uses local repo)
- Pi-hole, observability, bare-metal install — see [ROADMAP.md](ROADMAP.md)
