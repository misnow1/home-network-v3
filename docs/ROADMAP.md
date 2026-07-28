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
| 18 | Bastion hardening | Edge jump host — sshd/GSSAPI, UFW, fail2ban — [bastion-runbook.md](bastion-runbook.md) |
| 30 | Fleet security updates | Shared `unattended_upgrades` role + `security-updates.yml`; role-based reboot windows — [security-updates-runbook.md](security-updates-runbook.md) |
| 21 | NUT / UPS (kif) | `nut_ups` role, `nut-converge.yml`; kifups monitored on kif — [nut-runbook.md](nut-runbook.md) |

## Completed — production migrations

| Slice | Name | Notes |
|---|---|---|
| — | AD migration (pdc → dc1/dc2) | Legacy Fedora `pdc` retired; dc1/dc2 authoritative |
| 19 | kif/kvm01 Ubuntu reimage | Both hypervisors on Ubuntu 24.04, Ansible-managed |
| 25+ | Hypervisor host networking | Netplan-managed br0 + VLAN 3 bridges on kif/kvm01; production converge is idempotent — [hypervisor-runbook.md](hypervisor-runbook.md) |
| 27 | LDAP VIP (keepalived) | `ldap.home` fails over between dc1/dc2; Authelia authentication survives failover; production converge is idempotent — [ldap-vip-runbook.md](ldap-vip-runbook.md) |
| 10+ | Pi-hole / DNS forwarders | Dual Ubuntu Pi-hole VMs; AD forwarding, filtering, UCG DHCP, DDNS, and IPv4/IPv6 validation complete; production converge is idempotent — [pihole-runbook.md](pihole-runbook.md) |
| 16 | Internal mail relay | Dual Postfix relays (`mail` + `mail2`); member fallback, AD DNS, production TLS, and primary-outage delivery verified; production converge is idempotent — [mail-relay-runbook.md](mail-relay-runbook.md) |
| 19+ | Production fileserver (kif shares) | Ansible-managed `[homes]`, `[archive]`, `[shared]`, `[media]`, `[paperless]` + wsdd; production converge is idempotent and Windows mounts validated — [fileserver-runbook.md](fileserver-runbook.md) |

**Platform policy:** Remaining non-Ubuntu VMs will be
**repaved as Ubuntu** and converged with existing playbooks — not in-place migrated.

## Active — production cutover

| Priority | Slice | Name | Status | Notes |
|---|---|---|---|---|
| 1 | 26 | Reverse proxy (nginx + Authelia) | **in progress** | proxy01 VM + VLAN 4 docker edge; split from bastion — [reverse-proxy-runbook.md](reverse-proxy-runbook.md), [adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md), [edge-access-model.md](edge-access-model.md) |
| 2 | 23 | Restic scheduling + offsite copy | **in progress** | systemd timer, prune, `/archive/restic/` mirror on kif; quarterly restore drill — [backup-runbook.md](backup-runbook.md) |
| 3 | 31 | Kubernetes lab platform | **planned** | kubeadm + VLAN 9 workers; hybrid edge via proxy01 → MetalLB → ingress-nginx — [kubernetes-runbook.md](kubernetes-runbook.md), [adr/003-home-kubernetes.md](adr/003-home-kubernetes.md) |

## Active — automation backlog (post-reimage)

| Slice | Name | Depends on | Notes |
|---|---|---|---|
| 15+ | NFS exports (kif server) | Slice 19 | **`nfs_server` role + `nfs-server.yml` ready** — production converge/idempotency proof on kif pending; see [nfs-server-runbook.md](nfs-server-runbook.md) |
| — | nfs_client integration test | 15+ | Structural tests exist; tier-3 VM proof pending |

## Deferred (not forgotten)

| Slice | Name | Depends on | Why deferred |
|---|---|---|---|
| 11+ | Observability (Prometheus/Grafana) | Slices 1–5 hosts | Monitoring is separate concern |
| 12+ | Bare-metal install (PXE/kickstart) | Slice 1 baseline | Lab uses cloud-init; prod install later |
| 14+ | Windows provisioning | Slice 2 AD | Manual/docs only — Windows clients out of scope |
| 29+ | Stable IPv6-first LAN addressing | Slice 17, gateway topology | Replace ISP-PD-dependent inventory ACLs with stable internal IPv6 addressing (evaluate ULA and alternatives); research Windows RFC 6724 address selection, AAAA/AD DNS behavior, and dual-stack failure modes; apply consistently to NFS, firewalls, and fleet services |
| 20+ | Mac Time Machine + avahi | Production fileserver | `vfs_fruit`, avahi `_adisk._tcp` / `_device-info._tcp`; Finder discovery for personal Macs |
| 22+ | backup-libvirt automation | Slice 7 | `backup-libvirt.sh` honoring scope manifest (`offline_copy`, `snapshot`, `exclude`) |
| 23+ | Restic air-gap offsite | Slice 23 | SFTP/NAS/object-storage backend; automated copy off kif; immutable retention |
| 24+ | kif ESP/boot mirror | kif reimage (optional) | Rebuild 2×1TB pair with mirrored ESP/`/boot`; retire spare-as-OS or repurpose 512GB SSD |
| — | nut_client role | Slice 21 | Server slice done; client role for kvm01 netclient path deferred |
| — | AD SSH public keys | Slice 18 | [ad-ssh-public-keys.md](ad-ssh-public-keys.md) |
| 28+ | Bastion / edge VIP HA | Slice 26, second bastion VM | keepalived floating VIP for UniFi port-forwards — [adr/001-bastion-keepalived-vip.md](adr/001-bastion-keepalived-vip.md) |
| — | Authelia container HA | Slice 31 boring, container platform | Migrate Authelia/Valkey off single kif host; session loss acceptable short-term — blocked until k8s platform + restore proven ([adr/003-home-kubernetes.md](adr/003-home-kubernetes.md)) |
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
