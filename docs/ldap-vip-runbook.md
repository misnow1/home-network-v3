# LDAP VIP runbook (keepalived on DC pair)

Floating **LDAP/LDAPS** endpoint at **`ldap.home.2123studios.com`** (`192.168.1.12`) on the
Samba AD DC pair. Authelia and other single-URL LDAP clients connect here; VRRP moves the
VIP when a DC host or local LDAPS fails.

See also:

- [dc-runbook.md](dc-runbook.md) — DC converge and certbot
- [certbot-runbook.md](certbot-runbook.md) — Dreamhost DNS-01, multi-domain SAN certs
- [authelia-runbook.md](authelia-runbook.md) — point Authelia at the VIP (manual)

## Architecture

| Component | Detail |
|---|---|
| VIP | `192.168.1.12` — reserve in UniFi DHCP (no VM uses this IP) |
| DNS | AD A record `ldap.home.2123studios.com` → `.12` (Ansible `dns_ldap_vip.yml`) |
| VRRP | keepalived on dc1 (MASTER, priority 100) and dc2 (BACKUP, priority 90) |
| Health check | Local LDAPS on `127.0.0.1:636` with `-servername ldap.home…` must verify |
| TLS | Each DC cert includes `ldap.home.2123studios.com` SAN via certbot |
| Packet path | On MASTER, nftables DNAT `VIP:389/636` → this DC’s primary IP (`ldap_vip_backend_ip`) |

Samba uses `bind interfaces only` and only binds addresses present when it starts. The VIP
appears later via keepalived, so Samba never listens on `.12` itself. Instead, keepalived
`notify_master` installs nftables DNAT so clients hitting the VIP reach Samba on the DC’s
real address — no Samba restart, no risk of `samba_dnsupdate` registering the VIP as `dc1`
/`dc2`.

When kvm01/dc1 is down, dc2 takes the VIP, installs its own DNAT, and serves LDAPS with a
valid `ldap.home` cert.

## Prerequisites

1. Both DCs converged (`dc-converge.yml`) with `ldap_vip_enabled: true` in `group_vars/dc/`.
2. Per-DC `host_vars` with `certbot_domains` (DC FQDN + `ldap.home.2123studios.com`) and
   keepalived role (`ldap_vip_state` / `ldap_vip_priority`).
3. UniFi: exclude `192.168.1.12` from DHCP pool or add a static reservation that never
   assigns it to a client.

## Inventory variables

**`group_vars/dc/vars.yml`:**

```yaml
ldap_vip_enabled: true
ldap_vip_address: 192.168.1.12
ldap_vip_hostname: ldap.home.2123studios.com
```

**`host_vars/dc1.home.2123studios.com/vars.yml`:**

```yaml
certbot_domains:
  - dc1.home.2123studios.com
  - ldap.home.2123studios.com
ldap_vip_state: MASTER
ldap_vip_priority: 100
```

**`host_vars/dc2.home.2123studios.com/vars.yml`:**

```yaml
certbot_domains:
  - dc2.home.2123studios.com
  - ldap.home.2123studios.com
ldap_vip_state: BACKUP
ldap_vip_priority: 90
```

## Deployment

Issue or renew DC certs **before** relying on the LDAPS health check (check script requires
valid `ldap.home` SAN):

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/certbot.yml -e allow_production=true \
  --limit 'dc1.home.2123studios.com,dc2.home.2123studios.com'

${PROD} playbooks/dc-converge.yml -e allow_production=true \
  --limit 'dc1.home.2123studios.com,dc2.home.2123studios.com'
```

## Verification

```bash
# VIP should appear on dc1 normally
ip addr show | grep 192.168.1.12

# DNAT should be present on the MASTER
sudo nft list table ip ldap_vip

dig +short @192.168.1.10 ldap.home.2123studios.com A

# From another host (or the DC) — must succeed without Samba listening on .12
openssl s_client -connect ldap.home.2123studios.com:636 \
  -servername ldap.home.2123studios.com </dev/null \
  | openssl x509 -noout -subject -ext subjectAltName

ldapsearch -H ldaps://ldap.home.2123studios.com -x -b "" -s base namingContexts

# Samba should NOT list the VIP (ss -ltn 'sport = :636' shows primary + lo only)
ss -ltn 'sport = :636'
```

**Failover smoke test** — stop Samba on dc1 (or power off kvm01):

```bash
# VIP should move to dc2; DNAT table follows
ssh dc2.home.2123studios.com 'ip addr show | grep 192.168.1.12; nft list table ip ldap_vip'
openssl s_client -connect ldap.home.2123studios.com:636 \
  -servername ldap.home.2123studios.com </dev/null
```

## Troubleshooting

| Symptom | Check |
|---|---|
| VIP on neither DC | `systemctl status keepalived`; health script `/usr/local/sbin/check-ldaps-vip.sh` |
| VIP up but LDAPS to `.12` fails | `nft list table ip ldap_vip` on MASTER; `journalctl -t ldap-vip-notify`; confirm Samba listens on primary IP `:636` |
| Health check fails | Cert must include `ldap.home` SAN — run `certbot.yml` then `dc-converge.yml` |
| VIP registered as `dc1`/`dc2` A record | Should not happen with DNAT (Samba never binds VIP); prune excludes VIP from allowed IPs |
| Authelia auth fails | Authelia must use `ldaps://ldap.home…` (not dc1 FQDN); see authelia-runbook |
| Split-brain / flapping | VRRP `auth_pass` must match on both DCs; check network between dc1/dc2 |

## Deferred

- Certificate remaining-lifetime monitoring — observability slice (ROADMAP)
- If Authelia stack migrates off kif, the VIP endpoint remains portable; revisit compose-local
  cert/proxy patterns only for services colocated with Authelia
