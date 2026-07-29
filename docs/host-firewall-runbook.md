# Host firewall runbook

Opt-in **UFW** management for multi-service hosts (fileserver, Docker edge,
NUT, NFS, etc.). Replaces the former `docker_engine` UFW tasks so firewall
policy is not tied to the container engine.

**Playbook:** [`playbooks/host-firewall.yml`](../playbooks/host-firewall.yml)  
**Role:** [`roles/host_firewall`](../roles/host_firewall/)  
**Also applied from:** [`playbooks/hypervisor.yml`](../playbooks/hypervisor.yml) when
`host_firewall_enabled: true`

## Why a dedicated role

Enabling UFW with Ubuntu’s stock `DEFAULT_INPUT_POLICY=DROP` without enumerating
LAN services (SMB, NFS, NUT, wsdd, …) silently breaks them. Docker edge
isolation (proxy-only published ports) still belongs in the same policy, but
must not be the only thing the firewall knows about.

## Enable on kif (production)

```yaml
# inventories/production/host_vars/kif.home.2123studios.com/vars.yml
host_firewall_enabled: true
host_firewall_default_incoming: deny
host_firewall_rules:
  # … LAN + internet services — see host_vars example …
host_firewall_edge_proxy_cidrs:
  - 192.168.7.23/32
host_firewall_edge_published_ports:
  - 9191
  - 4080
  - 8000
  - 9091
  - 32400
```

Apply (rules first, then enable — the role always installs allows before
`state: enabled`):

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
HOST=kif.home.2123studios.com

# Stage without enabling (optional dry-run on a fresh host):
# ${PROD} playbooks/host-firewall.yml --limit "${HOST}" -e host_firewall_enable=false

${PROD} playbooks/host-firewall.yml --limit "${HOST}"
# or via hypervisor converge:
${PROD} playbooks/hypervisor.yml --limit "${HOST}" --tags host_firewall
```

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `host_firewall_enabled` | `false` | Master gate |
| `host_firewall_allow_ssh` | `true` | OpenSSH app profile before enable |
| `host_firewall_default_incoming` | `deny` | Incoming default policy |
| `host_firewall_default_outgoing` | `allow` | Outgoing default policy |
| `host_firewall_default_routed` | `null` | Routed policy; null skips |
| `host_firewall_rules` | `[]` | Allow list (`port`, `proto`, optional `src` / `direction`+`interface`, `comment`) |
| `host_firewall_deny_rules` | `[]` | Extra denies (after allows) |
| `host_firewall_edge_proxy_cidrs` | `[]` | Proxy IPs for Docker backends |
| `host_firewall_edge_published_ports` | `[]` | Ports allowed only from proxy CIDRs |
| `host_firewall_edge_deny_unlisted` | `true` | Deny those ports from other sources |
| `host_firewall_enable` | `true` | Activate UFW after rules |

## Ordering guarantees

1. Install `ufw`
2. Allow OpenSSH
3. Apply `host_firewall_rules`
4. Edge proxy allows → edge denies
5. Extra deny rules
6. Default policies
7. Enable UFW

Never enable UFW before SSH and LAN service allows are present.

## LAN services: prefer `in on br0`

Until internal IPv6 addressing is stable (ROADMAP 29+ / ULA), do **not** ACL LAN
services with ISP GUA prefixes. Match ingress interface instead:

```yaml
host_firewall_rules:
  - port: "2049"
    proto: tcp
    direction: in
    interface: br0
    comment: nfs
```

That covers IPv4 `192.168.1.0/24` and whatever GUA is on VLAN 1 without rewriting
rules on PD change. Edge proxy backends stay CIDR-based (`192.168.7.23/32` on br4).

## Validation

```bash
sudo ufw status verbose
# Default: deny (incoming), allow (outgoing)
# Expect OpenSSH, br0 LAN services (NFS/SMB/NUT/wsdd), transmission peer,
# edge proxy allows + denies
```

From a LAN client: NFS mount, SMB share, NUT `upsc`, Windows discovery (wsdd).
From a non-proxy host: Docker backend ports (`9191`, `4080`, …) must be refused.

## Migration from `docker_engine_*_ufw`

| Old | New |
|---|---|
| `docker_engine_manage_ufw` | `host_firewall_enabled` |
| `docker_engine_ufw_allow_rules` | `host_firewall_rules` |
| `docker_engine_ufw_edge_proxy_cidrs` | `host_firewall_edge_proxy_cidrs` |
| `docker_engine_ufw_published_ports` | `host_firewall_edge_published_ports` |
| `docker_engine_ufw_deny_unlisted_published_ports` | `host_firewall_edge_deny_unlisted` |
| `docker_engine_ufw_default_deny` | `host_firewall_default_incoming: deny` |

Bastion still uses its own UFW tasks today; it can switch to this role later.

## Related

- [edge-access-model.md](edge-access-model.md) — which Docker ports are proxy-only
- [nfs-server-runbook.md](nfs-server-runbook.md) — Kerberos NFS on kif
- [fileserver-runbook.md](fileserver-runbook.md) — SMB + wsdd
- [nut-runbook.md](nut-runbook.md) — upsd on LAN
