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
| **smbd** | SMB share(s) — lab: single `labshare`; production kif: `[homes]`, `[archive]`, `[shared]`, `[media]`, `[paperless]` |
| **wsdd** | Optional Windows network discovery when `fileserver_wsdd_enabled: true` |
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

## Multi-share inventory (ROADMAP 19+)

When `fileserver_shares` is non-empty, the role renders one Samba stanza per entry
instead of the legacy single-share vars (`fileserver_share_name` / `fileserver_share_path`).

Each share supports common ACL/mask keys plus optional `manage_path` (directory
ownership on disk) and `extra_options` for uncommon Samba keys:

```yaml
fileserver_samba_enabled: true
fileserver_wsdd_enabled: true
fileserver_manage_resolv_conf: false   # kif — do not clobber working DNS

fileserver_global_options:
  server_signing: required
  vfs_objects: acl_xattr

fileserver_shares:
  - name: homes
    browseable: false
    read_only: false
    valid_users: "%S %D%w%S"
  - name: media
    path: /media
    read_only: false
    force_group: media
    write_list: ['"@domain users"', "@media"]
    manage_path:
      path: /media
      owner: root
      group: media
      mode: "0755"
```

See [`inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example`](../inventories/production/host_vars/kif.home.2123studios.com/vars.yml.example) for the full kif inventory.

### kif production cutover

kif is in `fileservers` and uses winbind (not sssd). Enable Samba via host_vars, then:

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
HOST=kif.home.2123studios.com

# Backup before first converge
ssh "${HOST}" 'sudo cp /etc/samba/smb.conf /root/smb.conf.pre-19plus && sudo testparm -s | sudo tee /root/testparm.pre-19plus >/dev/null'

${PROD} playbooks/baseline.yml --limit "${HOST}"
${PROD} playbooks/fileserver.yml --limit "${HOST}"
${PROD} playbooks/fileserver.yml --limit "${HOST}"   # idempotency proof
```

**`[shared]` fix:** the hand-maintained config had broken directory modes (`0700 root:root`,
masks without traverse bits, `@users` = local Unix group). Inventory uses `"@domain users"`,
`2770` on `/home/shared`, and normalized `0664`/`2775` masks.

**Validation on kif:**

- [ ] `sudo net ads testjoin`
- [ ] `testparm -s` — five shares present
- [ ] `systemctl is-active smbd nmbd winbind wsdd-server`
- [ ] Domain-user SMB smoke test per share
- [ ] Kerberos NFS clients still mount (`exportfs -v` on kif; `klist` on client)

**Rollback:**

```bash
sudo cp /root/smb.conf.pre-19plus /etc/samba/smb.conf
sudo testparm -s
sudo systemctl restart smbd nmbd winbind wsdd-server
```

Set `fileserver_samba_enabled: false` only if Ansible must stop managing `smb.conf` immediately.

Samba shares coexist with Kerberos NFS on the same paths — see [nfs-server-runbook.md](nfs-server-runbook.md).

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
