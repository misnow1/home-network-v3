# home-network-v3 Roadmap

Canonical backlog for slices and deferred work. Update this file when scope changes.

## Active slices

| Slice | Name | Status | Notes |
|---|---|---|---|
| 0 | Test harness | **done** | CI, lab scripts, structural tests, integration VM cycle |
| 1 | Ubuntu baseline | **done** | `linux_baseline` role, `baseline.yml`, idempotency test |
| 2 | Samba AD DC + BIND DLZ | **done** | `dc01.lab.test`, bootstrap/converge split |
| 3 | Domain join (realmd + sssd) | planned | `member01.lab.test`, RFC2307 IDs, short names |
| 4 | Hypervisor (nested virt) | planned | `hv01.lab.test`, libvirt + Docker |
| 5 | Samba file server | planned | `nas01.lab.test`, winbind, `idmap_ad`, SMB test share |
| 6 | DDNS / nsupdate automation | planned | GSS-TSIG updates against BIND on DC |
| 7 | Backups + restore drills | planned | Scope manifests, automated restore drill |
| 8 | Production convergence | planned | Runbooks, prod wrapper, explicit opt-in |

## Deferred (not forgotten)

| Slice | Name | Depends on | Why deferred |
|---|---|---|---|
| 9+ | Certbot DNS validation | Slice 2 DC, stable DNS | Not needed for lab proof |
| 10+ | Pi-hole / DNS forwarders | Slice 2/6 DNS | Operational service, not provisioning core |
| 11+ | Observability (Prometheus/Grafana) | Slices 1–5 hosts | Monitoring is separate concern |
| 12+ | Bare-metal install (PXE/kickstart) | Slice 1 baseline | Lab uses cloud-init; prod install later |
| 13+ | DC replica | Slice 2 DC | Single DC sufficient for lab |
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
