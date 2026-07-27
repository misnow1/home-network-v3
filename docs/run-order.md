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

**Canonical apply order:** [production-runbook.md](production-runbook.md)

Quick start:

1. Copy inventory templates — see [inventories/README.md](../inventories/README.md)
2. Create `inventories/production/group_vars/all/vault.yml` with real secrets
3. Use the production wrapper — never call `ansible-playbook -i inventories/production` directly:

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

## Apply order index

### Greenfield

See [production-runbook.md](production-runbook.md) § Apply order — steps 1–10 cover
baseline → security updates → DC → hypervisors → fileservers → domain join → bastion →
DDNS → Pi-hole → certbot → mail relay.

### Additional DC replicas

Join new DCs to the existing domain with `dc-replica-join.yml` — see
[dc-runbook.md](dc-runbook.md) and [ad-sites.md](ad-sites.md). Router/DHCP DNS
cutover: [unifi-gateway-dns.md](unifi-gateway-dns.md).

See [ROADMAP.md](ROADMAP.md) for active slices and deferred work.
