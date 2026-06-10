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

## CKA practice VMs

CKA nodes on vlan3 use a separate inventory and converge playbook — not part of lab
integration tests or production apply order. See **[cka-runbook.md](cka-runbook.md)**.

```bash
cp inventories/cka/hosts.yml.example inventories/cka/hosts.yml
./scripts/cka/inventory-set-host.sh --name cka-cp1 --discover
ansible-playbook -i inventories/cka playbooks/cka-converge.yml --limit cka-cp1
```

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

### Greenfield

1. Time sync (chrony) — `baseline.yml` on all Linux hosts
2. Domain controllers — `dc-bootstrap.yml` once, then `dc-converge.yml`
3. Hypervisors — `hypervisor.yml`, then `backup.yml`
4. File servers — `fileserver.yml`
5. Domain members — `domain-join.yml` on `linux:!dc`
6. DDNS clients — `ddns-client.yml` (optional)
7. DDNS API — `ddns-api.yml` on DCs when dhcp-script integration is used

### AD migration (existing Samba domain)

See **[migration-runbook.md](migration-runbook.md)** for the full procedure.

1. Pre-flight — `./scripts/migration/preflight-check.sh`
2. Backup on old DC — manual `samba-tool domain backup` (Phase 0)
3. **`dc-restore.yml`** on dc1 (replaces `dc-bootstrap.yml`)
4. `dc-converge.yml` → `ddns-api.yml` on dc1
5. Router/DHCP DNS cutover — manual
6. CentOS deferred hosts — manual `/etc/resolv.conf` only
7. Reprovisioned Ubuntu members — `baseline.yml` → `domain-join.yml`
8. Optional — `domain-leave.yml` before in-place reprovision
9. Decommission old pdc after validation

See [production-runbook.md](production-runbook.md) for command examples and slice runbooks.
