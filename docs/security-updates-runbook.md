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
| `/etc/needrestart/conf.d/90-ansible.conf` | needrestart overrides — only when `unattended_upgrades_needrestart_manage` |

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

## needrestart and systemd re-exec

After an upgrade of a library that PID 1 maps (`libssl3t64`, `libsystemd0`, glibc),
`needrestart` keys a special `systemd-manager` restart and runs
`/etc/needrestart/restart.d/systemd-manager`, which is just `exec systemctl daemon-reexec`.

On a host where the systemd generator sandbox can stall, that re-exec is **fatal**.
systemd runs its generators in a `(sd-gens)` child after re-exec; if that child does not
finish within the 90 s generator timeout it is killed, systemd treats it as a startup
failure and calls `freeze()`:

```
systemd[1]: Reexecuting requested from client PID 103976 ('systemctl') (unit apt-daily-upgrade.service)...
systemd[1]: Reexecuting.
systemd[1]: Failed to fork off sandboxing environment for executing generators: Protocol error
systemd[1]: Freezing execution.
```

A frozen PID 1 stops serving `org.freedesktop.systemd1`, so **every** D-Bus client waits
out the 25 s activation timeout. Observed symptoms:

- SSH logins take ~60 s (`pam_systemd` → logind → systemd)
- `systemctl` never returns; `systemctl is-system-running` times out
- needrestart's own follow-up restarts all fail with
  `Failed to activate service 'org.freedesktop.systemd1': timed out`
- unattended-upgrades mail ends with `Error: Timeout was reached`

A plain `daemon-reload` survives the same generator timeout — it just takes 90 s
(`Reloading finished in 90227 ms`). Only `daemon-reexec` freezes the manager.

### The guard

Hypervisors set both flags, which drops the `systemd-manager` key before needrestart can
act on it:

```yaml
unattended_upgrades_needrestart_manage: true
unattended_upgrades_needrestart_skip_systemd_manager: true
```

That renders `/etc/needrestart/conf.d/90-ansible.conf`:

```perl
push(@{$nrconf{blacklist_rc}}, qr(^systemd-manager$));
```

Service restarts (sshd, postfix, sssd…) still happen normally; only the PID 1 re-exec is
skipped. **Trade-off:** PID 1 keeps running against the old library until the next boot.
That already matches hypervisor policy — reboots are manual, in a maintenance window.

Verify on the host:

```bash
sudo needrestart -v -r l 2>&1 | grep -i systemd-manager
# expect: needrestart[…]: systemd-manager is blacklisted -> ignored
```

Setting the skip flag back to `false` and re-running the playbook removes the file.

### Recovery from a frozen PID 1

`systemctl reboot` cannot work — it needs the bus. Confirm the diagnosis first:

```bash
busctl --system list | grep org.freedesktop.systemd1   # "(activatable)" with no PID = frozen
sudo cat /proc/1/stack                                 # do_wait / kernel_waitid = freeze() loop
ls -d /run/systemd/generator                           # missing = the generator run never completed
```

A healthy host shows PID 1 owning the bus name and a populated `/run/systemd/generator`.

On a hypervisor, drain the guests first, then force the reboot. Check the surviving half
of each redundant pair (the other Pi-hole, the other mail relay, the other DC) before
stopping anything:

```bash
for vm in $(sudo virsh list --name); do sudo virsh shutdown "$vm"; done
watch sudo virsh list           # wait for every guest to reach "shut off"
sync
sudo systemctl reboot --force   # systemctl kills/unmounts and reboots itself, no PID 1 contact
```

Escalate only if that stalls: `sudo systemctl reboot --force --force`, then as a last
resort `echo s | sudo tee /proc/sysrq-trigger` followed by `u` and `b`.

Post-reboot:

```bash
systemctl is-system-running                            # expect "running"
busctl --system list | grep org.freedesktop.systemd1    # expect PID 1 as owner
sudo virsh list --all
```

### Diagnosing the underlying generator stall

The needrestart guard removes the trigger, not the stall. A host that logs
`Failed to fork off sandboxing environment for executing generators` during a plain
`daemon-reload` still has a latent hang worth chasing — it only stops being fatal.

What the journal on kvm01 established (boots of Jul 17 – Jul 31):

| Observation | Implication |
|---|---|
| Every stall is 90.22 s (`Reloading finished in 90227 ms`, `90226 ms`) | Ended by the fixed 90 s generator timeout, not by a lock releasing |
| No generator logged anything during the window | Whatever blocks, blocks silently — narrowing by log output will not work |
| Requesting client varies: needrestart, `apt-daily-upgrade` (rsyslog postinst), `netplan apply` | Not needrestart-specific; any `daemon-reload` can hit it |
| An immediate retry completes in ~200 ms | Intermittent and state-dependent, so reproduction needs contention |
| kif never reproduces it with an identical generator set | Environmental, not a broken generator binary |

The leading hypothesis is a deadlock against PID 1 itself. The `(sd-gens)` child runs in a
fresh mount namespace, and PID 1 waits on it in `waitid()` while serving no D-Bus and no
autofs requests. Anything a generator does that needs PID 1 therefore blocks for the full
timeout. kvm01's stand-out difference from kif is its PID 1-owned direct autofs triggers on
`/archive` and `/media`. Rule that out first, in a window where a 90 s stall is acceptable:

```bash
systemctl list-units --type=automount            # PID 1-owned triggers
sudo systemctl stop archive.automount media.automount
for i in 1 2 3 4 5; do time sudo systemctl daemon-reload; done
sudo systemctl start archive.automount media.automount
```

Those units come from `nfs_client_static_mount_opts` in
[`roles/nfs_client`](../roles/nfs_client/defaults/main.yml). If stopping them clears the
stalls, the fix is to drop `x-systemd.automount` from that list. Note the deliberate
trade-off documented in [nfs-client-runbook.md](nfs-client-runbook.md): without it, boot
with kif down waits out `x-systemd.mount-timeout=30s` per mount instead of deferring the
mount entirely. `nofail` still keeps the boot from failing.

If the automounts are not the cause, catch the child in the act. Reproduce under
contention, since idle reloads succeed:

```bash
sudo systemd-analyze log-level debug
sudo unattended-upgrade --dry-run &      # create contention
sudo systemctl daemon-reload &
# from a second session while it is stalled:
ps -eo pid,ppid,stat,wchan:32,args | grep -E 'sd-gens|system-generators'
sudo cat /proc/<hung-pid>/stack         # which syscall is blocking
sudo ls -l /proc/<hung-pid>/cwd /proc/<hung-pid>/fd
sudo systemd-analyze log-level info
```

Do not time generators by running them by hand without care —
`/usr/lib/systemd/system-generators/netplan` writes into `/run/systemd/network`.

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
- [ ] Hypervisors: `needrestart -v -r l` reports `systemd-manager is blacklisted -> ignored`
- [ ] Hypervisors: `busctl --system list | grep org.freedesktop.systemd1` shows PID 1 as owner
- [ ] Second `security-updates.yml` run reports `changed=0`

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `unattended_upgrades_enabled` | `true` | Master enable for the role |
| `unattended_upgrades_auto_reboot` | `false` | Reboot after security updates when required |
| `unattended_upgrades_reboot_time` | `03:30` | Reboot window (local time; only when auto-reboot enabled) |
| `unattended_upgrades_mail` | `root` | Recipient; empty string disables mail |
| `unattended_upgrades_mail_report` | `on-change` | `always` / `only-on-error` / `on-change` |
| `unattended_upgrades_needrestart_manage` | `false` | Let the role own `/etc/needrestart/conf.d/90-ansible.conf`; leaves `/etc/needrestart` untouched when false |
| `unattended_upgrades_needrestart_skip_systemd_manager` | `false` | Suppress needrestart's `systemctl daemon-reexec` hook (`true` on hypervisors) |

## Related docs

- [production-runbook.md](production-runbook.md) — apply order
- [bastion-runbook.md](bastion-runbook.md) — edge host hardening includes shared role
- [mail-relay-runbook.md](mail-relay-runbook.md) — root mail rewrite to admin
- [software.md](software.md) — package ownership
- [inventories/README.md](../inventories/README.md) — group conventions
