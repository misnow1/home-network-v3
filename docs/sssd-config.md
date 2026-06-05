# SSSD configuration (Slice 3+)

Member Linux hosts use **realmd + sssd** for system authentication against `lab.test`.

## Requirements

1. **RFC2307 POSIX IDs** — read explicit `uidNumber` / `gidNumber` from AD:
   - `ldap_id_mapping = false`
2. **Short names** — users appear as `user`, not `user@lab.test`:
   - `use_fully_qualified_names = False`
   - `fully_qualified_names = False`

## Defaults

Lab defaults live in `inventories/lab/group_vars/all/vars.yml` and are applied by the
`domain_join` role (Slice 3).

## File server note

Samba file servers (`nas01`) use **winbind** for NSS, PAM, and SMB — not sssd.
See [fileserver-runbook.md](fileserver-runbook.md) (Slice 5).
