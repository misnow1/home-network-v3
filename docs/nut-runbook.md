# NUT / UPS runbook (Slice 21+)

Ansible-managed UPS monitoring via the `nut_ups` role and `playbooks/nut-converge.yml`.

See also:

- [vault-schema.md](vault-schema.md) — monitor and Pushover secrets
- [mail-relay-runbook.md](mail-relay-runbook.md) — Postfix relay client prerequisite
- [hypervisor-runbook.md](hypervisor-runbook.md) — production hypervisor converge

## Prerequisites

1. **baseline.yml** on the host (chrony, packages).
2. **Postfix relay client** when email notifications are enabled:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/domain-join.yml --limit kif.home.2123studios.com --tags domain_mail_relay
```

3. Production vault keys (see [vault-schema.md](vault-schema.md)).
4. Host variables — copy
   [`inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example`](../inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example)
   to `vars.yml` and customize.

## Converge

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/nut-converge.yml --limit kif.home.2123studios.com --check
${PROD} playbooks/nut-converge.yml --limit kif.home.2123studios.com
```

Tags: `nut_packages`, `nut_config`, `nut_notify`, `nut_services`.

## Verify on host

```bash
upsc -l
upsc kifups ups.status
systemctl is-active nut-server nut-monitor nut-driver@kifups
sudo /etc/nut/upssched-cmd online-notify   # smoke-test email + Pushover
```

## Device variables

Each UPS in `nut_ups_devices`:

| Field | usbhid-ups | snmp-ups |
|---|---|---|
| `name` | upsd name (`kifups`) | upsd name |
| `driver` | `usbhid-ups` | `snmp-ups` |
| `port` | `auto` or `/dev/...` | SNMP host IP |
| `enabled` | `true`/`false` | disable broken SNMP until fixed |
| `options` | `pollinterval`, `offdelay`, … | `community`, `snmp_version`, … |

## Netserver + remote clients (kvm01)

kif runs **netserver** with ACL-limited `LISTEN` on the host LAN IP.

Document-only netclient example for a secondary host:

```ini
# /etc/nut/nut.conf
MODE=netclient

# /etc/nut/upsmon.conf
MONITOR kifups@kif.home.2123studios.com 1 upsmon-remote <vault-password> slave
MINSUPPLIES 0
```

A dedicated `nut_client` role is deferred.

## Enable livingroomups (SNMP)

When the SNMP card is repaired:

1. Set `enabled: true` on the `livingroomups` device in host_vars.
2. Add a monitor entry or rely on auto-generated monitors.
3. Re-run `nut-converge.yml`.
4. Confirm `upsc livingroomups ups.status`.
