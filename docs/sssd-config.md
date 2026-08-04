# SSSD configuration (Slice 3+)

Member Linux hosts use **realmd + sssd** for system authentication against `lab.test`.

## Requirements

1. **RFC2307 POSIX IDs** — read explicit `uidNumber` / `gidNumber` from AD:
   - `ldap_id_mapping = false`
2. **Short names** — users appear as `user`, not `user@lab.test`:
   - `use_fully_qualified_names = False`

## Access control

`access_provider = simple` is used. With **no** `simple_allow_groups`, SSSD's
simple provider grants login to **all** domain users. Set
`domain_member_allow_groups` in `group_vars` to restrict access to named groups
(the lab uses `Domain Users`).

## Kerberos ticket renewal and KCM

Defaults in `roles/domain_join/defaults/main.yml` (override per host/group):

| Variable | Default | Purpose |
|----------|---------|---------|
| `sssd_krb5_renewable` | `true` | Emit the renewal settings below |
| `sssd_krb5_renewable_lifetime` | `7d` | `krb5_renewable_lifetime` — makes SSSD request renewable TGTs |
| `sssd_krb5_renew_interval` | `3600` | Seconds between renew attempts (~hourly) |
| `sssd_kcm_enabled` | `true` | Install `sssd-kcm` and start `sssd-kcm.socket` |
| `domain_join_krb5_ticket_lifetime` | `24h` | `ticket_lifetime` in the krb5.conf.d drop-in |
| `domain_join_krb5_renew_lifetime` | `7d` | `renew_lifetime` in the krb5.conf.d drop-in |

There is **no** `krb5_renewable` boolean in SSSD — `krb5_renewable_lifetime` is the
option that requests renewable tickets. `sudo sssctl config-check` rejects the
former, so it is asserted against in the structural tests.

SSSD renews TGTs **issued via `pam_sss`** (password / kbd-interactive). AD caps both
values (`MaxTicketAge` ~10h, `MaxRenewAge` ~7d with Samba defaults); after
`renew until`, re-authenticate. See
[nfs-client-runbook.md](nfs-client-runbook.md) § Long-running sessions.

The role also ensures `/etc/krb5.conf` has `includedir /etc/krb5.conf.d/` so Ubuntu
members load SSSD's `krb5.include.d` fragments, the `sssd-kcm` default-ccache
snippet, and the Ansible lifetime drop-in `/etc/krb5.conf.d/ansible_ticket_lifetimes`
(stock Ubuntu omits both the include line and any lifetimes, which is why Ubuntu
hosts got a 24h renew window while RHEL hosts got 7d).

## Defaults

Lab defaults live in `inventories/lab/group_vars/all/vars.yml` and are applied by the
`domain_join` role (Slice 3).

## File server note

Samba file servers (`nas01`) use **winbind** for NSS, PAM, and SMB — not sssd.
See [fileserver-runbook.md](fileserver-runbook.md) (Slice 5).

## SSH public keys in AD

Per-user provisioning (not host join): [ad-ssh-public-keys.md](ad-ssh-public-keys.md).
