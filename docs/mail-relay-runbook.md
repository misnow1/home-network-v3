# Internal mail relay runbook (Slice 16+)

Replace the legacy **pdc** internal→external SMTP relay. Outbound server mail (cron, alerts)
relays through **native Postfix on a dedicated Ubuntu VM** at **`mail.home.2123studios.com`**
and forwards to **Gmail** with pdc-equivalent sender rewrite rules.

See also:

- [certbot-runbook.md](certbot-runbook.md) — Dreamhost DNS-01 (same role as DCs)
- [vault-schema.md](vault-schema.md) — Gmail app password variables
- [production-runbook.md](production-runbook.md) — VM provisioning via `scripts/vm/vm-create.sh`

## Architecture

| Component | Location |
|---|---|
| Postfix relay | Dedicated VM — `mail.home.2123studios.com` |
| TLS | Certbot snap on same VM (`certbot` inventory group) |
| DNS A + MX | AD DNS on dc1 (Ansible `dns_mail_relay.yml`) |
| Member `relayhost` | Ansible `domain_join` role when `mail_relay_client_enabled: true` |
| Upstream | Gmail SMTP (`smtp.gmail.com:587`) with app password |

Sender rewrite (replicates pdc `/etc/postfix/sender_rewrite`):

```
root@kif.home.2123studios.com  →  root-kif@2123studios.com  (envelope)
```

Root mail delivery is centralized on the relay (`virtual_alias_maps`) — retire per-host
`/root/.forward` files once aliases are verified. The alias regex matches `root@` at the
apex domain (`root@home.2123studios.com`, produced by clients whose Postfix `myorigin` is
`$mydomain`) as well as any host under it (`root@kif.home.2123studios.com`); both rewrite
to `vault_mail_default_recipient`. Without the apex case, mail is relayed verbatim to Gmail,
which bounces it (`NXDOMAIN` — `home.2123studios.com` has no public MX).

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
vault_dreamhost_api_key: "<dreamhost-api-key>"   # shared with DC certbot
```

3. Copy inventory templates:

```bash
cp inventories/production/group_vars/mail_relay/vars.yml.example \
   inventories/production/group_vars/mail_relay/vars.yml
```

Add the mail relay host to `inventories/production/hosts.yml` (see
[`hosts.yml.example`](../inventories/production/hosts.yml.example)). The host must be
in both **`mail_relay`** and **`linux`** (via `linux.children.mail_relay`) so
`baseline.yml` matches it.

4. DC group vars — point DNS at the mail VM IP:

```yaml
mail_relay_dns_enabled: true
mail_relay_hostname: mail.home.2123studios.com
mail_relay_target_ip: 192.168.1.15   # mail VM
```

5. Linux member group vars (when ready to cut over):

```yaml
mail_relay_client_enabled: true
mail_relay_hostname: mail.home.2123studios.com
mail_relay_manage_root_forward: true   # optional: remove /root/.forward
```

The mail VM uses `mail_relay_client_enabled: false` in `group_vars/mail_relay/` so
`domain-join.yml` joins AD without configuring relay-client Postfix (server role handles
that via `mail-relay.yml`).

## Step 1 — Provision the mail relay VM

From the control node (kvm01 or similar):

```bash
./scripts/vm/vm-create.sh -i production mail.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production mail.home.2123studios.com
```

Suggested sizing: 512MB–1GB RAM, 8–12GB disk (see `hosts.yml.example`).

## Step 2 — Converge baseline, domain join, certbot, and Postfix

```bash
PROD='./scripts/prod-run.sh --confirm-production --'

${PROD} playbooks/baseline.yml --limit mail.home.2123studios.com
${PROD} playbooks/domain-join.yml --limit mail.home.2123studios.com
${PROD} playbooks/certbot.yml -e allow_production=true \
  --limit mail.home.2123studios.com
${PROD} playbooks/mail-relay.yml -e allow_production=true \
  --limit mail.home.2123studios.com
```

Run `domain-join.yml` before certbot so the mail VM is domain-joined and uses AD DNS.
With `mail_relay_client_enabled: false` in mail relay group vars, domain join does **not**
install relay-client Postfix — `mail-relay.yml` owns server config.

Certbot uses the same Dreamhost DNS-01 hooks as dc1. Renewal reloads Postfix via
`certbot_deploy_hook_reload_postfix: true` in mail relay group vars.

Verify TLS:

```bash
openssl s_client -connect mail.home.2123studios.com:587 -starttls smtp </dev/null
```

## Step 3 — AD DNS records

```bash
${PROD} playbooks/dc-converge.yml --limit dc1.home.2123studios.com
```

Verify:

```bash
dig +short @192.168.1.10 mail.home.2123studios.com A
dig +short @192.168.1.10 home.2123studios.com MX
```

## Step 4 — Smoke tests

On the mail relay VM:

```bash
echo "relay smoke test $(date)" | mail -s "mail-relay smoke test" root
```

From a domain-joined member (after relayhost configured):

```bash
echo "member smoke test $(date)" | mail -s "mail-relay member test" root
```

Verify in Gmail:

- Mail arrives at `vault_mail_default_recipient`
- Envelope / headers reflect rewritten `@2123studios.com` sender

## Step 5 — Cut over members

**Ansible-managed Ubuntu members** (with `mail_relay_client_enabled: true` in
`group_vars/linux/`):

```bash
${PROD} playbooks/baseline.yml --limit shell-clt01.home.2123studios.com
${PROD} playbooks/domain-join.yml --limit shell-clt01.home.2123studios.com
${PROD} playbooks/bastion.yml --limit shell-clt01.home.2123studios.com
```

**kif (winbind)** — mail relay client via tagged domain-join:

```bash
${PROD} playbooks/domain-join.yml --limit kif.home.2123studios.com --tags domain_mail_relay
```

## Step 6 — Legacy pdc (retired)

Internal mail relay runs on **mail.home.2123studios.com**. Legacy **pdc** is decommissioned.

## Apply order summary

```text
vm-create mail.home.2123studios.com
baseline.yml → domain-join.yml → certbot.yml → mail-relay.yml   (mail VM)
dc-converge.yml                                                 (dc1 — DNS A + MX)
baseline.yml → domain-join.yml                                  (members — relayhost client)
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Gmail rejects mail | Sender rewrite map; compare with pdc backup |
| Connection refused on :587 | `systemctl status postfix`; UFW if enabled |
| TLS errors | Run `certbot.yml` first; check `/etc/letsencrypt/live/` |
| `mail-relay.yml` fails on cert | certbot must complete before Postfix converge |
| Members can't relay | `mail_relay_mynetworks` includes member subnet |
| Playbook skipped on DC certbot | DC hosts still require `samba_dc_tls_enabled` |
