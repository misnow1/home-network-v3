# DNS architecture (lab)

Slice 2 establishes BIND9 as the authoritative DNS backend for the Samba AD domain
via DLZ (Dynamically Loadable Zones). Slice 6 adds GSS-TSIG dynamic updates from
domain members. Slice 9 adds lease-driven updates from dnsmasq.

## Lab domain

| Setting | Value |
|---|---|
| Domain | `lab.test` |
| Realm | `LAB.TEST` |
| NetBIOS | `LAB` |
| DC | `dc01.lab.test` (`192.168.100.10`) |

## Components

| Service | Role |
|---|---|
| **samba-ad-dc** | Active Directory (LDAP/Kerberos), generates DLZ zone data |
| **named (BIND9)** | Authoritative DNS for `lab.test`, loads Samba zone via DLZ |
| **chrony** | Time sync; converge extends with MS-SNTP signing for domain members |
| **dnsupdater** | AD service account in DnsAdmins for GSS-TSIG nsupdate clients |
| **ddns-nsupdate (Docker)** | HTTP API on DC; runs `kinit` + `nsupdate -g` for dhcp-script callers |
| **dhcp-ddns-hook** | Thin dnsmasq `dhcp-script` on DHCP server; POSTs lease events to DDNS API |

Samba's internal DNS server is **not** used. `samba-tool domain provision` is called with
`--dns-backend=BIND9_DLZ`.

## Lease-driven path (Slice 9)

```
dnsmasq (router/kvm01) --dhcp-script--> dhcp-ddns-hook.sh --HTTP POST-->
  ddns-nsupdate container on DC --GSS-TSIG nsupdate--> BIND on DC
```

Production routers are configured manually — the FerryCrossing gateway is a
UniFi Cloud Gateway Fiber; see [unifi-gateway-dns.md](unifi-gateway-dns.md) (router)
and [ddns-runbook.md](ddns-runbook.md) (DC API + deployment). Lab libvirt dnsmasq
uses the same hook via `scripts/lab/libvirt/lab-network.xml`.

## Configuration (Ansible-managed)

| File | Managed by | Notes |
|---|---|---|
| `/etc/bind/named.conf.options` | `named.conf.options.j2` | Forwarders, GSS-TSIG keytab path |
| `/etc/bind/named.conf.local` | blockinfile | Includes `/var/lib/samba/bind-dns/named.conf` |
| `/var/lib/samba/bind-dns/named.conf` | samba-tool | **Never template** — Samba-generated |
| `/var/lib/samba/private/dnsupdater.keytab` | `dnsupdater.yml` | Client update credentials (Slice 6) |
| `/etc/krb5.keytab.dnsupdater` | `ddns_client` role | Member copy of dnsupdater keytab |
| `/opt/ddns-nsupdate/` | `ddns_nsupdate` role | Docker compose project (Slice 9) |
| Samba `smb.conf` `interfaces` / `bind interfaces only` | `samba_interfaces.yml` | DC self-registration limited to primary NIC + lo |

## DC hostname registration (A/AAAA)

Samba's `samba_dnsupdate` (triggered by `samba-ad-dc`) registers the DC's own hostname
in AD DNS. Without interface binding, **every** host IP — including Docker bridges
(`docker0`, `br-*`) — can appear as A/AAAA records.

Ansible enforces on bootstrap, replica join, and converge:

```ini
interfaces = lo <primary-nic>
bind interfaces only = yes
```

| Variable | Default | Purpose |
|---|---|---|
| `samba_dc_bind_interfaces_only` | `true` | Enable interface binding |
| `samba_dc_interfaces` | `[]` | Explicit list (e.g. `[lo, enp1s0]`); empty = auto-detect `lo` + `ansible_default_ipv4.interface` |

After binding, converge prunes stale A/AAAA records for the DC hostname and runs
`samba_dnsupdate`. Override `samba_dc_interfaces` in host_vars when auto-detect picks
the wrong NIC.

## Integration test proof

**Slice 2 (static DNS):**

- `samba-ad-dc` and `named` running
- LDAP root DSE responds
- `_ldap._tcp.lab.test` SRV record resolves via BIND on the DC
- Kerberos ticket for `Administrator@LAB.TEST`

**Slice 6 (dynamic DNS — client nsupdate):**

- Reverse zone `100.168.192.in-addr.arpa` present
- `nsupdate -g` adds A + PTR records from a domain member
- `dig @dc01` confirms forward and reverse records

**Slice 9 (dynamic DNS — DHCP lease):**

- DDNS API health check on `:8765`
- DHCP probe VM receives lease; hook registers `dhcpprobe.lab.test`
- `dig @dc01` confirms A + PTR

See `docs/ddns-runbook.md` for converge order and manual examples.
