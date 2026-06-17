# Required software by host role

Package lists for Ubuntu 24.04 managed hosts. All `linux` inventory hosts receive
[`linux_baseline`](../roles/linux_baseline/); role playbooks add functional packages on top.

CentOS deferred hosts (`kvm01`, `kif`) are out of scope — manual management only.

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

### GitHub releases

| Binary | Version pin | Install path |
|---|---|---|
| `fzf` | `0.60.3` (see `linux_baseline_github_releases`) | `/usr/local/bin/fzf` |

Ubuntu apt ships an older fzf; the role installs upstream and deploys shell drop-ins in
`/etc/zsh/zshrc.d/` and `/etc/bash.bashrc.d/`. The `ansible` automation user stays on
bash; drop-ins apply to any interactive shell.

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
| `bridge-utils` | Bridge networking |
| `python3-libvirt` | libvirt Python bindings |
| `virt-top` | Live domain resource usage |
| `guestfish` | Offline disk image inspection |
| `tcpdump` | Bridge/VLAN traffic debugging |

Docker (`docker.io`, `docker-compose-v2`) is installed separately by the
[`docker_engine`](../roles/docker_engine/) role when `docker_engine_enabled: true`.

### File servers (`fileservers`)

**Playbook:** [`playbooks/fileserver.yml`](../playbooks/fileserver.yml) (run `baseline.yml` first)  
**Role:** [`roles/samba_fileserver`](../roles/samba_fileserver/) — variable `fileserver_packages`

| Package | Purpose |
|---|---|
| `samba`, `winbind` | SMB member server |
| `libnss-winbind`, `libpam-winbind` | NSS/PAM integration |
| `krb5-user`, `smbclient` | Kerberos and SMB client |

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

## Apply order

| Host type | Order |
|---|---|
| DC | `linux_baseline` inline in DC playbooks |
| Hypervisor, fileserver, domain member | `baseline.yml` → role playbook |
| CKA | `cka-converge.yml` (baseline + `cka_node`) |

## Overriding package lists

All lists are Ansible variables and can be overridden in inventory `group_vars` or
`host_vars`. Example:

```yaml
# inventories/lab/group_vars/all/vars.yml
linux_baseline_packages: "{{ linux_baseline_packages | default([]) }}"
```

Prefer appending via inventory rather than forking role defaults when possible.
