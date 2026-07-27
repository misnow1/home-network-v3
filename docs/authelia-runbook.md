# Authelia runbook (manual Docker on kif)

Authelia runs as a **hand-managed** Docker Compose stack on **kif**
(`/srv/docker/authelia`). Ansible only wires nginx forward-auth to Authelia via
`reverse_proxy_authelia_url` — this runbook documents manual changes for HA-related
LDAP and mail settings.

See also:

- [reverse-proxy-runbook.md](reverse-proxy-runbook.md) — nginx forward-auth
- [ldap-vip-runbook.md](ldap-vip-runbook.md) — deploy LDAP VIP before changing Authelia
- [mail-relay-runbook.md](mail-relay-runbook.md) — internal Postfix relay

## Stack layout

| Path | Purpose |
|---|---|
| `/srv/docker/authelia/docker-compose.yml` | Authelia + Valkey (Redis) containers |
| `/srv/docker/authelia/config/configuration.yml` | Authelia config (LDAP, notifier, session) |
| `/srv/docker/authelia/redis/` | Session cache volume (loss = re-login only) |

## LDAP backend — use the VIP

After [ldap-vip-runbook.md](ldap-vip-runbook.md) is deployed and verified, update
`configuration.yml`:

```yaml
authentication_backend:
  ldap:
    address: 'ldaps://ldap.home.2123studios.com'
    implementation: 'activedirectory'
    timeout: '5s'
    # Remove start_tls when using ldaps:// directly:
    # start_tls: true
    tls:
      server_name: ldap.home.2123studios.com
      skip_verify: false
    # ... remaining ldap settings unchanged ...
```

**Before:** Authelia pointed at `ldap://dc1.home.2123studios.com` with STARTTLS — a single-DC
SPOF. **After:** Authelia uses the keepalived VIP; VRRP moves `ldap.home` when dc1 or local
LDAPS fails.

Apply on kif:

```bash
sudo nano /srv/docker/authelia/config/configuration.yml
cd /srv/docker/authelia && sudo docker compose up -d
```

Verify login at `https://auth.2123studios.com` after changing LDAP settings.

## Access control for proxied apps

Authelia `access_control` rules must match every nginx vhost/path with
`auth_required: true`. After changing [reverse_proxy_sites](../inventories/production/group_vars/reverse_proxy/vars.yml.example),
update `/srv/docker/authelia/config/configuration.yml` on kif.

Example rules for the production edge layout (adjust groups to match your AD):

```yaml
access_control:
  default_policy: deny
  rules:
    - domain: auth.2123studios.com
      policy: bypass
    - domain: guacamole.2123studios.com
      policy: one_factor
      subject:
        - "group:domain users"
    - domain:
        - bastion.2123studios.com
        - kif.2123studios.com
      resources:
        - "^/guacamole/.*"
        - "^/transmission/.*"
      policy: one_factor
      subject:
        - "group:domain users"
```

Paperless stays **out** of Authelia: the Paperless-ngx iOS app does not support auth
redirects. Rely on Paperless native credentials, nginx rate limits, and kif Docker
port UFW (bastion-only). See [edge-access-model.md](edge-access-model.md).

Apply on kif:

```bash
sudo nano /srv/docker/authelia/config/configuration.yml
cd /srv/docker/authelia && sudo docker compose up -d
```

### MFA (recommended)

Guacamole grants remote desktop into the LAN — require **two_factor** for Guacamole
rules above when TOTP/WebAuthn is configured for your users:

```yaml
    - domain: guacamole.2123studios.com
      policy: two_factor
```

Review Authelia registration policy and ensure admin-capable AD accounts use MFA.
Password-only AD auth behind Authelia is weaker than Kerberos SSH on the bastion.

## Notifier — use the mail relay (not pdc)

Replace legacy `pdc.home.2123studios.com:25` SMTP with the internal mail relay:

```yaml
notifier:
  smtp:
    address: 'submission://mail.home.2123studios.com:587'
    timeout: '5s'
    sender: "Authelia <admin@auth.2123studios.com>"
    # ... remaining notifier settings ...
    disable_require_tls: false
    disable_starttls: false
```

If primary mail is down, member hosts use Postfix fallback to `mail2`; Authelia on kif should
still reach at least one relay on the LAN. For resilience when **both** relays are down,
Authelia password-reset email simply fails until a relay returns (acceptable for this stack).

Alternatively use plain SMTP on port 587 with TLS:

```yaml
    address: 'smtp://mail.home.2123studios.com:587'
```

Test notifier after change (Authelia admin UI or trigger a password reset flow).

## Session / Redis

Authelia is **functionally stateless** for HA purposes — losing the Valkey volume only
forces users to log in again. Do **not** block LDAP VIP work on Redis volume migration.

Container/host HA for Authelia itself is deferred (ROADMAP) until a more robust container
platform exists.

## Verification checklist

1. `ldapsearch -H ldaps://ldap.home.2123studios.com -x -b "" -s base namingContexts` from kif
2. Authelia container healthy: `docker compose ps` in `/srv/docker/authelia`
3. Login through a proxied site (nginx → Authelia → app)
4. Stop dc1 Samba — confirm Authelia login still works via VIP on dc2
5. Send a test notification (if configured) after notifier SMTP change

## Troubleshooting

| Symptom | Check |
|---|---|
| LDAP bind fails | VIP deployed? Cert SAN includes `ldap.home`? `tls.server_name` matches |
| TLS verify error | Run `openssl s_client -connect ldap.home.2123studios.com:636 -servername ldap.home.2123studios.com` from kif |
| Notifier fails | `mail.home:587` reachable from kif; relay accepts LAN submission |
| Auth works but slow | Normal during VIP failover — VRRP advert interval ~1s |

## Deferred

- Ansible-managed Authelia compose (may revisit when migrating off kif)
- Authelia container HA / volume migration
- Compose-local certbot sidecar — LDAP VIP on DCs is the portable LDAP endpoint instead
