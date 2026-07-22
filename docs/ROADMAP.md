# home-network-v3 Roadmap

Canonical backlog for slices and deferred work. Update this file when scope changes.

## Completed — lab-proven foundations

| Slice | Name | Proof |
|---|---|---|
| 0 | Test harness | CI, lab scripts, structural tests, integration VM cycle |
| 1 | Ubuntu baseline | `linux_baseline` role, `baseline.yml`, idempotency test |
| 2 | Samba AD DC + BIND DLZ | `dc01.lab.test`, bootstrap/converge split |
| 3 | Domain join (realmd + sssd) | `member01.lab.test`, RFC2307 IDs, short names |
| 4 | Hypervisor (nested virt) | `hv01.lab.test`, libvirt + Docker, 32GB lab disk |
| 5 | Samba file server | `nas01.lab.test`, winbind, shell login + SMB share |
| 6 | DDNS / nsupdate automation | GSS-TSIG updates against BIND on DC |
| 7 | Backups + restore drills | Scope manifests, local restic, restore drill |
| 8 | Production convergence | Runbooks, prod wrapper, inventory examples, safety tests |
| 9 | DHCP-driven DDNS | dnsmasq hook + Docker DDNS API on DC |
| 10 | Certbot DNS validation | Samba LDAPS/START-TLS; optional DDNS nginx TLS |
| 13 | DC replica | `dc02.lab.test` replica join; `INTEGRATION_SLICE=dc_replica`; CI nightly |
| 17 | Cross-site DNS + IPv6 | `dc_trusted_networks`, BIND `localnets` + IPv6, multi-VLAN/remote-site docs |
| 18 | Bastion hardening | Edge jump host — sshd/GSSAPI, UFW, unattended-upgrades, fail2ban — [bastion-runbook.md](bastion-runbook.md) |
| 21 | NUT / UPS (kif) | `nut_ups` role, `nut-converge.yml`; kifups monitored on kif — [nut-runbook.md](nut-runbook.md) |

## Completed — production migrations

| Slice | Name | Notes |
|---|---|---|
| — | AD migration (pdc → dc1/dc2) | Legacy Fedora `pdc` retired; dc1/dc2 authoritative |
| 19 | kif/kvm01 Ubuntu reimage | Both hypervisors on Ubuntu 24.04, Ansible-managed |

**Platform policy:** Remaining non-Ubuntu VMs (e.g. Pi-hole on CentOS/Rocky) will be
**repaved as Ubuntu** and converged with existing playbooks — not in-place migrated.

## Active — production cutover

| Priority | Slice | Name | Status | Notes |
|---|---|---|---|---|
| 1 | 10+ | Pi-hole / DNS forwarders | **in progress** | Config-only Ansible role; Pi-hole → dc1/dc2; UCG DHCP — [pihole-runbook.md](pihole-runbook.md) |
| 2 | 16 | Internal mail relay | **in progress** | Dual relay (`mail` + `mail2`), Postfix fallback, AD DNS — [mail-relay-runbook.md](mail-relay-runbook.md) |
| 3 | 27 | LDAP VIP (keepalived) | **in progress** | Floating `ldap.home` on dc1/dc2; Authelia + single-URL LDAP clients — [ldap-vip-runbook.md](ldap-vip-runbook.md), [authelia-runbook.md](authelia-runbook.md) |
| 4 | 26 | Reverse proxy (nginx + Authelia) | **in progress** | Data-driven `reverse_proxy` role; SAN cert via certbot DNS-01; Authelia forward-auth — [reverse-proxy-runbook.md](reverse-proxy-runbook.md) |
| 5 | 25+ | Hypervisor host networking | **in progress** | Netplan/Ansible for br0 + VLAN bridges on kif/kvm01 — [hypervisor-runbook.md](hypervisor-runbook.md) |

## Active — automation backlog (post-reimage)

| Slice | Name | Depends on | Notes |
|---|---|---|---|
| 15+ | NFS exports (kif server) | Slice 19 | kif exports `/home`, `/media`, `/archive` for Linux clients; Ansible role or fileserver companion |
| 19+ | Production fileserver (kif shares) | 15+, Slice 5 | Extend `samba_fileserver`: `[homes]`, `[archive]`, `[shared]`, `[media]`, `[paperless]`; **wsdd** |
| — | nfs_client integration test | 15+ | Structural tests exist; tier-3 VM proof pending |

## Deferred (not forgotten)

| Slice | Name | Depends on | Why deferred |
|---|---|---|---|
| 11+ | Observability (Prometheus/Grafana) | Slices 1–5 hosts | Monitoring is separate concern |
| 12+ | Bare-metal install (PXE/kickstart) | Slice 1 baseline | Lab uses cloud-init; prod install later |
| 14+ | Windows provisioning | Slice 2 AD | Manual/docs only — Windows clients out of scope |
| 20+ | Mac Time Machine + avahi | Production fileserver | `vfs_fruit`, avahi `_adisk._tcp` / `_device-info._tcp`; Finder discovery for personal Macs |
| 22+ | backup-libvirt automation | Slice 7 | `backup-libvirt.sh` honoring scope manifest (`offline_copy`, `snapshot`, `exclude`) |
| 23+ | Restic scheduling + offsite | Slice 7, hypervisors | systemd timers; repos on kif `/archive/restic/`; SFTP/NAS backend; quarterly restore drill; 3-2-1 offsite copy |
| 24+ | kif ESP/boot mirror | kif reimage (optional) | Rebuild 2×1TB pair with mirrored ESP/`/boot`; retire spare-as-OS or repurpose 512GB SSD |
| — | nut_client role | Slice 21 | Server slice done; client role for kvm01 netclient path deferred |
| — | AD SSH public keys | Slice 18 | [ad-ssh-public-keys.md](ad-ssh-public-keys.md) |
| 28+ | Bastion / edge VIP HA | Slice 26, second bastion VM | keepalived floating VIP for UniFi port-forwards — [adr/001-bastion-keepalived-vip.md](adr/001-bastion-keepalived-vip.md) |
| — | Authelia container HA | Slice 27, container platform | Migrate Authelia/Valkey off single kif host; session loss acceptable short-term |
| — | Cert lifetime monitoring | Slice 11+ observability | Alert on Let's Encrypt remaining lifetime (LDAP VIP, mail, edge SAN certs) |
| — | Inventory vm_hypervisor field | — | Record which hypervisor runs each VM for outage planning |
| — | LDAP VIP cert on kif (compose sidecar) | — | If Authelia stack migrates, revisit compose-local certbot; DC VIP+SAN remains portable LDAP endpoint |

## Principles

- Vertical slices — each must pass automated tests before the next begins
- Lab inventory only for integration tests (`inventories/lab/`)
- Production inventory is gitignored
- No unclear manual steps in the test path

## Environment

| Setting | Value |
|---|---|
| Lab OS | Ubuntu 24.04 LTS |
| Lab domain | `lab.test` (realm `LAB.TEST`) |
| Lab network | `home-dc-lab` — `192.168.100.0/24` |
| Production domain | `home.2123studios.com` (realm `HOME.2123STUDIOS.COM`) |
| Integration host | kvm01 or kif (libvirt + nested virt on kvm01 lab VMs) |

See [inventories/README.md](../inventories/README.md) for inventory layout and group conventions.
