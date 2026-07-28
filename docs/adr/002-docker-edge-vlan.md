# ADR 002: Docker edge VLAN segmentation

## Status

Accepted

## Context

Production exposed HTTPS and SSH through a single VM (`shell-clt01`) that ran both
bastion hardening and nginx reverse proxy. Docker application backends (Authelia,
Guacamole, Paperless, Transmission, Plex) run on **kif** with host-published ports
restricted by UFW to the reverse-proxy IP on the home LAN (`192.168.1.0/24`).

Problems with the combined model:

1. **Attack surface** — nginx, certbot, and sshd share a domain-joined bastion VM.
2. **LAN bypass risk** — backends listen on addresses reachable from the full LAN;
   UFW is the only control preventing direct access to container ports.
3. **Operational coupling** — cert renewal, nginx reloads, and bastion maintenance
   affect the same host.

## Decision

1. **Split edge roles across two VMs:**
   - **shell-clt01** — SSH bastion only (domain-joined, GSSAPI, fail2ban).
   - **proxy01** — nginx reverse proxy + certbot (standalone Ubuntu 24.04, no AD join).

2. **Introduce VLAN 4** (`192.168.7.0/24`) as an **L2-only** Docker backend network:
   - Host bridges **br4** on kif and kvm01, libvirt network **vlan4**.
   - **No UniFi gateway, DHCP, DNS, or Internet routing** on VLAN 4.
   - Mirrored addressing: kif `192.168.7.152`, kvm01 `192.168.7.21`, proxy01 `192.168.7.23`.

3. **Proxy-facing container ports** bind on kif br4 (`192.168.7.152`) via Docker
   publish syntax. UFW allows these ports only from proxy01's docker NIC
   (`192.168.7.23/32`).

4. **nginx backends** use static `192.168.7.x` IPs (not LAN hostnames).

5. **Transmission exception** — RPC/web UI (9091) stays on VLAN 4 (proxy-only);
   BitTorrent peer port (51413) publishes on VLAN 1 (`192.168.1.152`) for UniFi
   port-forwarding. Outbound tracker/DHT traffic uses Docker NAT via br0 — VLAN 4
   does not need Internet access.

6. **UniFi port-forwards:** SSH (22) → shell-clt01; HTTP/HTTPS (80/443) → proxy01;
   Transmission peer port → kif VLAN 1 (unchanged target, new bind model).

## Consequences

- Requires UniFi VLAN 4 trunk on hypervisor uplinks (manual, no gateway).
- Hand-managed Compose on kif must use explicit `192.168.7.152:PORT` publish binds.
- Authelia `trusted_proxies` must include `192.168.7.23/32`.
- proxy01 is dual-homed (VLAN 1 public + VLAN 4 docker); ansible admin via LAN SSH.
- Future edge HA (ADR 001) splits into SSH VIP vs HTTPS VIP; add vlan4 VIP for
  docker-side proxy when deploying keepalived on proxy01.

## Alternatives considered

| Alternative | Rejected because |
|---|---|
| Gateway on VLAN 4 for Internet | Expands blast radius for all proxy backends |
| macvlan per container | More moving parts; host-bind + UFW is sufficient |
| Keep nginx on bastion | Does not reduce attack surface |
| Route VLAN 4 through UniFi with firewall rules | L2-only is simpler and matches VLAN 3 isolation pattern |

## References

- [reverse-proxy-runbook.md](../reverse-proxy-runbook.md)
- [edge-access-model.md](../edge-access-model.md)
- [hypervisor-runbook.md](../hypervisor-runbook.md)
- [adr/001-bastion-keepalived-vip.md](001-bastion-keepalived-vip.md)
- [Transmission configuration](https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md)
