# Run order and production safety

## Lab development (default)

All integration work uses the lab inventory:

```bash
ansible-playbook -i inventories/lab playbooks/baseline.yml
ansible-playbook -i inventories/lab playbooks/dc-bootstrap.yml --limit dc01.lab.test
ansible-playbook -i inventories/lab playbooks/dc-converge.yml --limit dc01.lab.test
ansible-playbook -i inventories/lab playbooks/hypervisor.yml --limit hv01.lab.test
ansible-playbook -i inventories/lab playbooks/fileserver.yml --limit nas01.lab.test
./scripts/test-quick.sh
./scripts/test-integration.sh
```

`ansible.cfg` defaults to `inventories/lab`.

## Production runs

1. Copy `inventories/production/hosts.yml.example` to `inventories/production/hosts.yml`
2. Populate real hosts and create `inventories/production/group_vars/vault.yml`
3. Use the production wrapper — never call `ansible-playbook -i inventories/production` directly:

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit nas.example.home
```

Runs are logged under `logs/prod-run-*.log`.

## Destructive playbooks

Playbooks that create or rebuild directory services (for example `dc-bootstrap.yml`, when added
in Slice 2) must:

1. Refuse to run when the inventory path contains `production/` unless
   `-e allow_production=true` is explicitly passed (break-glass).
2. Document the break-glass procedure in the playbook header and a runbook under `docs/`.

Normal converge playbooks (baseline, docker, etc.) may run against production via
`scripts/prod-run.sh` without break-glass.

## Apply order (target state)

When production convergence is enabled (Slice 8):

1. Time sync (chrony) before directory-sensitive work
2. Domain controllers (bootstrap once, then converge)
3. File servers and hypervisors
4. Domain members and workstations

See slice-specific runbooks as they are added.
