# Reverse proxy runbook

Edge nginx reverse proxy with Authelia forward-auth. Terminates TLS for public,
Docker-hosted services and proxies them to backends on **VLAN 4** (Docker edge network).
Containers run on **kif**; the proxy is **proxy01** — a standalone dual-homed VM separate
from the SSH bastion (**shell-clt01**).

**Playbook:** [`playbooks/reverse-proxy.yml`](../playbooks/reverse-proxy.yml)  
**Role:** [`roles/reverse_proxy`](../roles/reverse_proxy/)  
**Inventory group:** `reverse_proxy`

## Architecture

```
Internet ── 80/443 ──> nginx (proxy01 — 192.168.1.23 public)
                           │  docker NIC 192.168.7.23 (vlan4)
                           │  auth_request subrequest
                           ├────────────────────────> Authelia (192.168.7.152:9191)
                           │  proxy_pass host:port
                           └────────────────────────> container backend (192.168.7.152 / kvm01)
```

- One data-driven nginx vhost per proxied app, rendered from `reverse_proxy_sites`.
- Authelia is the auth service (a Docker container on `kif`). This role only wires the
  forward-auth subrequest to it via `reverse_proxy_authelia_url`; it does **not** manage
  the Authelia container or its configuration. LDAP and notifier changes are manual —
  see [authelia-runbook.md](authelia-runbook.md).
- All vhosts share one Let's Encrypt SAN certificate issued by the
  [`certbot`](../roles/certbot/) role on proxy01.
- See [adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md) for VLAN 4 design.

## Prerequisites

Run in order on **proxy01** (standalone — no domain join):

1. [`playbooks/baseline.yml`](../playbooks/baseline.yml)
2. [`playbooks/certbot.yml`](../playbooks/certbot.yml) — issue the SAN certificate (DNS-01)
3. [`playbooks/reverse-proxy.yml`](../playbooks/reverse-proxy.yml)

Hypervisors must have **br4/vlan4** converged before proxy01's docker NIC works —
see [hypervisor-runbook.md](hypervisor-runbook.md) and
[docker-edge-vlan-cutover.md](docker-edge-vlan-cutover.md).

The reverse-proxy host must be in both the `reverse_proxy` and `certbot` inventory groups.
`certbot_domains` must list **every** proxied FQDN; the first entry becomes the
`/etc/letsencrypt/live/<name>` lineage referenced by `reverse_proxy_cert_name`.

## VM provisioning (proxy01)

Dual-homed on kvm01: **external-default** (DHCP → `192.168.1.23`) + **vlan4**
(static `192.168.7.23/24`, no gateway).

```bash
./scripts/vm/vm-create.sh -i production --prepare proxy01.home.2123studios.com
# Create UniFi DHCP reservation: printed MAC -> 192.168.1.23
./scripts/vm/vm-start.sh -i production proxy01.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production proxy01.home.2123studios.com
```

Copy host_vars example:

```bash
cp inventories/production/host_vars/proxy01.home.2123studios.com/vars.yml.example \
   inventories/production/host_vars/proxy01.home.2123studios.com/vars.yml
```

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
| `reverse_proxy_authelia_url` | `""` | Authelia base URL, e.g. `http://192.168.7.152:9191` |
| `reverse_proxy_cert_name` | first site FQDN | Let's Encrypt lineage (`/etc/letsencrypt/live/<name>`) |
| `reverse_proxy_require_cert` | `true` | Fail if the certificate is missing (run certbot first) |
| `reverse_proxy_bootstrap_selfsigned` | `false` | Lab only — self-sign missing lineages so `nginx -t` passes |
| `reverse_proxy_resolvers` | Pi-hole IPs | DNS resolvers for runtime upstream resolution |
| `reverse_proxy_trusted_proxies` | `[]` | Upstream proxy/load-balancer CIDRs allowed to supply `X-Forwarded-For`; keep empty for direct/NAT clients |
| `reverse_proxy_manage_ufw` | `true` | Add UFW allow rules for 80/443 |
| `reverse_proxy_manage_sshd` | `true` | Key-only sshd drop-in for standalone proxy hosts |
| `reverse_proxy_rate_limit_zones` | `[]` | nginx `limit_req_zone` definitions (http context) |
| `reverse_proxy_sites` | `[]` | List of proxied vhosts (schema below) |

Backend URLs in `reverse_proxy_sites` use **static VLAN 4 IPs** (`192.168.7.152`), not
LAN hostnames — the docker NIC on proxy01 has no DNS requirement for backends.

`reverse_proxy_trusted_proxies` controls nginx's **incoming** real-IP trust
boundary; it does not identify proxy01 to Authelia. The role replaces
client-supplied `X-Forwarded-For` with `$remote_addr` before proxying. Do not add
LAN, VLAN 4, proxy01's own `192.168.7.23`, or UniFi NAT ranges unless one of those
addresses is actually an upstream HTTP proxy supplying trusted forwarding
headers.

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
| `rate_limit` | no | Dict: `zone`, `burst`, `nodelay` — references `reverse_proxy_rate_limit_zones` |
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
PROXY=proxy01.home.2123studios.com

# Staging dry-run first (certbot_staging: true), then flip to false and re-issue.
${PROD} playbooks/baseline.yml --limit "${PROXY}"
${PROD} playbooks/certbot.yml --limit "${PROXY}" -e allow_production=true
${PROD} playbooks/reverse-proxy.yml --limit "${PROXY}" -e allow_production=true
```

## Adding a proxied container

1. Publish the container port on kif br4 (`192.168.7.152:PORT`) — see
   [authelia-runbook.md](authelia-runbook.md#docker-compose-port-bindings-vlan-4).
2. Add the port to `docker_engine_ufw_published_ports` and re-converge kif hypervisor/docker.
3. Add an entry to `reverse_proxy_sites` (and the FQDN to `certbot_domains`).
4. Re-run `certbot.yml` so the SAN cert covers the new name.
5. Re-run `reverse-proxy.yml`.

## Security

Edge exposure decisions: [edge-access-model.md](edge-access-model.md).

| Control | Configuration |
|---|---|
| Authelia forward-auth | `auth_required: true` per location; rules in [authelia-runbook.md](authelia-runbook.md) |
| Rate limiting | `reverse_proxy_rate_limit_zones` + `locations[].rate_limit` |
| Backend isolation | kif `docker_engine_manage_ufw` — proxy ports on VLAN 4 only from proxy01 |
| TLS | SAN cert via certbot DNS-01; HSTS on all vhosts |
| sshd | Key-only on proxy01 (`reverse_proxy_manage_sshd`) |

Production example enables Authelia on Guacamole (all paths) and Transmission RPC.
Paperless and Plex stay public with native app auth — Paperless because the iOS
Paperless-ngx app cannot follow Authelia redirects (see [edge-access-model.md](edge-access-model.md)).

After changing `auth_required`, update Authelia `access_control` on kif and re-run
`reverse-proxy.yml`.

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
- [ ] `rate-limit-zones.conf` present when zones configured
- [ ] `ufw status` — 80/tcp and 443/tcp allowed
- [ ] From proxy01: `curl -s http://192.168.7.152:9191/api/health` succeeds
- [ ] Protected vhost redirects unauthenticated users to Authelia
- [ ] Second `reverse-proxy.yml` run reports `changed=0`

## Migration from shell-clt01 combined host

Previously nginx and certbot ran on **shell-clt01** alongside the bastion role.
After cutover, shell-clt01 is bastion-only; proxy01 handles all public HTTPS.
See [docker-edge-vlan-cutover.md](docker-edge-vlan-cutover.md) for the ordered migration.

## Related docs

- [bastion-runbook.md](bastion-runbook.md) — SSH jump host (separate VM)
- [edge-access-model.md](edge-access-model.md) — public vs Authelia-protected services
- [certbot-runbook.md](certbot-runbook.md) — SAN certificate issuance
- [docker-edge-vlan-cutover.md](docker-edge-vlan-cutover.md) — production migration steps
- [software.md](software.md) — package list
