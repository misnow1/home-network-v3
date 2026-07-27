# Edge access model

Public exposure decisions for services proxied through **shell-clt01** (bastion +
reverse proxy). Complements [reverse-proxy-runbook.md](reverse-proxy-runbook.md) and
[authelia-runbook.md](authelia-runbook.md).

## Principles

1. **Internet-facing surface stays thin** — only SSH (22) and HTTPS (443) on the edge host.
2. **Authelia before apps** — admin and data apps require forward-auth unless the app
   provides equivalent auth and public access is intentional.
3. **Backends not directly reachable** — Docker host ports on kif are UFW-restricted to
   the reverse-proxy host(s) only (`docker_engine_manage_ufw`).
4. **Recoverability beats obscurity** — scheduled restic + offsite copy (see
   [backup-runbook.md](backup-runbook.md)) is the primary ransomware control.

## Public services (by design)

| Service | FQDN / path | Auth | Rationale |
|---|---|---|---|
| Authelia portal | `auth.2123studios.com` | Login portal itself | Required for SSO |
| Paperless | `paperless.2123studios.com` | Paperless native login | iOS Paperless-ngx app cannot follow Authelia redirects; rate-limited; backend port bastion-only |
| Plex | `plex.2123studios.com` | Plex native auth | Remote streaming for household; large app surface — monitor updates |
| SSH jump | `:22` on shell-clt01 | Kerberos/GSSAPI only | Admin access; fail2ban + no passwords |

## Authelia-protected (public HTTPS)

| Service | FQDN / path | Notes |
|---|---|---|
| Guacamole | `guacamole.2123studios.com`, `bastion.2123studios.com/guacamole`, `kif.2123studios.com/guacamole` | Remote desktop — high risk; MFA recommended |
| Transmission | `bastion.2123studios.com/transmission`, `kif.2123studios.com/transmission` | BitTorrent UI |

Access rules live in Authelia `configuration.yml` on kif — see
[authelia-runbook.md](authelia-runbook.md#access-control-for-proxied-apps).

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
| Docker backends | kif | LAN, restricted to reverse-proxy IP via UFW |
| AD / LDAP | dc1/dc2 + VIP | LAN only |
| Mail relay | mail/mail2 | Submission from LAN |

## Related controls

| Control | Where |
|---|---|
| nginx TLS + rate limits | `roles/reverse_proxy`, `reverse_proxy_rate_limit_zones` |
| Authelia forward-auth | `auth_required: true` in `reverse_proxy_sites` |
| kif Docker port firewall | `docker_engine_manage_ufw` in kif host_vars |
| Scheduled backups + offsite | `roles/backup`, kif host_vars |
| SSH hardening | `roles/bastion` |

## Review cadence

Revisit this document when:

- Adding a new proxied container
- Deploying edge VIP HA (Slice 28+) — update `docker_engine_ufw_edge_proxy_cidrs`
- Changing who needs remote access (VPN vs public)
