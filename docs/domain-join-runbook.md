# Domain join runbook (Slice 3)

Ubuntu lab members join `lab.test` via **realmd + sssd** (no winbind on general Linux hosts).

## Lab integration (automated)

```bash
./scripts/test-integration.sh
```

Default host is `member01.lab.test` — provisions `dc01`, creates test AD user, joins member, verifies, tears down both VMs.

Slice-specific regression:

```bash
LAB_HOST=dc01.lab.test ./scripts/test-integration.sh   # Slice 2
LAB_HOST=member01.lab.test LAB_SLICE=... # default domain_join
```

## Manual lab workflow

```bash
# DC must exist first (Slice 2)
./scripts/lab/vm-create.sh dc01.lab.test
./scripts/lab/wait-ssh.sh dc01.lab.test
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook tests/integration/setup_lab_ad_users.yml --limit dc01.lab.test

# Member join
./scripts/lab/vm-create.sh member01.lab.test
./scripts/lab/wait-ssh.sh member01.lab.test
ansible-playbook playbooks/baseline.yml --limit member01.lab.test
ansible-playbook playbooks/domain-join.yml --limit member01.lab.test
ansible-playbook tests/integration/test_domain_join_converged.yml --limit member01.lab.test
```

Re-run `domain-join.yml` twice — second run must report `changed=0`.

## SSSD settings

See [sssd-config.md](sssd-config.md):

- `ldap_id_mapping = false` — RFC2307 `uidNumber` / `gidNumber` from AD
- `use_fully_qualified_names = False` — short names (`labtest`, not `labtest@lab.test`)

## Vault variables

| Variable | Purpose |
|---|---|
| `vault_ad_join_user` | Account used by `realm join` (lab: `Administrator`) |
| `vault_ad_join_password` | Join account password |
| `vault_test_user_password` | Lab AD user for integration tests |

## Apply order

1. `baseline.yml` — chrony before Kerberos
2. `domain-join.yml` — packages, optional static resolv.conf (opt-in), realm join, sssd.conf, mkhomedir

DC hosts (`dc` group) are excluded — they never run `domain_join`.

## DNS / resolv.conf (opt-in)

Default **`domain_join_manage_resolv_conf: false`** — the role does not replace
`/etc/resolv.conf`. Use DHCP/systemd-resolved (e.g. production hypervisors on `br0`).

Enable static AD nameservers only when the host cannot resolve the realm yet:

```yaml
domain_join_manage_resolv_conf: true
domain_join_dns_servers:
  - 192.168.1.10
```

Lab sets both in `inventories/lab/group_vars/linux/vars.yml`. Overwriting resolv.conf
breaks the resolved stub symlink; do not enable on members that already reach AD via DHCP.

Winbind is reserved for the Samba file server slice (Slice 5) on `nas01.lab.test`.

## SSH for members with Kerberized NFS homedirs

Ubuntu cloud images ship `PasswordAuthentication no` in `sshd_config.d/50-cloud-init*.conf`.
OpenSSH applies the **first** value per keyword, so the role drops in
`10-domain-member-ssh.conf` (loads **before** `50-*`) to re-enable password and
keyboard-interactive auth for `pam_sss` when needed.

Opt in per inventory (example: `group_vars/hypervisors/vars.yml`):

```yaml
domain_member_sshd_enabled: true
```

This enables:

| Setting | Purpose |
|---|---|
| **GSSAPI** | `kinit` on client, then `ssh -K` (credential delegation for NFS `sec=krb5i`) |
| **`AuthorizedKeysCommand`** | Pubkeys from AD via `sss_ssh_authorizedkeys` — avoids reading `~/.ssh/authorized_keys` on NFS (root_squash) |
| **Password / kbd-interactive** | Laptop has VPN route to the host but **no KDC DNS** (`kinit` → “tried 0 KDCs”); AD auth and krb5 ticket acquisition happen **on the member** via `pam_sss` |

Per-user keys on directory objects: [ad-ssh-public-keys.md](ad-ssh-public-keys.md).
Re-run `domain-join.yml` with tags `domain_configure,domain_sshd` after enabling.

**Bastion** uses `roles/bastion` (GSSAPI-only, local homedirs) — do not enable
`domain_member_sshd_enabled` there.

**Client krb5 when DNS works** (home VPN with internal DNS): `kinit user@REALM`,
`ssh -K host`. When work VPN breaks home DNS, use password SSH to the member or a
portable `krb5.conf` with static `kdc = dc1.home.2123studios.com` plus `/etc/hosts` for the DC.

See [nfs-client-runbook.md](nfs-client-runbook.md) for mount and credential troubleshooting.
