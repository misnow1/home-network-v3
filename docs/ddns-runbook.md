# DDNS runbook (lab)

Slice 6 enables GSS-TSIG dynamic DNS updates against BIND on the Samba AD DC.

## Lab hosts

| Host | Role |
|---|---|
| `dc01.lab.test` | BIND DLZ, `dnsupdater` service account + keytab |
| `member01.lab.test` | Domain member, nsupdate client keytab |

## Prerequisites

- Slice 2 DC converged (`dc-converge.yml`) — includes reverse zone and dnsupdater
- Slice 3 domain join on the member (`domain-join.yml`)
- Vault variable `vault_dnsupdater_password` set in lab vault

## Converge order

```bash
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test

ansible-playbook playbooks/baseline.yml --limit member01.lab.test
ansible-playbook playbooks/domain-join.yml --limit member01.lab.test
ansible-playbook playbooks/ddns-client.yml --limit member01.lab.test
```

## What Ansible configures

**On the DC (`samba_dc` role):**

- Reverse zone `100.168.192.in-addr.arpa` for `192.168.100.0/24`
- AD user `dnsupdater` in `DnsAdmins`, password never expires
- Keytab at `/var/lib/samba/private/dnsupdater.keytab`

**On members (`ddns_client` role):**

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

## Integration test

```bash
LAB_HOST=member01.lab.test ./scripts/test-integration.sh
```

Provisions DC + member, joins domain, converges DDNS client, adds/deletes A + PTR
records via GSS-TSIG, verifies with `dig`.

## Out of scope (later slices)

- dhcp-dns hooks / dnsmasq integration
- Docker DDNS API from home-ansible v1
