# Domain join runbook (Slice 3)

Ubuntu lab members join `lab.test` via **realmd + sssd** (no winbind on general Linux hosts).

## Lab integration (automated)

```bash
./scripts/test-integration.sh
```

Default host is `member01.lab.test` — provisions `dc01`, creates test AD user, joins member, verifies, tears down both VMs.

Slice-specific regression:

```bash
LAB_HOST=dc01.lab.test ./scripts/test-integration.sh   # Slice 2
LAB_HOST=member01.lab.test LAB_SLICE=... # default domain_join
```

## Manual lab workflow

```bash
# DC must exist first (Slice 2)
./scripts/lab/vm-create.sh dc01.lab.test
./scripts/lab/wait-ssh.sh dc01.lab.test
ansible-playbook playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook tests/integration/setup_lab_ad_users.yml --limit dc01.lab.test

# Member join
./scripts/lab/vm-create.sh member01.lab.test
./scripts/lab/wait-ssh.sh member01.lab.test
ansible-playbook playbooks/baseline.yml --limit member01.lab.test
ansible-playbook playbooks/domain-join.yml --limit member01.lab.test
ansible-playbook tests/integration/test_domain_join_converged.yml --limit member01.lab.test
```

Re-run `domain-join.yml` twice — second run must report `changed=0`.

## SSSD settings

See [sssd-config.md](sssd-config.md):

- `ldap_id_mapping = false` — RFC2307 `uidNumber` / `gidNumber` from AD
- `use_fully_qualified_names = False` — short names (`labtest`, not `labtest@lab.test`)

## Vault variables

| Variable | Purpose |
|---|---|
| `vault_ad_join_user` | Account used by `realm join` (lab: `Administrator`) |
| `vault_ad_join_password` | Join account password |
| `vault_test_user_password` | Lab AD user for integration tests |

## Apply order

1. `baseline.yml` — chrony before Kerberos
2. `domain-join.yml` — packages, DNS, realm join, sssd.conf, mkhomedir

DC hosts (`dc` group) are excluded — they never run `domain_join`.

Winbind is reserved for the Samba file server slice (Slice 5) on `nas01.lab.test`.
