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

## Production — trusted networks and BIND ACLs

All hosts in the Ansible `dc` group (dc1, dc2, future site DCs) receive identical
BIND query/recursion ACLs from **`group_vars/dc/vars.yml`** — never per-host BIND edits.

| Variable | Scope | Purpose |
|---|---|---|
| `dc_trusted_networks` | All DCs | Estate-wide IPv4 CIDRs permitted to query/recurse |
| `samba_dc_dns_allowed_networks` | All DCs | Defaults to `dc_trusted_networks`; templated into `named.conf.options` |
| `dc_ntp_allow_cidr` | All DCs | MS-SNTP chrony allow — often **narrower** than DNS (e.g. VLAN 1 only) |
| `samba_dc_dns_include_localnets` | Role default | Adds BIND `localnets` ACL for on-link GUA (dynamic ISP prefix) |

**host_vars** per DC hold only site-specific join flags, reverse zones, and NIC overrides
— see [dc-runbook.md](dc-runbook.md).

After changing ACLs, converge every DC:

```bash
ansible-playbook playbooks/dc-converge.yml --limit dc
```

Production example (`inventories/production/group_vars/dc/vars.yml`):

```yaml
dc_trusted_networks:
  - 192.168.1.0/24    # FerryCrossing VLAN 1
  - 192.168.3.0/24    # FerryCrossing VLAN 2 (IoT)
  - 192.168.33.0/24   # Woodbine (VPN-forwarded)
  - 192.168.65.0/24   # Swanhollow (VPN-forwarded)
  # NOT 192.168.5.0/24 — VLAN 3 isolated

samba_dc_dns_allowed_networks: "{{ dc_trusted_networks }}"
dc_ntp_allow_cidr: 192.168.1.0/24   # chrony — VLAN 1 only
```

Router/DHCP configuration is manual — see [unifi-gateway-dns.md](unifi-gateway-dns.md)
and [remote-site-dns.md](remote-site-dns.md).

## IPv6 and dynamic ISP prefix

BIND listens on IPv6 (`listen-on-v6 { any; }`) and includes the built-in **`localnets`**
ACL when `samba_dc_dns_include_localnets: true` (default). `localnets` matches every
network corresponding to a local interface address — when the ISP delegates a new GUA
`/64` after a modem reboot, on-link clients are permitted without Ansible edits.

| Concern | Approach |
|---|---|
| DC hostname AAAA | **Do not publish** ISP GUA — `samba_interfaces.yml` binds Samba to LAN NIC + lo |
| Client AAAA | DHCPv6 lease path via `dhcp-ddns-hook.sh` (Slice 9) |
| Hardcoded `2600:…/64` | **Never** in inventory — use `localnets` |
| Stale client AAAA after prefix change | DDNS upsert on lease renew; manual `samba-tool dns delete` for orphans |
| Auto ip6.arpa reverse zone | See [migration-runbook.md](migration-runbook.md) — add NS glue or delete zone |

After a modem reboot, run `dc-converge.yml --limit dc` if BIND was restarted before the
new prefix appeared on the NIC; otherwise `localnets` updates automatically on reload.
