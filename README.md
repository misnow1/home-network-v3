# home-network-v3

Ansible and supporting automation to provision machines in a home network and lab.
Designed test-first: quick CI checks on GitHub, full libvirt integration tests on kvm01.

## Prerequisites (development hypervisors)

Development and integration tests run on production **hypervisors** — **kvm01** and
**kif** (`inventories/production` `hypervisors` group). Clone the repo on either host,
bootstrap the Python venv locally, and run the same scripts as CI.

**Repo checkout:** kif often uses NFS home (`kif:/home/...`); kvm01 may use NFS or local
disk. VM disks and seed ISOs must live on **local libvirt storage** on the host running
libvirt — see [docs/lab-storage.md](docs/lab-storage.md).

**Python / Ansible** (repo `.venv` — not system-wide):

- Python 3.11+
- `./scripts/bootstrap-dev.sh` installs `ansible-core`, `ansible-lint`, `yamllint`, and Galaxy collections from `requirements.txt` / `requirements.yml`

**System packages** (installed by `hypervisor.yml` on hypervisors — see [docs/software.md](docs/software.md)):

- `shellcheck` — `./scripts/test-quick.sh`
- `virsh`, `virt-install`, `qemu-img` — libvirt VM lifecycle
- `genisoimage` — cloud-init seed ISOs (`scripts/vm/vm-lib.sh`)
- `gettext-base` (`envsubst`) — templated cloud-init and autoinstall assets

```bash
sudo ./scripts/vm/dirs-ensure.sh -i lab   # once per hypervisor (lab profile)
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
| `inventories/production/` | Gitignored production hosts — see [inventories/README.md](inventories/README.md) |
| `scripts/test-*.sh` | Test entrypoints |
| `scripts/vm/` | Generic VM lifecycle (lab and production profiles) |
| `scripts/lab/` | Lab libvirt network, DDNS hook, thin wrappers (`-i lab`) |
| `docs/cka-runbook.md` | Ad-hoc CKA practice VMs on host bridge (vlan3) |
| `scripts/prod-run.sh` | Production playbook wrapper |
| `tests/structural/` | Tier 2 assert playbooks |

## GitHub Actions

Configure `VAULT_PASS_LAB` as both an Actions secret and a Dependabot secret (same value as
the lab vault password in [docs/vault-schema.md](docs/vault-schema.md)). Dependabot PRs do
not receive Actions secrets.

- **Test Quick** — linters and structural tests on every push/PR
- **Test Integration DC Replica** — nightly + manual `workflow_dispatch` on the kvm01
  self-hosted runner (`INTEGRATION_SLICE=dc_replica`)
- **Dependabot Auto-Merge** — squash-merges patch and minor Dependabot PRs after
  required checks pass (majors stay for review). Enable **Allow auto-merge** under
  Settings → General → Pull Requests, and require the **`quick`** check on `main`.

## Production runs

Never run destructive playbooks against production directly. Use:

```bash
./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit example.host
```

See [docs/run-order.md](docs/run-order.md) and [docs/production-runbook.md](docs/production-runbook.md).
