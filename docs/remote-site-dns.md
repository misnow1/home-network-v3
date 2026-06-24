# Remote-site DNS (Woodbine, Swanhollow)

Until each remote site has a local domain controller, clients there need AD DNS
without listing FerryCrossing DC IPs as their sole DHCP DNS servers. The interim
pattern is **conditional forwarders** on each site gateway: the router resolves
`home.2123studios.com` (and related zones) via VPN to dc1/dc2; everything else
uses normal upstream DNS.

See also:

- [ad-sites.md](ad-sites.md) — AD sites, subnets, future local DCs
- [unifi-gateway-dns.md](unifi-gateway-dns.md) — FerryCrossing UCG (DHCP, DDNS hook)
- [dns-architecture.md](dns-architecture.md) — BIND ACLs on DCs (`dc_trusted_networks`)

## Prerequisites

1. Site-to-site VPN routes remote LANs to FerryCrossing (`192.168.33.0/24` ↔
   `192.168.1.0/24`, same for Swanhollow `192.168.65.0/24`).
2. FerryCrossing DCs allow queries from remote subnets — `dc_trusted_networks` in
   `group_vars/dc/vars.yml` includes `192.168.33.0/24` and `192.168.65.0/24`.
3. Firewall permits **UDP/TCP 53** from remote subnets to dc1/dc2.

If VPN NAT masks the source subnet, capture queries on dc1 (`tcpdump -i any port 53`)
and add the observed source CIDR to `dc_trusted_networks`, then `dc-converge.yml --limit dc`.

## Architecture (interim)

```
Woodbine client → UCG dnsmasq (192.168.33.1)
                    ├─ home.2123studios.com / _msdcs / reverse → dc1, dc2 (VPN)
                    └─ other names → upstream public DNS
```

When a **local DC** is installed at Woodbine or Swanhollow:

1. Add the host to inventory under `dc:` with `samba_dc_join_site` set.
2. Run `dc-replica-join.yml` then `dc-converge.yml --limit dc`.
3. Set site DHCP DNS to the **local DC IP** (site-aware).
4. Keep or remove conditional forwarders to FerryCrossing (optional fallback).

## UniFi on-boot inject (per remote gateway)

Use the same `/data/on_boot.d/` persistence model as
[unifi-gateway-dns.md](unifi-gateway-dns.md). Inject dnsmasq `server=/zone/dc-ip` lines
for **every DC** in the inventory `dc` group — not dc1 alone.

Example for Woodbine gateway (`192.168.33.1`) while FerryCrossing hosts dc1 and dc2:

```bash
# /data/on_boot.d/30-remote-ad-dns.sh (example — adjust DC IPs from inventory)
CONF="/run/dnsmasq.dhcp.conf.d/remote-ad-forwarders.conf"
cat > "${CONF}" <<'EOF'
server=/home.2123studios.com/192.168.1.10
server=/home.2123studios.com/192.168.1.11
server=/_msdcs.home.2123studios.com/192.168.1.10
server=/_msdcs.home.2123studios.com/192.168.1.11
server=/33.168.192.in-addr.arpa/192.168.1.10
server=/65.168.192.in-addr.arpa/192.168.1.10
EOF
kill "$(cat /run/dnsmasq-main.pid)" 2>/dev/null || true
```

Repeat for Swanhollow (`192.168.65.1`) with the same DC targets (VPN reachability).

**Do not** add a second `dhcp-script=` line — remote sites do not need the FerryCrossing
DDNS hook until local DHCP registers leases against a site DC.

## DHCP DNS at remote sites (interim)

Keep **DHCP DNS Server** in UniFi as the **local router** (`192.168.33.1` or
`192.168.65.1`). Do not point DHCP option 6 directly at FerryCrossing DC IPs unless
the VPN is always up and you accept cross-site DNS dependency.

## Verification

From a client on Woodbine:

```bash
dig @192.168.33.1 dc1.home.2123studios.com A +short    # via forwarder
dig @192.168.1.10 home.2123studios.com SOA +short      # direct over VPN (optional)
```

From dc1:

```bash
sudo tcpdump -ni any port 53 and host 192.168.33.x
```

## Deferred

- DDNS hooks at remote sites (until local DC or central DDNS over VPN is required)
- RSAT inter-site links ([ad-sites.md](ad-sites.md) §5) — needed when remote DCs replicate
