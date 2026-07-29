# ADR 003: Home Kubernetes platform (learning-first)

## Status

Accepted

## Context

Two HP Z2 Mini G3 workstations (`k8s-node-1`, `k8s-node-2`) were purchased for Kubernetes
learning but never integrated into automation. The estate already runs Docker Compose on
**kif** behind **proxy01** nginx + Authelia ([adr/002-docker-edge-vlan.md](002-docker-edge-vlan.md)).
ADR 001 deferred **Kubernetes ingress** as overkill for public edge scale.

The operator is building professional Kubernetes admin skills (CKA-shaped) and wants a
**real-ish** cluster without betting production identity or media workloads on day one.

Community **ingress-nginx** reached end-of-life in March 2026 (repo archived; no further
security patches). The Ingress API remains available but is feature-frozen; upstream
direction is the **Gateway API**. Employer-stack research
([home-lab-k8s-stack.md](../home-lab-k8s-stack.md)) recommended Cilium + Envoy Gateway
over Calico + another Ingress controller.

## Decision

1. **Learning-first cluster** — platform must become boring before migrating Compose apps
   from kif. Authelia/Plex/Paperless stay on Docker until etcd restore, drains, storage,
   and delivery (Argo CD) are proven.

2. **Topology**
   - **Control plane:** single Ubuntu 24.04 VM on a hypervisor (kvm01), VLAN 9.
   - **Workers:** two bare-metal Z2 Minis (16 GB, 512 GB NVMe), VLAN 9, workers only.
   - No control-plane HA until restore/upgrades are routine.

3. **Bootstrap:** **kubeadm + containerd** — Ansible owns OS baseline and node packages;
   first cluster bootstrap is manual (documented runbook). No k3s, Kubespray, or Talos for v1.
   Target Kubernetes **1.36** (supported until 2027-06-28 at time of writing).

4. **Network — VLAN 9** (`192.168.9.0/24`) as a **routed** Kubernetes fabric (not L2-only
   like VLAN 4 docker edge):
   - UCG gateway, static addressing, Pi-hole or DC DNS for nodes.
   - CP VM and workers share one L3 island; admin SSH from VLAN 1 via normal routing.
   - Pod/service CIDRs use non-`192.168.0.0/16` ranges (kubeadm defaults `10.244.0.0/16`,
     `10.96.0.0/12`) to avoid overlap with home VLANs. Cilium cluster-pool IPAM uses the
     same pod CIDR.

5. **Edge — hybrid model** (revises ADR 001’s “no K8s ingress” for *public* edge only):
   - **proxy01** keeps Internet TLS, certbot, Authelia forward-auth, rate limits.
   - In-cluster **Envoy Gateway** (Gateway API: `Gateway` + `HTTPRoute`) receives HTTP
     from proxy01.
   - **MetalLB L2** advertises a stable VIP on VLAN 9 for the Envoy Gateway
     `LoadBalancer` Service.
   - **Do not** use community ingress-nginx.

6. **CNI:** **Cilium** (eBPF datapath, NetworkPolicy, Hubble). Cilium Gateway API and
   Cilium L2 announcements are **not** enabled in v1 — Envoy Gateway owns L7; MetalLB
   owns LB VIPs (portable skills; fewer CNI/L7 coupling surprises).

7. **Storage:** **local-path-provisioner** default + **NFS from kif** for shared/durable PVCs.
   Longhorn/Ceph deferred until additional shared disk capacity exists.

8. **Identity:** cert-based kubeconfigs via bastion; Authelia OIDC for kubectl later.
   Kube nodes are **not** domain-joined; local **break-glass** operator SSH (DC pattern).

9. **Delivery:** kubectl/Helm for bootstrap; **Argo CD** after the first useful app works.

10. **Backup bar:** scheduled **etcd snapshots** (+ kubeadm certs) off-box before any
    non-disposable workload.

11. **Deferred platform add-ons:** cert-manager (in-cluster/internal TLS) after the first
    Gateway HTTPRoute works over plain HTTP from proxy01; kube-proxy replacement via
    Cilium later.

## IPAM (FerryCrossing VLAN 9)

| Role | Address | Notes |
|---|---|---|
| Gateway | `192.168.9.1` | UCG — routed VLAN |
| Control plane VM | `192.168.9.10` | `k8s-cp01.home.2123studios.com` |
| Worker 1 | `192.168.9.128` | `k8s-node-1.home.2123studios.com` |
| Worker 2 | `192.168.9.129` | `k8s-node-2.home.2123studios.com` |
| MetalLB pool | `192.168.9.200`–`192.168.9.210` | L2 VIP for Envoy Gateway |

Document static DNS A records for CP, workers, and the gateway VIP. Reserve pool addresses
in UniFi — do not assign via DHCP.

## Consequences

- Requires new UniFi VLAN 9, firewall rules (VLAN 9 ↔ VLAN 1 for NFS/DNS/apt and
  proxy01 → MetalLB VIP), and `dc_trusted_networks` update if nodes query DC DNS directly.
- Hypervisors need **br9/vlan9** libvirt network for the CP VM ([hypervisor-runbook.md](../hypervisor-runbook.md)).
- Metal nodes use USB/cloud-init reimage; `k8s_node` role prepares packages but not
  `kubeadm init/join` in v1.
- NFS PVCs couple cluster durability to kif availability (Slice 15+ production proof pending).
- Single CP VM is an SPOF for the API — acceptable for learning; document recovery.
- ROADMAP “Authelia container HA” remains blocked until this platform is boring.
- App routing uses `HTTPRoute` (and later `ReferenceGrant`), not Ingress annotations.
- Gateway API CRDs must be installed/pinned explicitly and kept compatible with the
  Envoy Gateway release (do not let Helm silently downgrade CRDs).

## Alternatives considered

| Alternative | Rejected because |
|---|---|
| k3s | Hides control-plane surface the operator wants to learn |
| Stacked CP+worker on Z2 metal | Muddies capacity; CP etcd competes with app workloads |
| CP on VLAN 1, workers on VLAN 9 | Cross-VLAN API complexity on day one |
| L2-only VLAN 9 (like VLAN 4) | Nodes need routed DNS, apt, NFS without dual-homing everything |
| In-cluster public ingress only (no proxy01) | Bypasses certbot, Authelia, ADR 002 edge model |
| NodePort-only (no MetalLB) | Ugly dual-upstreams; poor match for static nginx backends |
| Community ingress-nginx | EOL March 2026; no security patches; Ingress API feature-frozen |
| F5 NGINX Ingress Controller (NIC) | Still Ingress-shaped; continuity play, weak Gateway API skills |
| Traefik as primary L7 | Fine for speed-to-HTTP; weaker long-term Gateway investment |
| Cilium alone (CNI + Gateway + L2) | Fewer moving parts, but L7 tied to CNI; Path A preferred for portable Envoy Gateway skills |
| Calico CNI | NetworkPolicy only; Cilium adds eBPF + Hubble matching modern platform practice |
| Cilium L2 instead of MetalLB (v1) | MetalLB keeps LB learning separate from CNI; revisit after Gateway is boring |
| Longhorn/Ceph on two 512 GB nodes | Storage cluster is a second hobby; needs more disks |
| Domain-join kube nodes | SSSD/PAM friction; cluster auth is separate from AD login |
| Migrate Compose apps day one | Too much blast radius before restore/delivery proven |
| Full Kubespray / idempotent kubeadm in Ansible v1 | Operator should feel init/join failure modes first |
| Kubernetes 1.31 | EOL 2025-11-11; final patch 1.31.14 — unsupported |

## References

- [kubernetes-runbook.md](../kubernetes-runbook.md)
- [home-lab-k8s-stack.md](../home-lab-k8s-stack.md) — employer-informed stack brief (Path A adopted)
- [adr/001-bastion-keepalived-vip.md](001-bastion-keepalived-vip.md)
- [adr/002-docker-edge-vlan.md](002-docker-edge-vlan.md)
- [edge-access-model.md](../edge-access-model.md)
- [unifi-gateway-dns.md](../unifi-gateway-dns.md)
- [hypervisor-runbook.md](../hypervisor-runbook.md)
- [nfs-server-runbook.md](../nfs-server-runbook.md)
- [cka-runbook.md](../cka-runbook.md)
