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
# Copy and edit group_vars/*.example → group_vars/*/vars.yml as needed
# Create inventories/production/group_vars/vault.yml with real secrets
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

Run playbooks in this order for a greenfield site. Re-run individual converge
playbooks idempotently after initial bootstrap.

| Step | Host group | Playbook | Notes |
|---|---|---|---|
| 1 | All Linux | `baseline.yml` | Chrony before Kerberos-sensitive work |
| 2 | `dc` | `dc-bootstrap.yml` | **Once** — destructive first run; break-glass |
| 3 | `dc` | `dc-converge.yml` | Ongoing DC + BIND + dnsupdater |
| 4 | `hypervisors` | `hypervisor.yml` | libvirt + Docker |
| 5 | `hypervisors` | `backup.yml` | restic client + scope manifest |
| 6 | `fileservers` | `fileserver.yml` | Samba member + winbind |
| 7 | `linux:!dc` | `domain-join.yml` | realmd + sssd members |
| 8 | `ddns_clients` | `ddns-client.yml` | Optional GSS-TSIG update clients |

Example sequence after inventory is ready:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/baseline.yml
${PROD} playbooks/dc-bootstrap.yml -e allow_production=true --limit dc.example.home
${PROD} playbooks/dc-converge.yml -e allow_production=true --limit dc.example.home
${PROD} playbooks/hypervisor.yml --limit kvm01.example.home
${PROD} playbooks/backup.yml --limit kvm01.example.home
${PROD} playbooks/fileserver.yml --limit nas.example.home
${PROD} playbooks/domain-join.yml --limit workstation.example.home
```

Adjust `--limit` to match your inventory. Use `--check` for dry runs where safe
(not for first DC bootstrap).

## Break-glass (destructive DC playbooks)

`dc-bootstrap.yml` and `dc-converge.yml` refuse non-lab inventory unless you pass
`-e allow_production=true`. Read [dc-runbook.md](dc-runbook.md) before first
production bootstrap.

```bash
./scripts/prod-run.sh --confirm-production -- \
  playbooks/dc-bootstrap.yml -e allow_production=true --limit dc.example.home
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

## Inventory conventions

| Group | Purpose |
|---|---|
| `dc` | Samba AD DC — name **must** be `dc` (roles assert on `groups['dc']`) |
| `hypervisors` | KVM + Docker + backup client |
| `fileservers` | Samba member file servers |
| `ddns_clients` | Hosts that run GSS-TSIG nsupdate |
| `linux` | Parent of member groups (optional organizational group) |

See `inventories/production/hosts.yml.example` and `group_vars/*/vars.yml.example`.

## Slice-specific runbooks

| Slice | Doc |
|---|---|
| DC | [dc-runbook.md](dc-runbook.md) |
| Domain join | [domain-join-runbook.md](domain-join-runbook.md) |
| Hypervisor | [hypervisor-runbook.md](hypervisor-runbook.md) |
| File server | [fileserver-runbook.md](fileserver-runbook.md) |
| DDNS | [ddns-runbook.md](ddns-runbook.md) |
| Backups | [backup-runbook.md](backup-runbook.md) |

## Deferred (post–Slice 8)

- SFTP/NAS restic repositories and systemd backup timers (lab uses local repo)
- Certbot DNS, Pi-hole, observability, bare-metal install — see [ROADMAP.md](ROADMAP.md)
