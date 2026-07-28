# Certbot and Samba LDAP TLS runbook

Slice 10 provisions **per-host FQDN** TLS certificates via the shared `certbot` role.
DC hosts wire certificates into Samba **LDAPS** / **LDAP START-TLS**. Mail relay hosts
reload **Postfix** after renewal.

See also:

- [dc-runbook.md](dc-runbook.md) — DC bootstrap and converge
- [mail-relay-runbook.md](mail-relay-runbook.md) — mail VM TLS + Postfix
- [ddns-runbook.md](ddns-runbook.md) — DDNS API (optional HTTPS front-end)
- [vault-schema.md](vault-schema.md) — `vault_dreamhost_api_key`

## Overview

| Piece | Lab | Production |
|---|---|---|
| Certificate issuer | Local CA (`certbot_provider: local_ca`) | Let's Encrypt DNS-01 via Dreamhost |
| Certbot delivery | OpenSSL in `certbot` role | snap `certbot` + Dreamhost API auth/cleanup hooks |
| Inventory group | `certbot` (children: `dc`; add `mail_relay` for mail VM) | Same |
| Samba TLS | `samba_dc/tasks/tls.yml` via `certbot.yml` on DC hosts | Same |
| Postfix TLS | N/A in lab CI | `certbot_deploy_hook_reload_postfix` on mail relay hosts |
| PEM paths | `/etc/letsencrypt/live/<fqdn>/` | Same (Certbot layout) |
| DDNS nginx TLS | Optional (`ddns_nsupdate_nginx_tls: false` default) | Enable after cert exists |

## Prerequisites

- `dc-converge.yml` completed on the target DC (`smb.conf` must exist)
- Production: `2123studios.com` DNS managed at Dreamhost (ACME TXT in parent zone;
  `home.2123studios.com` stays authoritative on the DC internally)
- Production vault: `vault_dreamhost_api_key` with Dreamhost API `dns-*` permission
  ([Dreamhost API keys](https://panel.dreamhost.com/?tree=home.api))

## Lab

Lab DC group vars enable local CA issuance:

```yaml
certbot_enabled: true
certbot_provider: local_ca
samba_dc_tls_enabled: true
```

```bash
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook playbooks/certbot.yml --limit dc01.lab.test
```

Integration test:

```bash
INTEGRATION_SLICE=certbot ./scripts/test-integration.sh
```

Verify on the DC (trust lab CA):

```bash
LDAPTLS_CACERT=/etc/letsencrypt/local-ca/ca.crt \
  ldapsearch -H ldaps://127.0.0.1 -x -b "" -s base namingContexts
```

## Production deployment

### 1. Inventory and vault

Copy [`inventories/production/group_vars/dc/vars.yml.example`](../inventories/production/group_vars/dc/vars.yml.example)
and set:

```yaml
certbot_enabled: true
certbot_provider: dreamhost_dns
certbot_email: you@2123studios.com
certbot_staging: true   # step 2 — flip false after staging succeeds
samba_dc_tls_enabled: true
```

Add to production vault:

```yaml
vault_dreamhost_api_key: "<dreamhost-api-key>"
```

Preflight the API key from the control node or DC (after first playbook run deploys
`/etc/letsencrypt/dreamhost.env`):

```bash
DREAMHOST_API_KEY='…' ./scripts/certbot/dreamhost-api-check.sh
# or on dc1:
./scripts/certbot/dreamhost-api-check.sh /etc/letsencrypt/dreamhost.env
```

### 2. Staging dry-run (recommended first)

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/certbot.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
```

With `certbot_staging: true`, Certbot uses Let's Encrypt staging CA. Optionally add
`-e certbot_dry_run=true` for a simulated order only.

### 3. Production certificate

Set `certbot_staging: false` in DC group vars, then:

```bash
${PROD} playbooks/certbot.yml -e allow_production=true \
  --limit dc1.home.2123studios.com
```

### 4. Verify LDAPS

From a host that trusts public CAs:

```bash
openssl s_client -connect dc1.home.2123studios.com:636 \
  -servername dc1.home.2123studios.com </dev/null

ldapsearch -H ldaps://dc1.home.2123studios.com -x -b "" -s base namingContexts
```

START-TLS on port 389:

```bash
ldapsearch -H ldap://dc1.home.2123studios.com -ZZ -x -b "" -s base namingContexts
```

## Renewal

Production uses the snap certbot renewal timer (`snap set certbot renew.timer-enabled=on`).

Deploy hook `/etc/letsencrypt/renewal-hooks/deploy/reload-services.sh`:

- `smbcontrol ldap_server reload-certs` (falls back to `systemctl restart samba-ad-dc`)
- Reloads DDNS nginx when `ddns_nsupdate_nginx_tls` is enabled

Manual renewal test:

```bash
sudo certbot renew --dry-run
```

## Optional DDNS API TLS

After `certbot.yml` succeeds on the DC:

1. Set `ddns_nsupdate_nginx_tls: true` in DC group vars
2. Re-run `ddns-api.yml`
3. Update router hook to HTTPS (see [ddns-runbook.md](ddns-runbook.md)) — may need
   `DDNS_CURL_EXTRA_ARGS='--resolve dc1.home.2123studios.com:443:192.168.1.10'`

## Troubleshooting

| Symptom | Check |
|---|---|
| All certbot tasks skipped | `certbot_enabled` in host/group vars for the target |
| DC: Samba TLS assert fails | `samba_dc_tls_enabled` in `group_vars/dc/vars.yml` |
| Issuance skipped, cert already exists | Leftover `/etc/letsencrypt/live/<fqdn>/` from a prior run — use `-e certbot_force_renewal=true` or remove that directory on the DC |
| LDAPS shows staging cert after `certbot_staging: false` | Re-run `certbot.yml` — role deletes mismatched lineage and re-issues against production ACME; or `-e certbot_force_renewal=true` |
| Dreamhost API preflight fails | API key has `dns-*` commands; domain DNS managed at Dreamhost |
| NXDOMAIN for `_acme-challenge.*` | Auth hook failed or TXT never published — check hook output in certbot log; see DNS CNAME note below |
| TXT in panel but LE still fails | Dreamhost NS sync is slow/flaky — auth hook waits until **all** `certbot_dreamhost_validation_resolvers` (default: three Dreamhost NS) serve the TXT, then sleeps `certbot_dreamhost_propagation_settle_seconds` (default 15s). Issuance can take several minutes for six SANs. Retry often succeeds |
| `_acme-challenge.<name>` never appears on NS | Dreamhost accepts the API call but does not publish TXT for some labels. **Fix:** CNAME public hostnames through `bastion.2123studios.com` (like `guacamole`), not directly to `2123studios.noip.me` — `kif.2123studios.com` required this change before production LE would validate |
| Public NS for `home.2123studios.com` | Must **not** delegate to internal DCs — Dreamhost must answer `_acme-challenge` queries |
| Samba TLS assert missing cert | Run `certbot.yml` before expecting LDAPS |
| LDAPS still shows Samba autogenerated cert | TLS block was outside `[global]` — re-run `certbot.yml`; `testparm -s /var/lib/samba/etc/smb.conf \| grep tls certfile` must show `/etc/letsencrypt/live/<fqdn>/fullchain.pem` |
| LDAPS works but clients distrust | Clients need public CA trust (prod) or lab CA installed (lab) |
| Renewal does not reload Samba | Deploy hook executable; `smbcontrol ldap_server reload-certs` on Samba 4.19+ |

## Backup note

`/etc/letsencrypt/` is not in hypervisor backup scope. After initial issuance, archive
`/etc/letsencrypt/` securely or ensure renewal remains functional before DC rebuild.
