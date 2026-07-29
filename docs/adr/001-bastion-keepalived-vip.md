# ADR 001: Bastion / edge HA via keepalived VIP

## Status

Accepted (deferred implementation)

## Context

Production exposes SSH through **shell-clt01** and HTTPS through **proxy01** (separate
VMs per [adr/002-docker-edge-vlan.md](002-docker-edge-vlan.md)). UniFi Cloud Gateway
inbound port-forward rules target a **single IP address** per service — dual-A DNS
records cannot satisfy this constraint.

A power outage on kvm01 (before UPS) took down the bastion, reverse proxy, and everything
behind public HTTPS even when kif and its services remained up.

## Decision

When edge HA is implemented:

1. Deploy a **second** bastion VM on the other hypervisor (kif) for SSH.
2. Deploy a **second** proxy VM on the other hypervisor for HTTPS.
3. Front SSH peers with a **keepalived floating VIP** on VLAN 1; front HTTPS peers
   with a separate VIP (also VLAN 1 for UniFi forwards).
4. Add a **vlan4 VIP** for docker-side proxy traffic when both proxy nodes need to
   reach backends during failover.
5. Point UniFi port-forwards at the **VIPs**, not individual VM IPs.
6. Do **not** use dual-A public or internal DNS for the edge — clients and the router need
   one stable target per service.

This mirrors the LDAP VIP pattern on dc1/dc2 ([ldap-vip-runbook.md](../ldap-vip-runbook.md)).

## Consequences

- Requires VRRP on two bastion hosts and two proxy hosts (or paired roles), shared
  nginx/cert sync or independent SAN certs on both proxy nodes, and coordinated
  keepalived health checks (nginx + sshd on respective VMs).
- Cert renewal must reload nginx on whichever proxy node holds the HTTPS VIP (and ideally both nodes).
- Update `host_firewall_edge_proxy_cidrs` with the vlan4 keepalived VIP when deployed.
- Authelia remains on kif today — edge HA without Authelia HA still improves SSH and
  static/offline surfaces; full app auth HA is a separate concern.
- Documented in ROADMAP as deferred until a second bastion is provisioned.

## Alternatives considered

| Alternative | Rejected because |
|---|---|
| Dual-A DNS for edge | UniFi port-forwards require one IP |
| Move sole bastion to kif | Still single VM SPOF |
| HAProxy on kif only | Does not survive kif loss; wrong layer for public ingress |
| Kubernetes ingress | Overkill for current scale; deferred with broader container migration |

## References

- [bastion-runbook.md](../bastion-runbook.md)
- [reverse-proxy-runbook.md](../reverse-proxy-runbook.md)
- [adr/002-docker-edge-vlan.md](002-docker-edge-vlan.md)
