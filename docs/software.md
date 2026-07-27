# Required software by host role

Package lists for Ubuntu 24.04 managed hosts. All `linux` inventory hosts receive
[`linux_baseline`](../roles/linux_baseline/); role playbooks add functional packages on top.

Hosts with `ansible_managed: false` in inventory are out of scope for apt playbooks.
Production hypervisors **kif** and **kvm01** are Ubuntu-managed post-reimage (Slice 19).
Non-Ubuntu VMs (e.g. Pi-hole) use config-only roles until repaved as Ubuntu.

## Shared baseline (`linux` group)

**Playbook:** [`playbooks/baseline.yml`](../playbooks/baseline.yml)  
**Role:** [`roles/linux_baseline`](../roles/linux_baseline/)

Also applied inline by `dc-bootstrap.yml`, `dc-replica-join.yml`, `dc-restore.yml`, and
`cka-converge.yml`.

### Apt packages

| Package | Purpose |
|---|---|
| `python3`, `python3-apt` | Ansible remote execution |
| `openssh-server` | Remote administration |
| `chrony` | Time sync (required before Kerberos) |
| `zsh`, `htop`, `vim` | Interactive admin tools |
| `curl`, `wget`, `git`, `jq`, `tree`, `unzip` | CLI utilities |
| `net-tools`, `iproute2`, `dnsutils` | Network diagnostics (`ip`, `dig`, legacy `ifconfig`) |
| `less`, `rsync`, `tmux` | File transfer and terminal multiplexing |

**pyenv build deps** (`linux_baseline_pyenv_build_packages`, only when
`linux_baseline_pyenv_enabled: true`): toolchain (`make`, `build-essential`, `pkg-config`,
`patch`), OpenSSL/zlib/bzip2/lzma/zstd (`libssl-dev`, `zlib1g-dev`, `libbz2-dev`, `liblzma-dev`,
`libzstd-dev`, `xz-utils`), readline/ncurses/sqlite/ffi (`libreadline-dev`, `libncursesw5-dev`,
`libsqlite3-dev`, `libffi-dev`), plus `tk-dev`, `libxml2-dev`, and `libxmlsec1-dev` for optional
modules. `curl` and `git` come from the baseline list above. See the
[pyenv suggested build environment](https://github.com/pyenv/pyenv/wiki#suggested-build-environment).

### GitHub releases and git checkouts

| Tool | Version pin | Install path | Default |
|---|---|---|---|
| `fzf` | `0.60.3` (see `linux_baseline_github_releases`) | `/usr/local/bin/fzf` | all `linux` hosts |
| `uv`, `uvx` | `0.11.26` (see `linux_baseline_github_releases`) | `/usr/local/bin/` | all `linux` hosts |
| `pyenv` | `2.7.3` (see `linux_baseline_pyenv_version`) | `/usr/local/lib/pyenv` | off (`linux_baseline_pyenv_enabled: false`) |

Ubuntu apt ships an older fzf; the role installs upstream and deploys shell drop-ins in
`/etc/zsh/zshrc.d/` and `/etc/bash.bashrc.d/` for fzf, pyenv (when enabled), and uv. The
`ansible` automation user stays on bash; drop-ins apply to any interactive shell.

**pyenv** is cloned from GitHub with build dependencies when enabled so `pyenv install` works out
of the box. Drop-ins set `PYENV_ROOT` and run `pyenv init` for shims, completion, and version
switching. Enable per host or group — production currently sets
`linux_baseline_pyenv_enabled: true` on `cka-sim.home.2123studios.com` only.

**uv** is installed from upstream GitHub releases; drop-ins enable shell completions via
`uv generate-shell-completion`.

## Role-specific packages

### Domain controllers (`dc`)

**Playbooks:** `dc-bootstrap.yml`, `dc-replica-join.yml`, `dc-restore.yml`, `dc-converge.yml`  
**Role:** [`roles/samba_dc`](../roles/samba_dc/) — variable `samba_packages`

| Package | Purpose |
|---|---|
| `samba-ad-dc` | Samba Active Directory DC |
| `krb5-user` | Kerberos client |
| `bind9`, `bind9utils` | BIND9_DLZ DNS backend |
| `ldap-utils` | LDAP CLI (`ldapsearch`, etc.) |
| `ldb-tools` | LDB CLI (`ldbsearch` against `sam.ldb`) |
| `tcpdump` | Packet capture during join/DNS issues |
| `nmap` | Port reachability checks |

### Hypervisors (`hypervisors`)

**Playbook:** [`playbooks/hypervisor.yml`](../playbooks/hypervisor.yml) (run `baseline.yml` first)  
**Role:** [`roles/hypervisor`](../roles/hypervisor/) — variable `hypervisor_libvirt_packages`

| Package | Purpose |
|---|---|
| `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients` | KVM / libvirt |
| `virtinst` | `virt-install` VM creation |
| `virt-manager` | Desktop GUI for domain management (e.g. Windows guests on kvm01) |
| `bridge-utils` | Bridge networking |
| `python3-libvirt` | libvirt Python bindings |
| `virt-top` | Live domain resource usage |
| `guestfish` | Offline disk image inspection |
| `tcpdump` | Bridge/VLAN traffic debugging |

**Development toolchain** (`hypervisor_dev_tool_packages` — kvm01, kif, and lab `hv01`):

| Package | Purpose |
|---|---|
| `shellcheck` | `./scripts/test-quick.sh` |
| `genisoimage` | Cloud-init seed ISOs (`scripts/vm/vm-lib.sh`) |
| `gettext-base` | `envsubst` for templated VM/autoinstall assets |

**Cursor Remote SSH sandbox** (`hypervisor_cursor_sandbox_enabled: true` on development hypervisors):

| Package / file | Purpose |
|---|---|
| `bubblewrap` | Cursor sandbox fallback backend (`bwrap`) |
| `/etc/apparmor.d/cursor-sandbox-remote` | AppArmor `userns` allowance for `cursorsandbox` on Ubuntu 24.04+ |

One-shot install on an already-provisioned host: `sudo ./scripts/hypervisor/install-cursor-sandbox-apparmor.sh`

Python/Ansible lint and playbooks use the repo `.venv` (`./scripts/bootstrap-dev.sh`), not apt.

**Performance tuning** (`hypervisor_perf_packages` — when `hypervisor_perf_tuning_enabled: true`):

| Package | Purpose |
|---|---|
| `tuned` | `virtual-host` profile for KVM hosts |
| `numactl` | NUMA topology inspection (`numactl -H`) |
| `linux-tools-generic` | `perf` and related kernel tools |

See [`hypervisor-performance.md`](hypervisor-performance.md) for sysctl, THP, VM profiles, and measurement.

Docker CE (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`,
`docker-compose-plugin`) is installed from Docker's official apt repo by the
[`docker_engine`](../roles/docker_engine/) role when `docker_engine_enabled: true`.
The role also removes Ubuntu's conflicting `docker.io`/`containerd` packages
(data under `/var/lib/docker` is preserved).

On **docker workload** hosts (kif, kvm01), the same role optionally installs `lvm2`,
creates/mounts dedicated LVs, and deploys `/etc/docker/daemon.json` (log rotation). When an
NVIDIA GPU is detected (or forced on), it also installs `nvidia-container-toolkit` and
registers the `nvidia` container runtime. **DCs** run Docker for DDNS only — they keep the
default empty `docker_engine_data_volumes` and stay on the root filesystem.

### File servers (`fileservers`)

**Playbook:** [`playbooks/fileserver.yml`](../playbooks/fileserver.yml) (run `baseline.yml` first)  
**Roles:** [`roles/samba_fileserver`](../roles/samba_fileserver/), optional [`roles/mdadm_monitor`](../roles/mdadm_monitor/)

| Package | Purpose |
|---|---|
| `samba`, `winbind` | SMB member server |
| `libnss-winbind`, `libpam-winbind` | NSS/PAM integration |
| `krb5-user`, `smbclient` | Kerberos and SMB client |

When `mdadm_monitor_enabled: true` (e.g. kif):

| Package | Purpose |
|---|---|
| `mdadm` | Software RAID tools and monitor |
| `mailutils` | Send mdadm alert mail to `root` (relays via Postfix) |

Postfix relay client is a prerequisite — applied via `domain-join.yml --tags domain_mail_relay`, not by `fileserver.yml`.

### Domain-joined members (`linux:!dc`)

**Playbook:** [`playbooks/domain-join.yml`](../playbooks/domain-join.yml) (run `baseline.yml` first)  
**Role:** [`roles/domain_join`](../roles/domain_join/) — variable `domain_join_packages`

| Package | Purpose |
|---|---|
| `realmd`, `sssd`, `sssd-ad`, `sssd-tools` | SSSD domain join |
| `adcli`, `krb5-user` | Discovery and Kerberos |
| `libpam-sss`, `libnss-sss` | PAM/NSS |
| `oddjob`, `oddjob-mkhomedir` | Home directory creation |
| `samba-common-bin` | `net ads` utilities |

### DDNS clients (`ddns_clients`)

**Playbook:** [`playbooks/ddns-client.yml`](../playbooks/ddns-client.yml)  
**Role:** [`roles/ddns_client`](../roles/ddns_client/) — variable `ddns_client_packages`

| Package | Purpose |
|---|---|
| `bind9-dnsutils` | `nsupdate` for dynamic DNS |

### Bastion (`bastion`)

**Playbook:** [`playbooks/bastion.yml`](../playbooks/bastion.yml) (run `baseline.yml` + `domain-join.yml` first)  
**Roles:** [`roles/bastion`](../roles/bastion/), [`roles/unattended_upgrades`](../roles/unattended_upgrades/)

| Package | Purpose |
|---|---|
| `ufw` | Host firewall (SSH-only inbound) |
| `fail2ban` | sshd brute-force protection |

Also deploys sshd drop-in and fail2ban jail templates. Security patching is applied by
the shared `unattended_upgrades` role (also available fleet-wide via
[`playbooks/security-updates.yml`](../playbooks/security-updates.yml)). See
[bastion-runbook.md](bastion-runbook.md) and [security-updates-runbook.md](security-updates-runbook.md).

### Fleet security updates (`linux`)

**Playbook:** [`playbooks/security-updates.yml`](../playbooks/security-updates.yml) (run `baseline.yml` first)  
**Role:** [`roles/unattended_upgrades`](../roles/unattended_upgrades/)

| Package | Purpose |
|---|---|
| `unattended-upgrades` | Automatic security patching |

Deploys APT periodic upgrade configuration, inventory-driven reboot windows, and
email to `root` on package changes (`MailReport: on-change`). See
[security-updates-runbook.md](security-updates-runbook.md).

### Reverse proxy (`reverse_proxy`)

**Playbook:** [`playbooks/reverse-proxy.yml`](../playbooks/reverse-proxy.yml) (run `baseline.yml` + `domain-join.yml` + `bastion.yml` + `certbot.yml` first)  
**Role:** [`roles/reverse_proxy`](../roles/reverse_proxy/) — variable `reverse_proxy_packages`

| Package | Purpose |
|---|---|
| `nginx` | Edge reverse proxy / TLS termination |

Typically colocated on the bastion host. Serves data-driven, TLS-protected virtual hosts
that proxy to Docker containers (on `kif`) and other LAN backends, with optional Authelia
forward-auth per location. Optional nginx rate limiting via
`reverse_proxy_rate_limit_zones`. TLS uses a single Let's Encrypt SAN certificate issued by the
[`certbot`](../roles/certbot/) role (DNS-01 via Dreamhost) and reloaded through the certbot
deploy hook (`certbot_deploy_hook_reload_nginx`). See
[reverse-proxy-runbook.md](reverse-proxy-runbook.md).

### CKA practice nodes (`cka`)

**Playbook:** [`playbooks/cka-converge.yml`](../playbooks/cka-converge.yml)  
**Role:** [`roles/cka_node`](../roles/cka_node/) — variable `cka_node_packages`

| Package | Purpose |
|---|---|
| `kubernetes-client` | `kubectl` |
| `kubectx` | `kubectx` / `kubens` context switching |

CKA nodes also receive the full baseline (including fzf, htop, zsh). The role creates a
local user (`$USER` from the control node) with zsh login shell and passwordless sudo.
`kubeadm`, `kubelet`, and `containerd` are **not** automated — install per course materials.

### Backup hosts (`hypervisors` with backup playbook)

**Playbook:** [`playbooks/backup.yml`](../playbooks/backup.yml)  
**Role:** [`roles/backup`](../roles/backup/) — variable `backup_restic_package`

| Package | Purpose |
|---|---|
| `restic` | Backup client |

When `backup_schedule_enabled: true`, deploys `ansible-backup.timer` (docker volume backup,
retention prune, optional offsite `restic copy`). See [backup-runbook.md](backup-runbook.md).

### Docker workload hosts (`docker_engine` with UFW)

When `docker_engine_manage_ufw: true`, restricts published container ports to edge proxy
hosts. See [edge-access-model.md](edge-access-model.md).

| Package | Purpose |
|---|---|
| `ufw` | Host firewall for Docker port isolation |

## Apply order

| Host type | Order |
|---|---|
| DC | `linux_baseline` inline in DC playbooks; `security-updates.yml` for ongoing patching |
| Hypervisor, fileserver, domain member | `baseline.yml` → `security-updates.yml` → role playbook |
| Bastion | `baseline.yml` → `domain-join.yml` → `bastion.yml` (includes `unattended_upgrades`) |
| Reverse proxy | `baseline.yml` → `domain-join.yml` → `bastion.yml` → `certbot.yml` → `reverse-proxy.yml` |
| CKA | `cka-converge.yml` (baseline + `cka_node`) |

## Overriding package lists

All lists are Ansible variables and can be overridden in inventory `group_vars` or
`host_vars`. Example:

```yaml
# inventories/lab/group_vars/all/vars.yml
linux_baseline_packages: "{{ linux_baseline_packages | default([]) }}"
```

Prefer appending via inventory rather than forking role defaults when possible.

Enable pyenv on a specific host:

```yaml
# inventories/production/host_vars/cka-sim.home.2123studios.com/vars.yml
linux_baseline_pyenv_enabled: true
```
