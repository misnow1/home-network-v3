# home-network-v3 Roadmap

Canonical backlog for slices and deferred work. Update this file when scope changes.

## Active slices

| Slice | Name | Status | Notes |
|---|---|---|---|
| 0 | Test harness | **done** | CI, lab scripts, structural tests, integration VM cycle |
| 1 | Ubuntu baseline | **done** | `linux_baseline` role, `baseline.yml`, idempotency test |
| 2 | Samba AD DC + BIND DLZ | **done** | `dc01.lab.test`, bootstrap/converge split |
| 3 | Domain join (realmd + sssd) | **done** | `member01.lab.test`, RFC2307 IDs, short names |
| 4 | Hypervisor (nested virt) | **done** | `hv01.lab.test`, libvirt + Docker, 32GB lab disk |
| 5 | Samba file server | **done** | `nas01.lab.test`, winbind, shell login + SMB share |
| 6 | DDNS / nsupdate automation | **done** | GSS-TSIG updates against BIND on DC |
| 7 | Backups + restore drills | **done** | Scope manifests, local restic, restore drill |
| 8 | Production convergence | **done** | Runbooks, prod wrapper, inventory examples, safety tests |
| 9 | DHCP-driven DDNS | **done** | dnsmasq hook + Docker DDNS API on DC |
| 10 | Certbot DNS validation | **done** | Samba LDAPS/START-TLS; optional DDNS nginx TLS |
| 13 | DC replica | **done** | `dc02.lab.test` replica join; `INTEGRATION_SLICE=dc_replica`; CI nightly |
| 17 | Cross-site DNS + IPv6 | **done** | `dc_trusted_networks`, BIND `localnets` + IPv6, multi-VLAN/remote-site docs |
| 10+ | Pi-hole / DNS forwarders | **in progress** | Config-only Ansible role; Pi-hole → dc1/dc2; UCG DHCP — [pihole-runbook.md](pihole-runbook.md) |
| 16 | Internal mail relay | **in progress** | Dedicated mail VM (Postfix + certbot); AD DNS + domain_join relayhost — see [mail-relay-runbook.md](mail-relay-runbook.md) |
| 18 | Bastion hardening | **done** | Edge jump host — sshd/GSSAPI, UFW, unattended-upgrades, fail2ban — [bastion-runbook.md](bastion-runbook.md) |
| 26 | Reverse proxy (nginx + Authelia) | **in progress** | Data-driven `reverse_proxy` role; SAN cert via certbot DNS-01; Authelia forward-auth; replaces bastion-el9 nginx — [reverse-proxy-runbook.md](reverse-proxy-runbook.md) |
| 19 | kif/kvm01 Ubuntu reimage | **in progress** | kif spare SSD + md127 LVs **done** (ubuntu-vg stale LVs in burn-in); kvm01 Tier-1 capture **done** (2026-07-15); maintenance window + Ubuntu install remain — [kif-kvm01-reimage-runbook.md](kif-kvm01-reimage-runbook.md) |
| 21 | NUT / UPS (kif) | **done** | `nut_ups` role, `nut-converge.yml`; kifups monitored on kif — [nut-runbook.md](nut-runbook.md) |

## Deferred (not forgotten)

| Slice | Name | Depends on | Why deferred |
|---|---|---|---|
| 11+ | Observability (Prometheus/Grafana) | Slices 1–5 hosts | Monitoring is separate concern |
| 12+ | Bare-metal install (PXE/kickstart) | Slice 1 baseline | Lab uses cloud-init; prod install later |
| 14+ | Windows provisioning | Slice 2 AD | Manual/docs only — Windows clients out of scope |
| 15+ | NFS exports | Slice 5 / kif reimage | kif exports `/home`, `/media`, `/archive` for Linux clients (kvm01); Ansible role or fileserver companion — not manual-only post-reimage |
| 19+ | Production fileserver (kif shares) | kif reimage, Slice 5 | Extend `samba_fileserver`: `[homes]`, `[archive]`, `[shared]`, `[media]`, `[paperless]`; **wsdd**; drop legacy `[netlogon]`/`[sysvol]` if dc1/dc2 authoritative |
| 20+ | Mac Time Machine + avahi | Production fileserver | `vfs_fruit`, avahi `_adisk._tcp` / `_device-info._tcp`; Finder discovery for personal Macs — skip stock avahi on reimage cutover |
| 22+ | backup-libvirt automation | Slice 7 | `backup-libvirt.sh` honoring scope manifest (`offline_copy`, `snapshot`, `exclude`) |
| 23+ | Restic scheduling + offsite | Slice 7, hypervisors | systemd timers; repos on kif `/archive/restic/`; SFTP/NAS backend; quarterly restore drill; 3-2-1 offsite copy |
| 24+ | kif ESP/boot mirror | kif reimage (optional) | Rebuild 2×1TB pair with mirrored ESP/`/boot`; retire spare-as-OS or repurpose 512GB SSD |
| 25+ | Hypervisor host networking | kif/kvm01 reimage, Slice 4 | Netplan/Ansible for br0 + VLAN bridges; libvirt `external-default` / `vlan3`; not Docker bridges |

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
| Integration host | kvm01 (libvirt + nested virt) |
