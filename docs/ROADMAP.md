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
| 16 | Internal mail relay | **in progress** | Dedicated mail VM (Postfix + certbot); AD DNS + domain_join relayhost — see [mail-relay-runbook.md](mail-relay-runbook.md) |

## Deferred (not forgotten)

| Slice | Name | Depends on | Why deferred |
|---|---|---|---|
| 10+ | Pi-hole / DNS forwarders | Slice 2/6 DNS | Operational service, not provisioning core |
| 11+ | Observability (Prometheus/Grafana) | Slices 1–5 hosts | Monitoring is separate concern |
| 12+ | Bare-metal install (PXE/kickstart) | Slice 1 baseline | Lab uses cloud-init; prod install later |
| 14+ | Windows provisioning | Slice 2 AD | Manual/docs only — Windows clients out of scope |
| 15+ | NFS exports | Slice 5 file server | SMB first; NFS if needed later |

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
