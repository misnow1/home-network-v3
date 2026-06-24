# home-network-v3

Ansible and supporting automation to provision machines in a home network and lab.
Designed test-first: quick CI checks on GitHub, full libvirt integration tests on kvm01.

## Prerequisites (control node / kvm01)

- Python 3.11+
- `ansible-core`, `ansible-lint`, `yamllint` (`pip install -r requirements.txt`)
- `virsh`, `virt-install`, `qemu-img` (integration tests)
- `cloud-localds` or `genisoimage` (cloud-init seed ISO)
- `envsubst` (gettext)
- **Local lab storage** on kvm01 (not NFS home) — see [docs/lab-storage.md](docs/lab-storage.md)

```bash
sudo ./scripts/vm/dirs-ensure.sh -i lab   # once per host (lab profile)
```

## Quick start

```bash
./scripts/bootstrap-dev.sh        # pyenv-aware venv + pip + galaxy
# or manually:
# eval "$(pyenv init -)" && python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt

# Lab vault password (local dev — change after clone)
printf '%s' 'change-me-lab-vault' > .vault_pass_lab
chmod 600 .vault_pass_lab

./scripts/test-quick.sh          # tiers 1+2
./scripts/test-integration.sh    # tier 3 on kvm01 (default slice from LAB_HOST)
INTEGRATION_SLICE=dc_replica ./scripts/test-integration.sh   # two-DC replica test
./scripts/test-all.sh            # both
```

Set `SKIP_VM_TESTS=1` to run integration network/key checks without creating a VM.

## Layout

See [docs/ROADMAP.md](docs/ROADMAP.md) for the slice plan and deferred work.

| Path | Purpose |
|---|---|
| `inventories/lab/` | Default inventory for development and integration tests |
| `inventories/cka/` | CKA practice VMs on vlan3 (see [docs/cka-runbook.md](docs/cka-runbook.md)) |
| `inventories/production/` | Gitignored production hosts (`hosts.yml.example` is the template) |
| `scripts/test-*.sh` | Test entrypoints |
| `scripts/vm/` | Generic VM lifecycle (lab and production profiles) |
| `scripts/lab/` | Lab libvirt network, DDNS hook, thin wrappers (`-i lab`) |
| `docs/cka-runbook.md` | Ad-hoc CKA practice VMs on host bridge (vlan3) |
| `scripts/prod-run.sh` | Production playbook wrapper |
| `tests/structural/` | Tier 2 assert playbooks |

## GitHub Actions

Configure repository secret `VAULT_PASS_LAB` to match the lab vault password documented in
[docs/vault-schema.md](docs/vault-schema.md).

- **Test Quick** — linters and structural tests on every push/PR
- **Test Integration DC Replica** — nightly + manual `workflow_dispatch` on the kvm01
  self-hosted runner (`INTEGRATION_SLICE=dc_replica`)

## Production runs

Never run destructive playbooks against production directly. Use:

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit example.host
```

See [docs/run-order.md](docs/run-order.md) and [docs/production-runbook.md](docs/production-runbook.md).
