# Vault schema

This document lists every Ansible Vault variable, its purpose, and how to recreate the
lab vault if the password is lost.

## Files

| File | Encrypted | Used by |
|---|---|---|
| `inventories/lab/group_vars/all/vault.yml` | Yes (committed) | Lab integration tests and development |
| `inventories/production/group_vars/all/vault.yml` | Yes (gitignored) | Production runs via `scripts/prod-run.sh` |

Non-secret production variables use committed `*.example` templates under
`inventories/production/group_vars/` — copy to `vars.yml` locally (see
`docs/production-runbook.md`).

## Password files (never commit)

| File | Purpose |
|---|---|
| `.vault_pass_lab` | Local lab vault password |
| `.vault_pass` | Local production vault password |

GitHub Actions secret: `VAULT_PASS_LAB`

Default lab development password (change after clone): `change-me-lab-vault`

## ansible.cfg and vault passwords

`ansible.cfg` intentionally does **not** set `vault_password_file`. Lab and production
use different password files (`.vault_pass_lab` vs `.vault_pass`); a global default breaks
`ansible-vault create` / `edit` for the other environment.

Always pass `--vault-password-file` explicitly:

| Task | Password file |
|---|---|
| Lab playbooks / `./scripts/test-quick.sh` | `.vault_pass_lab` (via `scripts/lib/ansible.sh`) |
| Production playbooks | `.vault_pass` (via `scripts/prod-run.sh`) |
| `ansible-vault` CLI (lab) | `--vault-password-file .vault_pass_lab` |
| `ansible-vault` CLI (production) | `--vault-password-file .vault_pass` |

## Lab vault variables

Variables below are added as slices land. Placeholder exists for Slice 0.

| Variable | Slice | Purpose | Example placeholder |
|---|---|---|---|
| `vault_lab_placeholder` | 0 | Proves vault decrypt works in CI | `configured` |
| `vault_ad_join_user` | 3 | Domain join service account | `svc-ansible-join` |
| `vault_ad_join_password` | 3 | Domain join password | `change-me-join` |
| `vault_samba_admin_password` | 2 | Samba DC administrator password | `change-me-dc-admin` |
| `vault_test_user_password` | 3 | Lab AD user for integration tests | `change-me-test-user` |
| `vault_dnsupdater_password` | 6 | DnsAdmins service account for GSS-TSIG nsupdate | `change-me-dnsupdater` |
| `vault_ddns_shared_secret` | 9 | Bearer token for DDNS API (dhcp-script → DC) | `change-me-ddns-api` |
| `vault_backup_repository_key` | 7 | Backup target encryption key | `change-me-backup-key` |
| `vault_dreamhost_api_key` | 10 | Dreamhost API key (`dns-*`) for Certbot DNS-01 | production only |
| `vault_mail_gmail_user` | 16 | Gmail address for internal mail relay SASL auth | production only |
| `vault_mail_gmail_app_password` | 16 | Gmail app password for relay smarthost | production only |
| `vault_mail_default_recipient` | 16 | Delivery target for root@*.home.2123studios.com | production only |
| `vault_nut_ups_local_mon_password` | 21 | NUT upsmon master password (local shutdown) | production only |
| `vault_nut_ups_remote_mon_password` | 21 | NUT upsmon slave password (remote netclient) | production only |
| `vault_nut_snmp_community_livingroom` | 21 | SNMP community for livingroomups (optional) | production only |
| `vault_pushover_user_key` | 21 | Pushover user key for UPS notifications | production only |
| `vault_pushover_api_token` | 21 | Pushover application API token | production only |

## Recreate the lab vault

```bash
printf '%s' 'your-new-password' > .vault_pass_lab
chmod 600 .vault_pass_lab

ansible-vault create inventories/lab/group_vars/all/vault.yml --vault-password-file .vault_pass_lab
```

Or encrypt individual strings:

```bash
ansible-vault encrypt_string --vault-password-file .vault_pass_lab \
  'change-me-join' --name vault_ad_join_password
```

After recreating, update the `VAULT_PASS_LAB` GitHub secret and re-run `./scripts/test-quick.sh`.

## Production vault

Production secrets are never committed. Copy structure from the lab vault variable table
and populate real values locally. Use the **production** password file, not the lab default:

```bash
printf '%s' 'your-production-vault-password' > .vault_pass
chmod 600 .vault_pass

ansible-vault create inventories/production/group_vars/all/vault.yml \
  --vault-password-file .vault_pass
```

**Important:** The file must live under `group_vars/all/`. A vault file at
`group_vars/vault.yml` is **not** loaded for hosts (Ansible treats that as a group
named `vault`). If you have an older `group_vars/vault.yml`, move it:

```bash
mv inventories/production/group_vars/vault.yml \
   inventories/production/group_vars/all/vault.yml
```

Edit or view later with the same `--vault-password-file .vault_pass` flag.
