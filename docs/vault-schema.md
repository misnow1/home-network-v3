# Vault schema

This document lists every Ansible Vault variable, its purpose, and how to recreate the
lab vault if the password is lost.

## Files

| File | Encrypted | Used by |
|---|---|---|
| `inventories/lab/group_vars/all/vault.yml` | Yes (committed) | Lab integration tests and development |
| `inventories/production/group_vars/vault.yml` | Yes (gitignored) | Production runs via `scripts/prod-run.sh` |

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
and populate real values locally:

```bash
ansible-vault create inventories/production/group_vars/vault.yml --vault-password-file .vault_pass
```
