# Edge access model

Public exposure decisions for services proxied through **proxy01** (reverse proxy) and
**shell-clt01** (SSH bastion). Complements [reverse-proxy-runbook.md](reverse-proxy-runbook.md) and
[authelia-runbook.md](authelia-runbook.md).

## Principles

1. **Internet-facing surface stays thin** — SSH (22) on shell-clt01; HTTP/HTTPS (80/443) on proxy01.
2. **Authelia before apps** — admin and data apps require forward-auth unless the app
   provides equivalent auth and public access is intentional.
3. **Proxy backends on VLAN 4** — Docker host ports for proxied apps bind on kif br4
   (`192.168.7.152`) and are UFW-restricted to proxy01's docker NIC only
   (`docker_engine_manage_ufw`).
4. **Recoverability beats obscurity** — scheduled restic + offsite copy (see
   [backup-runbook.md](backup-runbook.md)) is the primary ransomware control.

## Public services (by design)

| Service | FQDN / path | Auth | Rationale |
|---|---|---|---|
| Authelia portal | `auth.2123studios.com` | Login portal itself | Required for SSO |
| Paperless | `paperless.2123studios.com` | Paperless native login | iOS Paperless-ngx app cannot follow Authelia redirects; rate-limited; backend on VLAN 4 only |
| Plex | `plex.2123studios.com` | Plex native auth | Remote streaming for household; large app surface — monitor updates |
| SSH jump | `:22` on shell-clt01 | Kerberos/GSSAPI only | Admin access; fail2ban + no passwords |

## Authelia-protected (public HTTPS)

| Service | FQDN / path | Notes |
|---|---|---|
| Guacamole | `guacamole.2123studios.com`, `bastion.2123studios.com/guacamole`, `kif.2123studios.com/guacamole` | Remote desktop — high risk; MFA recommended |
| Transmission | `bastion.2123studios.com/transmission`, `kif.2123studios.com/transmission` | BitTorrent UI (RPC on VLAN 4; peer port on VLAN 1) |

Access rules live in Authelia `configuration.yml` on kif — see
[authelia-runbook.md](authelia-runbook.md#access-control-for-proxied-apps).

## Transmission exception (Internet peer port)

Transmission needs outbound Internet (trackers/DHT via Docker NAT on br0) and inbound
peer connections (UniFi port-forward to kif VLAN 1). The web UI/RPC stays proxy-only
on VLAN 4:

| Port | Bind address | Exposure |
|---|---|---|
| 9091 (RPC) | `192.168.7.152` | proxy01 only (Authelia) |
| 51413 (peer) | `192.168.1.152` | Internet via UniFi forward |

VLAN 4 remains L2-only (no gateway) — see [adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md).

## VPN-preferred (future tightening)

These apps **can** be moved off public DNS / UniFi port-forwards if remote household
access is not required:

- Guacamole — prefer site-to-site VPN + internal URL for admin-only remote desktop
- Transmission — LAN or VPN only
- Paperless — only if the mobile app is abandoned or gains Authelia/OIDC support

**Plex** is the usual exception if off-LAN streaming is needed.

Implementation when tightening:

1. Remove FQDN from `certbot_domains` / UniFi forwards (or DNS-only internal).
2. Remove or comment the vhost in `reverse_proxy_sites`.
3. Access via VPN with internal DNS (`*.home.2123studios.com`).

## Not on the public edge

| Capability | Host | Exposure |
|---|---|---|
| Samba / NFS data | kif | LAN only (`192.168.1.0/24`, Kerberos) |
| Docker proxy backends | kif | VLAN 4 only (`192.168.7.152`), proxy01 via UFW |
| Transmission peer port | kif | VLAN 1 (`192.168.1.152:51413`), Internet forward |
| AD / LDAP | dc1/dc2 + VIP | LAN only |
| Mail relay | mail/mail2 | Submission from LAN |

## Related controls

| Control | Where |
|---|---|
| nginx TLS + rate limits | `roles/reverse_proxy` on proxy01, `reverse_proxy_rate_limit_zones` |
| Authelia forward-auth | `auth_required: true` in `reverse_proxy_sites` |
| kif Docker port firewall | `docker_engine_manage_ufw` in kif host_vars |
| Scheduled backups + offsite | `roles/backup`, kif host_vars |
| SSH hardening | `roles/bastion` on shell-clt01 |

## Review cadence

Revisit this document when:

- Adding a new proxied container
- Deploying edge VIP HA (Slice 28+) — update `docker_engine_ufw_edge_proxy_cidrs`
- Changing who needs remote access (VPN vs public)
