# Reverse proxy runbook

Edge nginx reverse proxy with Authelia forward-auth. Terminates TLS for public,
Docker-hosted services and proxies them to LAN backends (containers run on `kif`;
the proxy is a separate hardened edge host, typically the bastion).

**Playbook:** [`playbooks/reverse-proxy.yml`](../playbooks/reverse-proxy.yml)  
**Role:** [`roles/reverse_proxy`](../roles/reverse_proxy/)  
**Inventory group:** `reverse_proxy`

## Architecture

```
Internet ── 443 ──> nginx (reverse_proxy host)
                      │  auth_request subrequest
                      ├────────────────────────> Authelia (kif:9191)
                      │  proxy_pass host:port
                      └────────────────────────> container backend (kif / other LAN host)
```

- One data-driven nginx vhost per proxied app, rendered from `reverse_proxy_sites`.
- Authelia is the auth service (a Docker container on `kif`). This role only wires the
  forward-auth subrequest to it via `reverse_proxy_authelia_url`; it does **not** manage
  the Authelia container or its configuration.
- All vhosts share one Let's Encrypt SAN certificate issued by the
  [`certbot`](../roles/certbot/) role.

## Prerequisites

Run in order on the proxy host:

1. [`playbooks/baseline.yml`](../playbooks/baseline.yml)
2. [`playbooks/domain-join.yml`](../playbooks/domain-join.yml)
3. [`playbooks/bastion.yml`](../playbooks/bastion.yml) — hardening + UFW (enables the firewall)
4. [`playbooks/certbot.yml`](../playbooks/certbot.yml) — issue the SAN certificate (DNS-01)
5. [`playbooks/reverse-proxy.yml`](../playbooks/reverse-proxy.yml)

The reverse-proxy host must be in both the `reverse_proxy` and `certbot` inventory groups.
`certbot_domains` must list **every** proxied FQDN; the first entry becomes the
`/etc/letsencrypt/live/<name>` lineage referenced by `reverse_proxy_cert_name`.

## Configuration

Copy the example and edit:

```bash
cp inventories/production/group_vars/reverse_proxy/vars.yml.example \
   inventories/production/group_vars/reverse_proxy/vars.yml
```

Key variables (full list in [`roles/reverse_proxy/defaults/main.yml`](../roles/reverse_proxy/defaults/main.yml)):

| Variable | Default | Purpose |
|---|---|---|
| `reverse_proxy_enabled` | `false` | Master enable for the playbook/role |
| `reverse_proxy_authelia_url` | `""` | Authelia base URL, e.g. `http://kif.home.2123studios.com:9191` |
| `reverse_proxy_cert_name` | first site FQDN | Let's Encrypt lineage (`/etc/letsencrypt/live/<name>`) |
| `reverse_proxy_require_cert` | `true` | Fail if the certificate is missing (run certbot first) |
| `reverse_proxy_bootstrap_selfsigned` | `false` | Lab only — self-sign missing lineages so `nginx -t` passes |
| `reverse_proxy_resolvers` | DC IPs | DNS resolvers for runtime upstream resolution |
| `reverse_proxy_trusted_proxies` | LAN CIDRs | `set_real_ip_from` for Authelia trusted proxies |
| `reverse_proxy_manage_ufw` | `true` | Add UFW allow rules for 80/443 |
| `reverse_proxy_sites` | `[]` | List of proxied vhosts (schema below) |

### Site schema

Each entry in `reverse_proxy_sites`:

| Field | Required | Purpose |
|---|---|---|
| `name` | yes | Identifier + `conf.d/<name>.conf` filename |
| `server_names` | yes | List of `server_name` values |
| `cert_name` | no | Override the shared lineage for this vhost |
| `hsts` | no | Emit HSTS header (default `reverse_proxy_hsts_enabled`) |
| `gzip` | no | Enable gzip (useful for Plex-style apps) |
| `client_max_body_size` | no | e.g. `100M` for large uploads |
| `authelia_location` | no | Force-include the Authelia authz endpoint (auto-enabled when any location needs auth) |
| `upstreams` | no | List of `upstream {}` blocks (`name`, `servers`, `keepalive`, `extra`) |
| `extra_server_config` | no | Raw directives at server scope (escape hatch) |
| `locations` | yes | List of location blocks |

Each `locations` entry:

| Field | Required | Purpose |
|---|---|---|
| `path` | yes | e.g. `/`, `= /`, `/guacamole` |
| `proxy_pass` | no | Upstream URL to proxy to |
| `return` | no | e.g. `301 /guacamole/` (instead of proxying) |
| `auth_required` | no | Include Authelia forward-auth for this location |
| `websocket` | no | Add `Upgrade`/`Connection` headers |
| `include_proxy_snippet` | no | Include shared `proxy.conf` (default `true`) |
| `extra_config` | no | Raw directives inside the location (escape hatch) |

See the [example group_vars](../inventories/production/group_vars/reverse_proxy/vars.yml.example)
for the full production layout (Authelia portal, Guacamole, Paperless, Plex, Transmission).

## TLS

The `certbot` role issues one SAN certificate for all `certbot_domains` via DNS-01
(Dreamhost). On renewal, the certbot deploy hook reloads nginx when
`certbot_deploy_hook_reload_nginx: true` is set in the `reverse_proxy` group vars.

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
PROXY=shell-clt01.home.2123studios.com

# Staging dry-run first (certbot_staging: true), then flip to false and re-issue.
${PROD} playbooks/certbot.yml --limit "${PROXY}" -e allow_production=true
${PROD} playbooks/reverse-proxy.yml --limit "${PROXY}" -e allow_production=true
```

## Adding a proxied container

1. Add an entry to `reverse_proxy_sites` (and the FQDN to `certbot_domains`).
2. Re-run `certbot.yml` so the SAN cert covers the new name.
3. Re-run `reverse-proxy.yml`.

## Lab integration

```bash
INTEGRATION_SLICE=reverse_proxy LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

The lab fixture uses loopback upstreams and a self-signed bootstrap certificate
(`reverse_proxy_bootstrap_selfsigned: true`), so no certbot run is required.

## Validation checklist

- [ ] `nginx -t` succeeds
- [ ] `systemctl is-active nginx` — active
- [ ] Each vhost file present under `/etc/nginx/conf.d/`
- [ ] Snippets present in `/etc/nginx/snippets/` (`proxy.conf`, `authelia-location.conf`, `authelia-authrequest.conf`)
- [ ] `ufw status` — 80/tcp and 443/tcp allowed
- [ ] Protected vhost redirects unauthenticated users to Authelia
- [ ] Second `reverse-proxy.yml` run reports `changed=0`

## Migration from bastion-el9 (complete)

The legacy CentOS `bastion-el9` ran this nginx layout by hand (per-vhost files under
`/etc/nginx/conf.d/`, shared snippets, a single SAN cert via the certbot nginx plugin).
Production reverse proxy runs on **shell-clt01.home.2123studios.com**, reproducing the
layout from `reverse_proxy_sites` with DNS-01 TLS (no port-80 dependency).

## Related docs

- [bastion-runbook.md](bastion-runbook.md) — host hardening the proxy sits on
- [certbot-runbook.md](certbot-runbook.md) — SAN certificate issuance
- [software.md](software.md) — package list
