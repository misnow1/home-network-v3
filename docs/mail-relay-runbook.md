# Internal mail relay runbook (Slice 16+)

Replace **pdc** as the internal→external SMTP relay. Outbound server mail (cron, alerts)
relays through **Postfix in Docker on kif**, published at **`mail.home.2123studios.com`**, and
forwards to **Gmail** with pdc-equivalent sender rewrite rules.

See also:

- [migration-runbook.md](migration-runbook.md) — pdc decommission checklist
- [certbot-runbook.md](certbot-runbook.md) — Dreamhost DNS-01 (reuse for mail TLS on kif)
- [vault-schema.md](vault-schema.md) — Gmail app password variables

## Architecture

| Component | Location |
|---|---|
| Relay container | kif — `/srv/docker/mail-relay/` |
| DNS A + MX | AD DNS on dc1 (Ansible `dns_mail_relay.yml`) |
| Member `relayhost` | Ansible `domain_join` role when `mail_relay_enabled: true` |
| Upstream | Gmail SMTP (`smtp.gmail.com:587`) with app password |

Sender rewrite (replicates pdc `/etc/postfix/sender_rewrite`):

```
root@kif.home.2123studios.com  →  root-kif@2123studios.com  (envelope)
```

Root mail delivery is centralized on the relay (`virtual_alias_maps`) — retire per-host
`/root/.forward` files once aliases are verified.

## Prerequisites

1. **Audit pdc** before shutdown — copy `/etc/postfix/` and note dependent hosts:

```bash
ssh pdc.home.2123studios.com 'sudo tar czf - /etc/postfix' > pdc-postfix-backup.tgz
```

2. Production vault (`inventories/production/group_vars/all/vault.yml`):

```yaml
vault_mail_gmail_user: you@gmail.com
vault_mail_gmail_app_password: "<app-password>"
vault_mail_default_recipient: you@gmail.com
```

3. DC group vars (`inventories/production/group_vars/dc/vars.yml`):

```yaml
mail_relay_dns_enabled: true
mail_relay_hostname: mail.home.2123studios.com
mail_relay_target_ip: 192.168.1.30   # kif IP
```

4. Linux member group vars (when ready to cut over):

```yaml
mail_relay_enabled: true
mail_relay_hostname: mail.home.2123studios.com
mail_relay_manage_root_forward: true   # optional: remove /root/.forward
```

## Step 1 — TLS certificate on kif

Issue a Let's Encrypt certificate for `mail.home.2123studios.com` using Dreamhost DNS-01
(same approach as dc1 — see [certbot-runbook.md](certbot-runbook.md)).

On kif (manual until kif is Ansible-managed):

```bash
# Install certbot snap if needed; use Dreamhost API credentials from vault
sudo certbot certonly --manual --preferred-challenges dns \
  -d mail.home.2123studios.com \
  --agree-tos -m you@2123studios.com
# Or reuse dreamhost certbot hooks from roles/certbot/files/ if copied to kif
```

Certs must exist at:

```
/etc/letsencrypt/live/mail.home.2123studios.com/fullchain.pem
/etc/letsencrypt/live/mail.home.2123studios.com/privkey.pem
```

Add a renewal deploy hook to reload the container:

```bash
# /etc/letsencrypt/renewal-hooks/deploy/reload-mail-relay.sh
#!/bin/bash
docker compose -f /srv/docker/mail-relay/docker-compose.yml up -d --force-recreate
```

## Step 2 — Deploy relay container on kif

Copy the repo project to kif:

```bash
rsync -av docker/mail-relay/ kif.home.2123studios.com:/srv/docker/mail-relay/
```

On kif:

```bash
cd /srv/docker/mail-relay
cp .env.example .env
# Edit .env — set GMAIL_USER, GMAIL_APP_PASSWORD, MAIL_DEFAULT_RECIPIENT, mynetworks
docker compose config    # validate compose file
docker compose up -d --build
docker compose logs -f mail-relay
```

## Step 3 — Replace kif host Postfix

After the container passes smoke tests, stop the host Postfix service (port 25/587 conflict):

```bash
sudo systemctl disable --now postfix
```

Remove `/root/.forward` on kif once centralized aliases deliver mail correctly.

## Step 4 — AD DNS records

From the control node:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/dc-converge.yml --limit dc1.home.2123studios.com
```

Verify:

```bash
dig +short @192.168.1.10 mail.home.2123studios.com A
dig +short @192.168.1.10 home.2123studios.com MX
```

## Step 5 — Smoke tests

On kif (local delivery → relay → Gmail):

```bash
echo "relay smoke test $(date)" | mail -s "mail-relay kif test" root
```

From a domain-joined member (after relayhost configured):

```bash
echo "member smoke test $(date)" | mail -s "mail-relay member test" root
```

Verify in Gmail:

- Mail arrives at `vault_mail_default_recipient`
- `X-Google-Original-From` or envelope reflects rewritten `@2123studios.com` sender

TLS check from a member:

```bash
openssl s_client -connect mail.home.2123studios.com:587 -starttls smtp </dev/null
```

## Step 6 — Cut over members

**Ansible-managed Ubuntu members:**

```bash
${PROD} playbooks/domain-join.yml --limit bastion.home.2123studios.com
```

**Legacy CentOS hosts (kvm01, etc.)** — manual `/etc/postfix/main.cf`:

```
relayhost = [mail.home.2123studios.com]:587
smtp_use_tls = yes
```

## Step 7 — Retire pdc

Confirm no relay traffic to pdc, then proceed with migration runbook Step 8:

- [migration-runbook.md](migration-runbook.md) Phase 3 checklist — "Internal mail relay no longer depends on pdc"
- Demote or power off pdc

## Troubleshooting

| Symptom | Check |
|---|---|
| Gmail rejects mail | Sender rewrite map; compare with pdc backup |
| Connection refused on :587 | Container running; host Postfix disabled; firewall |
| TLS errors | Cert paths mounted; certbot renewal |
| Mail loops on kif | Host Postfix still running alongside container |
| Members can't relay | `mynetworks` in `.env` includes member subnet |
