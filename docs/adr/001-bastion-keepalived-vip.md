# ADR 001: Bastion / edge HA via keepalived VIP

## Status

Accepted (deferred implementation)

## Context

Production exposes HTTPS and SSH through a single bastion VM (`shell-clt01`) on kvm01.
UniFi Cloud Gateway inbound port-forward rules target a **single IP address** — dual-A DNS
records cannot satisfy this constraint.

A power outage on kvm01 (before UPS) took down the bastion, reverse proxy, and everything
behind public HTTPS even when kif and its services remained up.

## Decision

When bastion HA is implemented:

1. Deploy a **second** bastion/reverse-proxy VM on the other hypervisor (kif).
2. Front both with a **keepalived floating VIP** on the LAN.
3. Point UniFi port-forwards at the **VIP**, not individual VM IPs.
4. Do **not** use dual-A public or internal DNS for the edge — clients and the router need
   one stable target.

This mirrors the LDAP VIP pattern on dc1/dc2 ([ldap-vip-runbook.md](../ldap-vip-runbook.md)).

## Consequences

- Requires VRRP on two bastion hosts, shared nginx/cert sync or independent SAN certs on
  both nodes, and coordinated keepalived health checks (nginx + sshd).
- Cert renewal must reload nginx on whichever node holds the VIP (and ideally both nodes).
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
- [ROADMAP.md](../ROADMAP.md) — deferred bastion VIP HA slice
