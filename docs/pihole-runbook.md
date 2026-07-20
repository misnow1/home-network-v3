# Pi-hole DNS runbook (Slice 10+)

Production ad/malware filtering with Pi-hole in front of clients, while **dc1/dc2
remain authoritative** for `home.2123studios.com` via BIND DLZ.

See also:

- [dns-architecture.md](dns-architecture.md) — BIND DLZ, DDNS pipeline, DC ACLs
- [unifi-gateway-dns.md](unifi-gateway-dns.md) — UCG DHCP, dhcp-script wrapper (unchanged)
- [ddns-runbook.md](ddns-runbook.md) — lease-driven DDNS to dc1
- [remote-site-dns.md](remote-site-dns.md) — no Pi-hole changes in this slice

## Architecture

```
DHCP client ──(option 6)──► Pi-hole (.18 + .22)
                              ├─ AD zones ──► dc1/dc2 BIND
                              └─ public ──► blocklists + upstream (1.1.1.1, 8.8.8.8)
UCG dnsmasq ──(dhcp-script only)──► DDNS API on dc1 ──► BIND
```

**Do not:**

- List dc1/dc2 as secondary client DNS (Windows bypasses Pi-hole)
- Point `dc_dns_forwarders` at Pi-hole (loop risk; hides per-client stats)
- Use the router (192.168.1.1) as a DNS resolver for clients

## Hosts

| Host | IP | Hypervisor | OS | Notes |
|---|---|---|---|---|
| pihole-1.home.2123studios.com | 192.168.1.18 | kif | Ubuntu 24.04 | Repave second (after pihole-2) |
| pihole-2.home.2123studios.com | 192.168.1.22 | kvm01 | Ubuntu 24.04 | Repave first |

Hosts are in the `linux` and `pihole` inventory groups. SSH as `ansible` after
`baseline.yml` + `domain-join.yml`. Pi-hole is installed by Ansible (`pihole_install:
true`) during `pihole-converge.yml`.

## Ubuntu repave (CentOS/Rocky → 24.04)

Repave **pihole-2 first** (kvm01), then **pihole-1** (kif). One host stays up for
client DNS during each cycle.

Inventory needs `vm_name`, `vm_memory_mb`, and `vm_disk_gb` (8 GB is sufficient).
Pi-hole NICs use dual-stack DHCP with router reservations. Pin `macaddress` under
`ethernets` to preserve the reservation across repaves; `network` is the libvirt
network name and is not copied into guest Netplan. Run `vm-create` on the host
hypervisor:

```bash
# On kvm01 — pihole-2 (do this host first)
./scripts/vm/vm-destroy.sh -i production pihole-2.home.2123studios.com
./scripts/vm/vm-create.sh -i production pihole-2.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production pihole-2.home.2123studios.com

# On kif — pihole-1 (after pihole-2 is converged)
./scripts/vm/vm-destroy.sh -i production pihole-1.home.2123studios.com
./scripts/vm/vm-create.sh -i production pihole-1.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production pihole-1.home.2123studios.com
```

Post-repave converge (each host):

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/baseline.yml --limit pihole-2.home.2123studios.com
${PROD} playbooks/domain-join.yml --limit pihole-2.home.2123studios.com
${PROD} playbooks/nfs-client.yml --limit pihole-2.home.2123studios.com   # optional homedirs only
${PROD} playbooks/pihole-converge.yml -e allow_production=true \
  -e pihole_install=true --limit pihole-2.home.2123studios.com
```

`pihole_install=true` pre-seeds `/etc/pihole/pihole.toml` (with `dns.upstreams` and
`misc.etc_dnsmasq_d`) then runs the official installer **without** `--unattended`.
Pi-hole v6 treats an existing `pihole.toml` as pre-configured and skips the ncurses
wizard — see [unattended installation for v6.x](https://discourse.pi-hole.net/t/unattended-installation-for-v6-x/78295).
The `--unattended` flag is unreliable on v6 when `pihole.toml` is absent
([thread](https://discourse.pi-hole.net/t/does-pihole-v6-no-longer-supports-unattended-for-automated-install/81741/2)).

Repeat with `pihole-1` after pihole-2 validates. Cloud-init `ansible` user is used after
domain-join (no `ansible.yml` root override).

## Discovery (before first converge)

Requires **Pi-hole v6** (`/etc/pihole/pihole.toml`). The Ansible role refuses v5-only installs.

On each Pi-hole host (as root):

```bash
pihole version
test -f /etc/pihole/pihole.toml && echo ok || echo "missing pihole.toml — upgrade required"
pihole-FTL --config misc.etc_dnsmasq_d 2>/dev/null || true
pihole-FTL --config dns.upstreams 2>/dev/null || true
pihole-FTL --config dns.revServers 2>/dev/null || true
grep -rh '^server=' /etc/dnsmasq.d/ 2>/dev/null || true
```

| Setting | Purpose |
|---|---|
| `/etc/pihole/pihole.toml` | v6 config (required) |
| `misc.etc_dnsmasq_d` | must be `true` for `/etc/dnsmasq.d/05-ad-zones.conf` |
| `dns.revServers` | cleared by Ansible (replaced by dnsmasq `server=/zone/` lines) |
| `/etc/dnsmasq.d/05-ad-zones.conf` | AD + reverse forwarding to dc1/dc2 |

Pi-hole v6 **ignores** `/etc/dnsmasq.d` until `misc.etc_dnsmasq_d` is enabled —
the Ansible role sets this automatically.

## DNS query handling (FTL vs Conditional Forwarding)

Pi-hole v6 has two overlapping mechanisms. **Ansible uses dnsmasq
`server=/` lines** (`05-ad-zones.conf`) for AD — not the Web UI **Conditional
Forwarding** (`dns.revServers`).

| Web UI / FTL setting | Ansible variable | Production value | Why |
|---|---|---|---|
| Never forward non-FQDN queries | `dns.domainNeeded` | `false` (OFF) | Short names can be resolved via AD forward zones |
| Never forward reverse private | `dns.bogusPriv` | `false` (OFF) | PTR for RFC1918 must reach dc1/dc2 via `server=/…in-addr.arpa/` |
| Conditional forwarding | `dns.revServers` | `[]` (disabled) | Replaced by `05-ad-zones.conf`; do not duplicate in UI |
| Interface listening mode | `dns.listeningMode` | `SINGLE` | Accept IoT VLAN clients (192.168.3.x) routed to Pi-hole on 192.168.1.x |
| Listen interface | `dns.interface` | primary NIC (`enp1s0`) | Used with `SINGLE` — not `ALL` (open resolver risk) |

**Do not** enable Conditional Forwarding in the Web UI for each subnet. Instead,
list every reverse zone hosted on the DCs in `pihole_reverse_zones` (match
`samba_dc_reverse_zones` in `group_vars/dc/vars.yml`). Ansible emits one
`server=/zone/dc` line per zone per DC, for example:

| Subnet | Reverse zone |
|---|---|
| VLAN 1 `192.168.1.0/24` | `1.168.192.in-addr.arpa` |
| VLAN 2 `192.168.3.0/24` | `3.168.192.in-addr.arpa` |
| Remote Woodbine | `33.168.192.in-addr.arpa` (only if DC hosts the zone) |
| Remote Swanhollow | `65.168.192.in-addr.arpa` (only if DC hosts the zone) |

VLAN 3 (`192.168.5.0/24`) does not use Pi-hole — no zone entry required unless
that changes.

**Top Clients hostnames:** Pi-hole is not the DHCP server. Client names in the
dashboard come from **PTR** (reverse zones above → DC) and **AD A/AAAA** records,
not from `revServers`. UniFi client names still come from the dhcp-script hook on
the UCG, not from Pi-hole DNS.

**`LOCAL` vs `SINGLE`:** `LOCAL` only accepts queries from subnets that match a
local interface address. IoT clients source `192.168.3.x` to Pi-hole at
`192.168.1.18` — rejected under `LOCAL`. `SINGLE` listens on `enp1s0` and accepts
any source routed to that NIC (still internal-only; do not use `ALL` on WAN-facing
hosts).

## Prerequisites

1. `dc-converge.yml` completed on dc1 and dc2 (BIND DLZ authoritative)
2. `ddns-api.yml` on dc1 — DDNS API healthy:

   ```bash
   curl -fsS "http://192.168.1.10:8765/ddns/v1/health"
   ```

3. Production inventory includes `pihole` group — copy templates:

   ```bash
   cp inventories/production/group_vars/pihole/vars.yml.example \
      inventories/production/group_vars/pihole/vars.yml
   # Add pihole hosts to inventories/production/hosts.yml
   ```

4. Web UI password in vault (`vault_pihole_web_password`) — see [vault-schema.md](vault-schema.md):

   ```bash
   ansible-vault edit inventories/production/group_vars/all/vault.yml \
     --vault-password-file .vault_pass
   ```

5. SSH to both Pi-hole VMs — cloud-init `ansible` user after Ubuntu repave.

## Ansible converge

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/pihole-converge.yml -e allow_production=true
```

**What the role configures:**

| Item | Path / mechanism |
|---|---|
| AD zone forwarding | `/etc/dnsmasq.d/05-ad-zones.conf` + `misc.etc_dnsmasq_d=true` |
| FTL query policy | `dns.domainNeeded=false`, `dns.bogusPriv=false`, `dns.revServers=[]` |
| Listen mode | `dns.listeningMode=SINGLE`, `dns.interface` = primary NIC |
| Upstream public DNS | `pihole-FTL --config dns.upstreams` |
| Disable UI conditional forwarding | `dns.revServers=[]` |
| Static local names (optional) | `/etc/pihole/custom.list` from `pihole_local_dns_records` |
| Web UI / API password | `pihole setpassword` when `vault_pihole_web_password` differs (API check) |
| Reload | `pihole reloaddns` handler |

Optional blocklist refresh:

```bash
${PROD} playbooks/pihole-converge.yml -e allow_production=true --tags pihole_gravity \
  -e pihole_update_gravity=true
```

## Pre-cutover verification

From the control node:

```bash
./scripts/pihole/cutover-check.sh --phase pre
```

Manual checks:

```bash
dig @192.168.1.18 dc1.home.2123studios.com A +short          # → 192.168.1.10
dig @192.168.1.18 _ldap._tcp.home.2123studios.com SRV +short
dig @192.168.1.18 doubleclick.net A +short                  # blocked / empty
dig @192.168.1.10 home.2123studios.com SOA +short           # authoritative on DC
```

Compare `/etc/dnsmasq.d/05-ad-zones.conf` on both Pi-hole hosts — must be identical.

## Static DNS audit (UniFi → Pi-hole)

Before cutover, export **UniFi Local DNS Records** (Settings → Internet → DNS → Local
DNS Records) and any legacy router hostnames.

For each static name not registered via AD DDNS:

1. Prefer AD static A on dc1 for domain-joined infrastructure
2. Otherwise add to `pihole_local_dns_records` in `group_vars/pihole/vars.yml`:

   ```yaml
   pihole_local_dns_records:
     - name: printer.home.2123studios.com
       ip: 192.168.1.50
   ```

3. Re-run `pihole-converge.yml`
4. Verify: `dig @192.168.1.18 printer.home.2123studios.com A +short`

After migration, **retire** router-local DNS records — clients no longer query the UCG
for resolution.

## Cutover procedure

### 1. Converge Pi-hole (both hosts)

Run `pihole-converge.yml` and `./scripts/pihole/cutover-check.sh --phase pre`.

### 2. Test from a pilot client (before DHCP change)

On one workstation, set DNS manually to 192.168.1.18. Confirm AD login, internal
hostnames, and blocked domains. Revert DNS when done.

### 3. UniFi UI — DHCP DNS (VLAN 1)

1. UniFi Network → **Settings** → **Networks** → Default LAN → **DHCP**
2. Set **DHCP DNS Server** to **192.168.1.18** and **192.168.1.22** only
3. Apply; renew leases on sample clients (`dhclient`, reboot, or `ipconfig /renew`)

**Do not** change the dhcp-script wrapper — see [unifi-gateway-dns.md](unifi-gateway-dns.md).

### 4. Validate VLAN 1

```bash
./scripts/pihole/cutover-check.sh --phase post
```

Confirm:

- Pi-hole dashboard shows **client IPs** (not dc1)
- UniFi client list still shows hostnames (from dhcp-script, not DNS)
- DDNS: renew lease → `dig @192.168.1.10 <hostname>.home.2123studios.com A`

### 5. UniFi UI — IoT VLAN 2

Same DHCP DNS servers (.18 + .22). See [unifi-gateway-dns.md](unifi-gateway-dns.md)
multi-VLAN section.

### 6. Retire router DNS forwarding

Remove legacy on-boot scripts that inject `server=/home.2123studios.com/` to dc1/dc2
(e.g. `07-create-local-dns-conf.sh`). Remove runtime files:

```bash
rm -f /run/dnsmasq.dhcp.conf.d/local_custom_dns.conf
kill "$(cat /run/dnsmasq-main.pid)"
```

The router must **not** answer client DNS for AD zones anymore — Pi-hole forwards
directly to dc1/dc2.

### 7. VLAN 3 (restricted)

No changes — stays on router/public DNS; not in `dc_trusted_networks`.

## IPv6

Ansible sets `resolver.resolveIPv6` when `pihole_enable_ipv6: true` in
`group_vars/pihole/vars.yml`. Listening mode is set by `ftl_dns.yml` (not IPv6-only).
Upstream resolvers and `ip6.arpa` reverse zones are already configured.

**Prerequisite:** hosts need GUA addresses (ISP prefix delegation). When PD is broken,
`cutover-check.sh --phase ipv6` warns that no AAAA exists in AD — that is expected
until leases renew with v6.

When PD works:

1. Confirm Pi-hole hosts receive GUA (DDNS or static AAAA on dc1)
2. UniFi DHCPv6 **RDNSS** → `192.168.1.18` and `192.168.1.22` — see
   [unifi-gateway-dns.md](unifi-gateway-dns.md)
3. Re-run `pihole-converge.yml` and validate:

   ```bash
   ./scripts/pihole/cutover-check.sh --phase ipv6
   ```

## Remote sites

No changes in this slice. Woodbine/Swanhollow keep router conditional forwarders to
dc1/dc2 — see [remote-site-dns.md](remote-site-dns.md).

## Rollback

1. UniFi UI — set DHCP DNS back to **dc1** (192.168.1.10) and **dc2** (192.168.1.11)
2. Optionally restore router `server=/` on-boot scripts from `.disabled` backups
3. Renew client leases
4. Pi-hole config can remain — clients simply stop using it

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AD auth fails via Pi-hole | Missing `_msdcs` or SRV forwarding | Check `05-ad-zones.conf`; `dig SRV` via Pi-hole |
| Pi-hole shows only dc1 IP as client | Clients still use DC as DNS | Fix DHCP option 6; remove DC secondary DNS |
| Internal names NXDOMAIN | Static names still on router | Migrate to `pihole_local_dns_records` |
| dnsmasq.d ignored | `misc.etc_dnsmasq_d=false` | Re-run converge; confirm `misc.etc_dnsmasq_d=true` |
| Short names fail | `dns.domainNeeded=true` or missing AD forward | Re-run converge; use FQDN `host.home.2123studios.com` |
| PTR / Top Clients show IPs only | `dns.bogusPriv=true` or missing reverse zone | Re-run converge; verify `pihole_reverse_zones` |
| IoT VLAN DNS fails | `listeningMode=LOCAL` | Use `SINGLE` + primary interface (role default) |
| DDNS broken | dhcp-script wrapper removed/changed | Restore [unifi-gateway-dns.md](unifi-gateway-dns.md) wrapper |

## Pi-hole Web UI notes

- **Do not** enable Conditional Forwarding if it duplicates `05-ad-zones.conf`
- Upstream DNS: set `pihole_upstream_providers` (e.g. `Cloudflare (DNSSEC)`,
  `Google (ECS, DNSSEC)`) so Settings → DNS checkboxes stay checked; Ansible expands
  to canonical addresses in `dns.upstreams`
- Blocklists apply to non-forwarded queries; AD zones pass through to DCs
