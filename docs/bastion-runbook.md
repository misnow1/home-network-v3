# Bastion runbook (Slice 18)

Edge jump host hardening for domain-joined Ubuntu members. The bastion sits on the
network perimeter and provides SSH access into the internal network.

**Playbook:** [`playbooks/bastion.yml`](../playbooks/bastion.yml)  
**Role:** [`roles/bastion`](../roles/bastion/)  
**Inventory group:** `bastion` (child of `linux`)

## Prerequisites

Run in order on each bastion host:

1. [`playbooks/baseline.yml`](../playbooks/baseline.yml) — packages, chrony, hostname
2. [`playbooks/domain-join.yml`](../playbooks/domain-join.yml) — realmd + sssd AD join
3. [`playbooks/bastion.yml`](../playbooks/bastion.yml) — edge hardening

Do **not** run `ddns-client.yml` on bastion — the UCG dhcp-script registers the host
via the DDNS API on the DC.

## What the role configures

| Component | Behavior |
|---|---|
| **sshd** | Drop-in: no root, no password auth, GSSAPI/Kerberos enabled |
| **UFW** | Default deny incoming; allow OpenSSH only; outbound unrestricted |
| **unattended-upgrades** | Security updates; automatic reboot at configured time |
| **fail2ban** | sshd jail with management-network `ignoreip` |

No kerberized NFS autofs mounts — bastion is a lean jump host. Homedirs are local via
`pam_mkhomedir` from `domain_join`.

## VM provisioning (production)

Bastion uses DHCP with a router reservation so the UCG `dhcp-script` registers DNS on
first boot. Set `ansible_host` to the reservation IP and `vm_use_dhcp: true` in
inventory (see [`production-runbook.md`](production-runbook.md)).

```bash
# Reservation-first — do not skip --prepare on first provision
./scripts/vm/vm-create.sh -i production --prepare bastion.home.2123studios.com
# Create UniFi DHCP reservation: printed MAC -> ansible_host IP
./scripts/vm/vm-start.sh -i production bastion.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production bastion.home.2123studios.com
```

Then apply playbooks below. Reprovisioning: `vm-destroy.sh` then repeat the prepare
workflow so MAC and reservation stay aligned.

## Production apply

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
BASTION=bastion.home.2123studios.com

${PROD} playbooks/baseline.yml --limit "${BASTION}"
${PROD} playbooks/domain-join.yml --limit "${BASTION}"
${PROD} playbooks/bastion.yml --limit "${BASTION}"
```

Re-run `bastion.yml` idempotently after variable changes.

## Client access (interim — SSH keys deferred)

Until SSH public key automation lands, authenticate with Kerberos tickets:

```bash
# On your client (domain-joined or with krb5.conf pointing at dc1)
kinit youruser@HOME.2123STUDIOS.COM

ssh -o GSSAPIAuthentication=yes \
    -o PreferredAuthentications=gssapi-with-mic \
    bastion.home.2123studios.com
```

Password is used for `kinit` on the client, not on the SSH wire to bastion.

SSH access is restricted by `domain_member_allow_groups` in
`inventories/production/group_vars/linux/vars.yml` (SSSD `simple_allow_groups`).

## Migration from bastion-el9

The legacy CentOS/RHEL 9 host (`bastion-el9`) is replaced by a fresh Ubuntu 24.04 VM at
`bastion.home.2123studios.com`. See [migration-runbook.md](migration-runbook.md) Phase 2.

1. Optionally `domain-leave.yml` before wipe (in-place reprovision only).
2. Reinstall Ubuntu 24.04 (cloud-init or manual).
3. Delete stale AD computer account if hostname unchanged.
4. Apply baseline → domain-join → bastion (above).
5. Validate GSSAPI SSH and internal jump connectivity.

DDNS: router dhcp-hook continues to register the host; no `ddns-client` keytab on bastion.

## Lab integration

```bash
INTEGRATION_SLICE=bastion LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

Uses `member01.lab.test` as a bastion subset after domain join.

## Validation checklist

- [ ] `sshd -T` shows `gssapiauthentication yes`, `passwordauthentication no`, `permitrootlogin no`
- [ ] `ufw status` — active, OpenSSH allowed
- [ ] `fail2ban-client status sshd` — jail active
- [ ] `kinit` + GSSAPI SSH succeeds for an allowed domain user
- [ ] Jump to an internal host works (`ssh internal-host` from bastion)
- [ ] Second `bastion.yml` run reports `changed=0`

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `bastion_unattended_auto_reboot` | `true` | Reboot after security updates when required |
| `bastion_unattended_reboot_time` | `03:30` | Reboot window (local time) |
| `bastion_fail2ban_maxretry` | `5` | sshd failures before ban |
| `bastion_fail2ban_bantime` | `3600` | Ban duration (seconds) |
| `bastion_fail2ban_ignoreip` | lab subnet + localhost | Ansible/management CIDRs to never ban |
| `bastion_gssapi_strict_acceptor_check` | `false` | Relaxed for DHCP edge hostname/SPN |
| `bastion_ufw_enabled` | `true` | Set `false` only for debugging |

## Deferred follow-up

1. **SSH public keys** — AD `sshPublicKey` on user objects +
   `AuthorizedKeysCommand /usr/bin/sss_ssh_authorizedkeys %u` (verify Samba AD schema on dc1)
2. **Package trimming** — optional `linux_baseline` minimal profile for jump hosts
3. **NFS autofs** — hypervisors via `nfs-client.yml` when `nfs_client_enabled`; not on bastion — [nfs-client-runbook.md](nfs-client-runbook.md)

## Related docs

- [domain-join-runbook.md](domain-join-runbook.md) — SSSD and group access
- [migration-runbook.md](migration-runbook.md) — Phase 2 reprovision
- [production-runbook.md](production-runbook.md) — wrapper and apply order
- [software.md](software.md) — package list
