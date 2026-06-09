# DDNS runbook (lab + production)

Slice 6 enables GSS-TSIG dynamic DNS updates against BIND on the Samba AD DC.
Slice 9 adds lease-driven updates from dnsmasq via a thin hook and Docker DDNS API on the DC.

## Lab hosts

| Host | Role |
|---|---|
| `dc01.lab.test` | BIND DLZ, `dnsupdater` keytab, DDNS API (Docker) |
| `member01.lab.test` | Domain member, nsupdate client keytab (Slice 6) |
| kvm01 (libvirt) | Lab dnsmasq + `dhcp-ddns-hook.sh` (Slice 9 integration) |

## Prerequisites

- Slice 2 DC converged (`dc-converge.yml`) — includes reverse zone and dnsupdater
- Vault variables `vault_dnsupdater_password` and `vault_ddns_shared_secret` set in lab vault
- For Slice 6 member clients: Slice 3 domain join on the member (`domain-join.yml`)

## Converge order

**Slice 6 — client-side nsupdate:**

```bash
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test

ansible-playbook playbooks/baseline.yml --limit member01.lab.test
ansible-playbook playbooks/domain-join.yml --limit member01.lab.test
ansible-playbook playbooks/ddns-client.yml --limit member01.lab.test
```

**Slice 9 — DHCP-driven DDNS API:**

```bash
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook playbooks/ddns-api.yml --limit dc01.lab.test
```

## What Ansible configures

**On the DC (`samba_dc` role):**

- Reverse zone `100.168.192.in-addr.arpa` for `192.168.100.0/24`
- AD user `dnsupdater` in `DnsAdmins`, password never expires
- Keytab at `/var/lib/samba/private/dnsupdater.keytab`

**On the DC (`ddns_nsupdate` role, Slice 9):**

- Docker Engine (`docker_engine` role)
- DDNS API at `http://<dc-ip>:8765` (HTTP + bearer token; TLS deferred)
- Container mounts DC keytab and `krb5.conf` (+ `krb5.conf.d`)

**On members (`ddns_client` role, Slice 6):**

- `bind9-dnsutils` (`nsupdate`, `dig`)
- Copy of DC keytab at `/etc/krb5.keytab.dnsupdater`

## Manual nsupdate test

On a converged member:

```bash
kinit -kt /etc/krb5.keytab.dnsupdater dnsupdater@LAB.TEST
nsupdate -g <<'EOF'
server 192.168.100.10
zone lab.test
update add testhost.lab.test 300 A 192.168.100.99
send
EOF
dig @192.168.100.10 testhost.lab.test A +short
```

## Production router (manual — not Ansible-managed)

Install the hook from this repository on the dnsmasq host (router or DHCP server):

1. Copy `scripts/dhcp-ddns-hook.sh` to `/usr/local/sbin/dhcp-ddns-hook.sh` (`chmod +x`)
2. Create `/etc/home-ddns.env` (mode `0600`, root-owned):

```sh
DDNS_UPDATE_URL="http://<dc-ip>:8765/ddns/v1/lease"
DDNS_BEARER_TOKEN="<same as vault_ddns_shared_secret>"
DDNS_DNS_DOMAIN="<your-domain>"
# Optional: DDNS_UPDATE_URL_FALLBACK="http://<replica-dc-ip>:8765/ddns/v1/lease"
```

3. Configure dnsmasq:

```conf
dhcp-script=/usr/local/sbin/dhcp-ddns-hook.sh
```

4. Optional UFW on the DC: set `ddns_nsupdate_manage_ufw: true` and `ddns_nsupdate_ufw_allow_cidrs` to your LAN CIDRs.

The hook requires `curl` and `python3` or `jq` on the router. It always exits 0 (fail-open) so DHCP is never blocked by API failures.

**Rotate bearer token:** update `vault_ddns_shared_secret`, re-run `ddns-api.yml`, update every `/etc/home-ddns.env` on dnsmasq hosts.

## API reference

- `GET /ddns/v1/health` — returns `200 ok`
- `POST /ddns/v1/lease` — JSON `{"action":"upsert"|"delete","address":"…","hostname":"label","client_id":"…"}`, header `Authorization: Bearer <secret>`

IPv4 upsert creates A + PTR. IPv4 delete removes PTR always; A is removed when hostname is set or inferred from PTR. IPv6 upsert/delete manages AAAA only (no ip6.arpa in this phase).

## Integration tests

**Slice 6 (member nsupdate client):**

```bash
LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

**Slice 9 (dhcp-script → API → dig):**

```bash
INTEGRATION_SLICE=dhcp_ddns ./scripts/test-integration.sh
```

Lab hook setup is automated via `scripts/lab/ddns-hook-ensure.sh` (writes `$(lab_data_dir)/home-ddns.env` on local disk) and `scripts/lab/dhcp-ddns-hook-lab.sh` (repo-local wrapper — no sudo). Libvirt dnsmasq uses the wrapper via `scripts/lab/libvirt/lab-network.xml.tmpl`.
