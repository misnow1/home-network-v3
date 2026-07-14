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
2. `domain-join.yml --tags domain_mail_relay` — Postfix relay client (production kif only; prerequisite for MD/NUT email)
3. `fileserver.yml` — Samba AD member when `fileserver_samba_enabled: true`; optional `mdadm_monitor` when enabled

DC hosts (`dc` group) are excluded — they never run `samba_fileserver`.

### kif (hand-maintained Samba)

kif uses `fileserver_samba_enabled: false` in host_vars. The pre-reimage config at
`/archive/pre-reimage-kif-2026-06-29/samba/smb.conf` defines `[homes]`, `[archive]`,
`[shared]`, `[media]`, and `[paperless]` — not the lab single-share template. ROADMAP **19+**
will Ansible-manage those shares.

`fileserver.yml` on kif runs only `mdadm_monitor` (and hypervisor when tagged). It does **not**
deploy `smb.conf`.

**Recovery** if smb.conf was overwritten:

```bash
sudo cp /archive/pre-reimage-kif-2026-06-29/samba/smb.conf /etc/samba/smb.conf
sudo testparm -s
sudo systemctl restart smbd nmbd winbind
```

## MD array monitoring (optional)

When `mdadm_monitor_enabled: true` (production kif), [`fileserver.yml`](../playbooks/fileserver.yml) also runs the [`mdadm_monitor`](../roles/mdadm_monitor/) role.

| Component | Purpose |
|---|---|
| **mdadm** | RAID tools and monitor daemon |
| **mdmonitor** | Continuous failure/degradation alerts |
| **mdcheck timers** | Ubuntu 24.04 periodic scrubs (`mdcheck_start`, `mdcheck_continue`) |
| **mdmonitor-oneshot** | Daily poll for newly degraded arrays |
| **MAILADDR root** | Alerts relay through Postfix → `mail.home.2123studios.com` → vault recipient |

**Prerequisites:** Postfix relay client must be active before `fileserver.yml` (same as NUT). On kif (winbind, not full domain-join):

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/domain-join.yml \
  --limit kif.home.2123studios.com --tags domain_mail_relay
```

Lab `nas01` leaves `mdadm_monitor_enabled` at default `false` (no RAID).

**Verification:**

```bash
systemctl status mdmonitor mdcheck_start.timer mdcheck_continue.timer mdmonitor-oneshot.timer
cat /proc/mdstat
grep MAILADDR /etc/mdadm/mdadm.conf
```

Each `fileserver.yml` converge on a RAID host sends a mdadm test email (`TestMessage`) to verify the relay chain end-to-end.
