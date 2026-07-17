# AD SSH public keys (user provisioning)

Store **SSH public keys on Active Directory user objects** so domain-joined Linux
hosts can authenticate with `AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys`
without reading `~/.ssh/authorized_keys` on the filesystem. That matters on members
with **Kerberized NFS homedirs** (`root_squash` on kif): sshd cannot use pubkey files
under `/home/%u` until the user has a Kerberos ticket and the home is mounted.

This is **user provisioning** (per-person keys on the directory), not host join. Host
sshd wiring lives in [`domain_join`](domain-join-runbook.md) (`domain_member_sshd_enabled`)
or [`bastion`](bastion-runbook.md) (deferred full AD-key rollout).

## Prerequisites

| Layer | Requirement |
|-------|-------------|
| **Directory** | Samba AD user exists with RFC2307 `uidNumber` / `gidNumber` (see [sssd-config.md](sssd-config.md)) |
| **Member host** | `playbooks/domain-join.yml` converged; for hypervisors, `domain_member_sshd_enabled: true` |
| **SSSD** | `services` includes `ssh` when AD authorized keys are enabled (role sets this automatically) |
| **Client key** | Ed25519 or RSA public key line (`ssh-ed25519 AAAA... comment`) |

Pubkey SSH proves identity to **sshd** only. **NFS `sec=krb5i` homedirs** still need a
user Kerberos TGT on the member (password/`pam_sss` login, or `ssh -K` after client
`kinit`). See [nfs-client-runbook.md](nfs-client-runbook.md).

## 1. Verify `sshPublicKey` on the DC

On a DC (or from a host with `ldap-utils` and reachability to LDAP):

```bash
DC=dc1.home.2123studios.com
BASE="DC=home,DC=2123studios,DC=com"

ldapsearch -H ldap://"${DC}" -x -b "${BASE}" \
  "(sAMAccountName=misnow1)" sshPublicKey sAMAccountName
```

- If the attribute is **absent from the schema** (ldapsearch errors on unknown type),
  extend Samba’s LDAP schema for OpenSSH `sshPublicKey` before storing keys. Check
  Samba release notes / `ldapschema` on the DC; lab validation: repeat on `dc01.lab.test`.
- If the attribute exists but is **empty**, proceed to add a key.

## 2. Add or update a user’s key

Use the user’s **DN** from `samba-tool user show misnow1` or ldapsearch. Example
modify (run on the DC as root, adjust DN and key material):

```bash
USER=misnow1
KEY_FILE=~/.ssh/id_ed25519.pub   # one line: type + base64 + comment

ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: CN=${USER},CN=Users,${BASE}
changetype: modify
add: sshPublicKey
sshPublicKey: $(tr -d '\n' < "${KEY_FILE}")
-
EOF
```

To **replace** keys, `delete: sshPublicKey` (all values) then `add:` the new line(s),
or use `ldbedit` on the user object.

**Multiple keys:** repeat `sshPublicKey:` lines in the same `add` block (multi-valued).

Do **not** commit private keys or key material to this git repo.

## 3. Validate on a member

After LDAP replicates (usually immediate for single-site):

```bash
getent passwd misnow1
sudo sss_ssh_authorizedkeys misnow1    # should print the pubkey line(s)
```

From your workstation (member has `10-domain-member-ssh.conf` deployed):

```bash
ssh -i ~/.ssh/id_ed25519 misnow1@kvm01.home.2123studios.com
```

If pubkey auth succeeds but the session has no homedir/NFS access, obtain Kerberos
credentials (password login or `ssh -K` with a prior `kinit`).

## 4. Remove a key

```bash
ldbmodify -H /var/lib/samba/private/sam.ldb <<EOF
dn: CN=${USER},CN=Users,${BASE}
changetype: modify
delete: sshPublicKey
sshPublicKey: ssh-ed25519 AAAA...exact-line-to-remove...
-
EOF
```

Match the **exact** stored string (including comment).

## Automation (future)

This repo does not yet Ansible-manage per-user `sshPublicKey` attributes. Reasonable
follow-ups:

- Playbook or script invoked at user onboarding (vault or CI), idempotent per user
- Lab coverage in `tests/integration/setup_lab_ad_users.yml` once schema is confirmed
- Bastion: replace interim GSSAPI-only client access ([bastion-runbook.md](bastion-runbook.md))

## Related

- [domain-join-runbook.md](domain-join-runbook.md) — member sshd drop-in and login modes
- [dc-runbook.md](dc-runbook.md) — **local** operator SSH on DCs (different from AD user keys)
- [nfs-client-runbook.md](nfs-client-runbook.md) — Kerberos mounts and ESTALE vs credentials
- [bastion-runbook.md](bastion-runbook.md) — edge jump host; AD keys listed as deferred
