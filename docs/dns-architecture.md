# DNS architecture (lab)

Slice 2 establishes BIND9 as the authoritative DNS backend for the Samba AD domain
via DLZ (Dynamically Loadable Zones). Slice 6 adds GSS-TSIG dynamic updates.

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

Samba's internal DNS server is **not** used. `samba-tool domain provision` is called with
`--dns-backend=BIND9_DLZ`.

## Configuration (Ansible-managed)

| File | Managed by | Notes |
|---|---|---|
| `/etc/bind/named.conf.options` | `named.conf.options.j2` | Forwarders, GSS-TSIG keytab path |
| `/etc/bind/named.conf.local` | blockinfile | Includes `/var/lib/samba/bind-dns/named.conf` |
| `/var/lib/samba/bind-dns/named.conf` | samba-tool | **Never template** — Samba-generated |
| `/var/lib/samba/private/dnsupdater.keytab` | `dnsupdater.yml` | Client update credentials (Slice 6) |
| `/etc/krb5.keytab.dnsupdater` | `ddns_client` role | Member copy of dnsupdater keytab |

## Integration test proof

**Slice 2 (static DNS):**

- `samba-ad-dc` and `named` running
- LDAP root DSE responds
- `_ldap._tcp.lab.test` SRV record resolves via BIND on the DC
- Kerberos ticket for `Administrator@LAB.TEST`

**Slice 6 (dynamic DNS):**

- Reverse zone `100.168.192.in-addr.arpa` present
- `nsupdate -g` adds A + PTR records from a domain member
- `dig @dc01` confirms forward and reverse records

## Deferred (later slices)

- dhcp-dns hooks
- Automated lease-driven updates from dnsmasq/Docker API

See `docs/ddns-runbook.md` for converge order and manual nsupdate examples.
