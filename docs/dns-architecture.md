# DNS architecture (lab)

Slice 2 establishes BIND9 as the authoritative DNS backend for the Samba AD domain
via DLZ (Dynamically Loadable Zones).

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

Samba's internal DNS server is **not** used. `samba-tool domain provision` is called with
`--dns-backend=BIND9_DLZ`.

## Configuration (Ansible-managed)

| File | Managed by | Notes |
|---|---|---|
| `/etc/bind/named.conf.options` | `named.conf.options.j2` | Forwarders, GSS-TSIG keytab path |
| `/etc/bind/named.conf.local` | blockinfile | Includes `/var/lib/samba/bind-dns/named.conf` |
| `/var/lib/samba/bind-dns/named.conf` | samba-tool | **Never template** — Samba-generated |

## Integration test proof

Automated tests verify:

- `samba-ad-dc` and `named` running
- LDAP root DSE responds
- `_ldap._tcp.lab.test` SRV record resolves via BIND on the DC
- Kerberos ticket for `Administrator@LAB.TEST`

## Deferred (Slice 6+)

The following are intentionally **out of scope** for Slice 2:

- GSS-TSIG keytab generation for update clients
- `nsupdate` / DDNS client automation
- dhcp-dns hooks
- Automated dynamic record add/delete tests

Slice 2 proves BIND serves AD DNS correctly via DLZ. Dynamic updates land once domain
members exist to act as update clients.
