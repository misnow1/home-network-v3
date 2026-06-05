# File server runbook (Slice 5)

Samba AD member servers join `lab.test` via **winbind + idmap_ad** (not sssd). Domain users
get shell login (SSH/su) and SMB access — no per-host local accounts beyond `ansible`.

## Lab integration (automated)

```bash
LAB_HOST=nas01.lab.test ./scripts/test-integration.sh
```

Provisions `dc01`, creates `labtest` AD user, converges `nas01`, verifies NSS/PAM/SMB, tears down both VMs.

Slice-specific regression:

```bash
LAB_HOST=member01.lab.test ./scripts/test-integration.sh   # Slice 3
LAB_HOST=hv01.lab.test ./scripts/test-integration.sh       # Slice 4
LAB_HOST=nas01.lab.test ./scripts/test-integration.sh      # Slice 5
```

## Manual lab workflow

```bash
# DC must exist first (Slice 2)
./scripts/lab/vm-create.sh dc01.lab.test
./scripts/lab/wait-ssh.sh dc01.lab.test
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook tests/integration/setup_lab_ad_users.yml --limit dc01.lab.test

# File server
./scripts/lab/vm-create.sh nas01.lab.test
./scripts/lab/wait-ssh.sh nas01.lab.test
ansible-playbook playbooks/baseline.yml --limit nas01.lab.test
ansible-playbook playbooks/fileserver.yml --limit nas01.lab.test
ansible-playbook tests/integration/test_fileserver_converged.yml --limit nas01.lab.test
```

Re-run `fileserver.yml` twice — second run must report `changed=0`.

## What the role delivers

| Component | Purpose |
|---|---|
| **winbind** | AD auth, NSS (`getent`), PAM (shell login) |
| **idmap_ad** | RFC2307 POSIX IDs from AD (`schema_mode = rfc2307`) |
| **smbd** | SMB share `labshare` at `/srv/samba/labshare` (ACL: `@LAB\labusers`) |
| **PAM** | `pam_winbind` + `pam_mkhomedir` for domain user homedirs |

## Identity model

- **Domain Users** (e.g. `labtest`) — interactive shell login and SMB access when in `labusers`
- **Domain Admins** — not configured for NAS login (break-glass via `ansible` SSH)
- **sssd** — not installed; winbind owns NSS/PAM on file servers

See [sssd-config.md](sssd-config.md) for the member-server (sssd) vs file-server (winbind) split.

## Vault variables

| Variable | Purpose |
|---|---|
| `vault_ad_join_user` | Account used by `net ads join` (lab: `Administrator`) |
| `vault_ad_join_password` | Join account password |
| `vault_test_user_password` | Lab AD user for integration tests |

## Apply order

1. `baseline.yml` — chrony before Kerberos
2. `fileserver.yml` — packages, DNS, smb.conf, domain join, winbind NSS/PAM, share

DC hosts (`dc` group) are excluded — they never run `samba_fileserver`.
