# Security updates runbook

Fleet-wide Ubuntu security patching via `unattended-upgrades`. Security and ESM
origins install automatically; automatic reboot is **opt-in** per inventory group or
host so redundant services never reboot in the same window.

**Playbook:** [`playbooks/security-updates.yml`](../playbooks/security-updates.yml)  
**Role:** [`roles/unattended_upgrades`](../roles/unattended_upgrades/)  
**Inventory group:** `linux` (all Ubuntu apt-managed hosts)

## Prerequisites

Run after [`playbooks/baseline.yml`](../playbooks/baseline.yml) on each host. Re-run
`security-updates.yml` idempotently anytime inventory policy changes.

Bastion hosts also receive the shared role from [`playbooks/bastion.yml`](../playbooks/bastion.yml)
after domain join — see [bastion-runbook.md](bastion-runbook.md).

## What the role configures

| File | Purpose |
|---|---|
| `/etc/apt/apt.conf.d/20auto-upgrades` | Daily apt update + unattended upgrade |
| `/etc/apt/apt.conf.d/50unattended-upgrades` | Security/ESM origins, kernel cleanup, mail, reboot policy |

Security origins only — no full `-updates` dist-upgrade. Kernel package cleanup is
enabled when unused kernels are superseded.

## Email notifications

Matches the prior CentOS/Rocky pattern: mail `root` when packages change (or a reboot
is needed). Delivery path:

```
unattended-upgrades → local Postfix (mail -s / sendmail)
  → mail.home / mail2 (smtp_fallback_relay)
  → virtual_alias_maps: root@<host>.home… → vault_mail_default_recipient
```

Defaults: `unattended_upgrades_mail: root`, `unattended_upgrades_mail_report: on-change`.

| MailReport | Behavior |
|---|---|
| `on-change` | Email when packages are installed or a reboot is required (default) |
| `only-on-error` | Email only on failure |
| `always` | Email after every run |

**Prerequisite:** host must be able to send outbound mail — typically
`mail_relay_client_enabled: true` via `domain-join.yml` (members/hypervisors/bastion)
or the mail-relay VMs themselves. See [mail-relay-runbook.md](mail-relay-runbook.md).

Disable mail with `unattended_upgrades_mail: ""`.

## Production apply

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

# Fleet-wide (after baseline has run at least once)
${PROD} playbooks/security-updates.yml

# Staged rollout — one redundancy tier at a time
${PROD} playbooks/security-updates.yml --limit dc2.home.2123studios.com
${PROD} playbooks/security-updates.yml --limit dc1.home.2123studios.com
${PROD} playbooks/security-updates.yml --limit 'pihole:&linux'
${PROD} playbooks/security-updates.yml --limit 'mail_relay:&linux'
${PROD} playbooks/security-updates.yml --limit bastion.example.home
${PROD} playbooks/security-updates.yml --limit 'linux_members:&linux'
${PROD} playbooks/security-updates.yml --limit 'hypervisors:&linux'
```

Reboot windows use **host local time** (`linux_baseline_timezone`, default
`America/New_York`).

## Maintenance window matrix

Stagger redundant peers by ≥30 minutes. Example production schedule:

| Tier | Host(s) | Reboot time | Auto-reboot | Notes |
|---|---|---|---|---|
| 1 | dc2 (BACKUP) | 02:00 | yes | LDAP VIP fails over to dc1 |
| 1 | dc1 (MASTER) | 02:45 | yes | After dc2 window |
| 2 | pihole-2 (kvm01) | 03:00 | yes | One DNS forwarder remains |
| 2 | pihole-1 (kif) | 03:45 | yes | After pihole-2 |
| 3 | bastion | 03:30 | yes | Edge jump host |
| 4 | mail2 (kif) | 04:00 | yes | Fallback relay |
| 4 | mail (kvm01) | 04:30 | yes | Primary relay |
| 5 | linux_members | 04:30 | yes | Low blast radius |
| 6 | kif, kvm01 (hypervisor OS) | — | **no** | Reboot stops all local VMs |

Guest VMs (dc, mail, pihole, bastion) patch and reboot **inside** their own OS.
Hypervisor bare-metal reboots are **manual** — updates install but
`/var/run/reboot-required` records pending maintenance.

Inventory examples:

- Fleet defaults: [`group_vars/linux/vars.yml.example`](../inventories/production/group_vars/linux/vars.yml.example)
- Bastion: [`group_vars/bastion/vars.yml.example`](../inventories/production/group_vars/bastion/vars.yml.example)
- DC / Pi-hole / mail stagger: per-host `host_vars/*/vars.yml.example`

## Hypervisor manual reboot

When `/var/run/reboot-required` exists on kif or kvm01:

1. Confirm no other hypervisor maintenance is in progress.
2. Check guest VM placement — each hypervisor hosts critical VMs (see
   [production-runbook.md](production-runbook.md)).
3. Schedule a maintenance window; migrate or accept guest downtime.
4. Reboot during low-traffic period; verify libvirt, Docker, and critical guests.

Do **not** enable `unattended_upgrades_auto_reboot` on hypervisor hosts until
live migration or drain automation exists.

## HA validation after changes

After the first production rollout on each tier, run existing smoke tests:

| Pair | Validation |
|---|---|
| dc1 + dc2 | [ldap-vip-runbook.md](ldap-vip-runbook.md) — VIP failover smoke test |
| pihole-1 + pihole-2 | [pihole-runbook.md](pihole-runbook.md) — client DNS resolution |
| mail + mail2 | [mail-relay-runbook.md](mail-relay-runbook.md) — delivery with primary stopped |

## Disable or roll back

Set in inventory and re-run the playbook:

```yaml
unattended_upgrades_enabled: false
```

Or disable automatic reboot only:

```yaml
unattended_upgrades_auto_reboot: false
```

Emergency break-glass on a single host:

```bash
sudo systemctl stop unattended-upgrades.service
sudo rm /etc/apt/apt.conf.d/20auto-upgrades
```

Restore by re-running `security-updates.yml`.

## Lab integration

```bash
# Fleet default (auto_reboot false) on a fileserver VM
INTEGRATION_SLICE=security_updates LAB_HOST=nas01.lab.test ./scripts/test-integration.sh

# Bastion auto-reboot policy via bastion group_vars
INTEGRATION_SLICE=bastion LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

## Validation checklist

- [ ] `dpkg -s unattended-upgrades` succeeds
- [ ] `/etc/apt/apt.conf.d/20auto-upgrades` enables periodic upgrades
- [ ] `/etc/apt/apt.conf.d/50unattended-upgrades` lists `-security` origins
- [ ] `Automatic-Reboot` matches inventory on each host
- [ ] `Unattended-Upgrade::Mail "root"` and `MailReport "on-change"` present
- [ ] Smoke: `echo test | mail -s "security-updates smoke $(hostname)" root` reaches admin inbox
- [ ] Redundant peers have non-overlapping reboot windows
- [ ] Hypervisors show `Automatic-Reboot "false"`
- [ ] Second `security-updates.yml` run reports `changed=0`

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `unattended_upgrades_enabled` | `true` | Master enable for the role |
| `unattended_upgrades_auto_reboot` | `false` | Reboot after security updates when required |
| `unattended_upgrades_reboot_time` | `03:30` | Reboot window (local time; only when auto-reboot enabled) |
| `unattended_upgrades_mail` | `root` | Recipient; empty string disables mail |
| `unattended_upgrades_mail_report` | `on-change` | `always` / `only-on-error` / `on-change` |

## Related docs

- [production-runbook.md](production-runbook.md) — apply order
- [bastion-runbook.md](bastion-runbook.md) — edge host hardening includes shared role
- [mail-relay-runbook.md](mail-relay-runbook.md) — root mail rewrite to admin
- [software.md](software.md) — package ownership
- [inventories/README.md](../inventories/README.md) — group conventions
