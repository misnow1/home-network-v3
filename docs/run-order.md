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

See **[production-runbook.md](production-runbook.md)** for the full apply order and examples.

1. Copy `inventories/production/hosts.yml.example` to `inventories/production/hosts.yml`
2. Copy `inventories/production/group_vars/*/vars.yml.example` files to `vars.yml` and customize
3. Create `inventories/production/group_vars/vault.yml` with real secrets
4. Use the production wrapper — never call `ansible-playbook -i inventories/production` directly:

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit nas.example.home
```

Runs are logged under `logs/prod-run-*.log`.

Tier 2 CI runs `./scripts/test-prod-safety.sh` to verify wrapper guardrails without a real production inventory.

## Destructive playbooks

Playbooks that create or rebuild directory services (for example `dc-bootstrap.yml`) must:

1. Refuse to run when the inventory path contains `production/` unless
   `-e allow_production=true` is explicitly passed (break-glass).
2. Document the break-glass procedure in the playbook header and a runbook under `docs/`.

Normal converge playbooks (baseline, hypervisor, etc.) may run against production via
`scripts/prod-run.sh` without break-glass.

## Apply order (production)

1. Time sync (chrony) — `baseline.yml` on all Linux hosts
2. Domain controllers — `dc-bootstrap.yml` once, then `dc-converge.yml`
3. Hypervisors — `hypervisor.yml`, then `backup.yml`
4. File servers — `fileserver.yml`
5. Domain members — `domain-join.yml` on `linux:!dc`
6. DDNS clients — `ddns-client.yml` (optional)

See [production-runbook.md](production-runbook.md) for command examples and slice runbooks.
