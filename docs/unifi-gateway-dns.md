# UniFi gateway DNS (production)

Production DHCP/DNS runs on a **UniFi Cloud Gateway Fiber** (UCG Fiber, model
`ucgfiber`) under UniFi OS. The gateway runs dnsmasq, managed by
`ubios-udapi-server`. Router configuration is **manual** — not Ansible-managed.

During AD migration, legacy **on-boot scripts** that conditionally forwarded AD
subdomains (`server=/home.2123studios.com/…`) to the old DC are **retired**.
Clients query **Pi-hole** for DNS; Pi-hole forwards AD zones to dc1/dc2. The gateway
keeps **DHCP** and the **dhcp-script** hook for lease-driven DDNS and UniFi client
tracking — it is not a DNS resolver for clients.

See also:

- [pihole-runbook.md](pihole-runbook.md) — Pi-hole forwarding, DHCP cutover, static DNS migration
- [ddns-runbook.md](ddns-runbook.md) — DDNS API, bearer token, hook behaviour, cutover timing
- [dns-architecture.md](dns-architecture.md) — BIND DLZ and DDNS pipeline
- [wan-failover-5g.md](wan-failover-5g.md) — UniFi 5G Backup failover and cellular Traffic Rules

## Architecture change

**Before (legacy on-boot):**

```
DHCP client → UCG dnsmasq → server=/home.2123studios.com/ → pdc
                          → upstream public DNS
```

**After (Pi-hole + AD on DCs):**

```
DHCP client ──(option 6)──► Pi-hole (.18 + .22)
                              ├─ AD zones ──► dc1/dc2 BIND
                              └─ public ──► blocklists + upstream
UCG dnsmasq ──(dhcp-script)──► DDNS API on dc1 :8765 ──► BIND
```

- **Retire:** conditional `server=/` AD forwarding on the UCG (Pi-hole forwards to DCs).
- **UniFi UI:** DHCP DNS server → Pi-hole (`192.168.1.18`, `192.168.1.22`).
- **On-boot inject:** `dhcp-script` only (no UniFi UI for this).
- **Do not** list dc1/dc2 as client DNS — see [pihole-runbook.md](pihole-runbook.md).

**Earlier post-migration (direct to DC, pre-Pi-hole):**

```
DHCP client ──(option 6)──► dc1 BIND (authoritative AD DNS)
UCG dnsmasq ──(dhcp-script)──► DDNS API on dc1 :8765 ──► BIND
```

## Persistence model

UniFi OS regenerates dnsmasq configuration under `/run/` at boot and during
controller provisioning. Files placed directly in `/run/dnsmasq*.conf.d/` are
**not** persistent.

Only `/data/` is reliably preserved across reboots and firmware upgrades.
Paths under `/etc/` and `/usr/local/` may survive in the overlay on some
updates but must not be relied on for production cutover.

### Boot hook directory

The standard on-boot directory is **`/data/on_boot.d/`** (underscore). Some
installations use `/data/onboot.d` (symlink or older naming). Verify on your
gateway:

```bash
ls -la /data/on_boot.d /data/onboot.d 2>/dev/null
```

Scripts must be executable, use a `#!/bin/bash` or `#!/bin/sh` shebang, and
have a **`.sh` extension** (required by udm-boot).

### dnsmasq runtime paths

Paths vary by firmware and UniFi Network version. On Network 9.x the DHCP
configuration directory is typically:

```
/run/dnsmasq.dhcp.conf.d/
```

Other paths seen on UDM/UXG/UCG family devices:

- `/run/dnsmasq.conf.d/`
- `/run/dnsmasq.dns.conf.d/`

Discover on your gateway:

```bash
ls -d /run/dnsmasq*.conf.d/ 2>/dev/null
ps aux | grep '[d]nsmasq'
```

Reload after injecting custom configuration (prefer the **main** DHCP instance):

```bash
kill "$(cat /run/dnsmasq-main.pid)" 2>/dev/null || pkill -f 'dnsmasq-main' || true
```

UCG Fiber runs a separate dnsmasq on WAN (`eth4`); avoid blind `pkill dnsmasq`
if possible. `ubios-udapi-server` restarts the main instance automatically.

### UniFi `dhcp-script` (only one allowed)

`ubios-udapi-server` sets `dhcp-script` in **`shared.conf`**, which calls
`/tmp/dnsmasq-main.dhcp.script` → `/usr/bin/dnsmasq-dhcp-script` (UniFi local
hostname / DNS integration).

dnsmasq rejects a **second** `dhcp-script=` in another file (e.g.
`home-ddns.conf`) with:

```text
illegal repeated keyword at line N of .../shared.conf
```

**Do not** add a parallel `dhcp-script=` line. Instead, `20-home-ddns.sh`
patches `shared.conf` to point at a **wrapper** that chains both hooks:

```
dhcp-script → /data/home-ddns/dhcp-script-wrapper.sh
                ├─ /usr/bin/dnsmasq-dhcp-script  (UniFi)
                └─ export DDNS_ENV_FILE=/data/home-ddns/home-ddns.env
                   └─ /data/home-ddns/dhcp-ddns-hook.sh  (DDNS API)
```

The wrapper **exports `DDNS_ENV_FILE`** before calling the hook. dnsmasq invokes
the hook with a minimal environment — variables inside `home-ddns.env` are only
read after the hook knows which file to source.

### On-boot runner

Scripts in `/data/on_boot.d/` are executed by an on-boot service (commonly
**udm-boot** from [unifi-utilities on-boot-script](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script)).
The runner package must be installed and healthy after firmware updates.

For a more robust self-restoring runner, see
[unifi-on-boot](https://github.com/unredacted/unifi-on-boot).

After a firmware upgrade, verify:

```bash
systemctl status udm-boot --no-pager
ls /data/on_boot.d/
```

## Persistence options

| Mechanism | Survives reboot/update? | This migration |
|---|---|---|
| **UniFi UI — DHCP DNS Server** (Settings → Networks → DHCP) | Yes (controller-managed) | **Use** — DHCP option 6 → Pi-hole (.18 + .22); see [pihole-runbook.md](pihole-runbook.md) |
| **UniFi UI — DNS Records / Local Hostnames** | Yes | Optional static LAN names; not needed for AD zone |
| **UniFi UI — WAN upstream DNS** | Yes | Unchanged; dc1 handles AD queries |
| **`/data/on_boot.d/*.sh`** | Yes (`/data/` preserved) | **Use** — patch `shared.conf` `dhcp-script` → wrapper |
| **Patch `shared.conf` dhcp-script** | Runtime only; re-patch at boot | **Required** — chain UniFi + DDNS hooks |
| **Cron/watchdog re-injection** (e.g. every 5 min) | Yes | Optional if udapi re-provisioning wipes inject |
| **`/etc/dnsmasq.d/` + systemd sync** | Partial | Community alternative; not primary |
| **`config.gateway.json`** (USG on controller) | N/A | **Not applicable** to UCG Fiber |
| **Legacy `server=/domain/dc-ip` forwarding** | via on-boot | **Remove** after cutover |

## Persistent file layout

Recommended paths on the gateway (all under `/data/`):

```
/data/home-ddns/
  dhcp-ddns-hook.sh         # from repo scripts/dhcp-ddns-hook.sh
  dhcp-script-wrapper.sh    # chains UniFi dnsmasq-dhcp-script + hook
  home-ddns.env             # DDNS_UPDATE_URL, DDNS_BEARER_TOKEN, DDNS_DNS_DOMAIN
  shared-dhcp-script.line.bak  # original shared.conf line (rollback)
/data/on_boot.d/
  20-home-ddns.sh           # patches shared.conf at boot
```

Example scripts and install helper live in
[`scripts/router/unifi/`](../scripts/router/unifi/).

## Pre-cutover checklist

Before changing the gateway:

1. `dc-converge.yml` completed on dc1 (BIND DLZ, reverse zone, `dnsupdater`)
2. `ddns-api.yml` deployed — see [ddns-runbook.md](ddns-runbook.md) § Production deployment — DC
3. `curl http://192.168.1.10:8765/ddns/v1/health` returns `ok` (also checked by `cutover-check.sh --phase pre`)
4. FSMO roles on dc1 — `./scripts/migration/cutover-check.sh --phase pre`
5. On-boot runner installed and `/data/on_boot.d/` exists
6. Gateway has `curl` and `python3` or `jq`

## Cutover procedure

### 1. Set DHCP DNS in UniFi UI

1. UniFi Network → **Settings** → **Networks** → primary LAN (e.g. Default).
2. Open **DHCP** (set Advanced Configuration to **Manual** if DNS fields are hidden).
3. Set **DHCP DNS Server** to **`192.168.1.18`** and **`192.168.1.22`** (Pi-hole pair).
   - During Pi-hole rollout, converge both hosts before changing DHCP — [pihole-runbook.md](pihole-runbook.md).
   - Pre-Pi-hole validation may briefly use dc1 only; steady state is Pi-hole only (not dc1/dc2).
4. **Apply** changes.

This survives firmware updates without on-boot scripts.

### 2. Install DDNS hook files

From your workstation (repo checkout), copy files to the gateway. Replace
`gateway` with the UCG management IP or hostname.

```bash
GATEWAY=gateway.home.2123studios.com
REPO=/path/to/home-network-v3

scp "${REPO}/scripts/dhcp-ddns-hook.sh" \
    "${REPO}/scripts/lib/dhcp-ddns-parse.sh" \
    "${REPO}/scripts/router/unifi/dhcp-script-wrapper.sh" \
    "${REPO}/scripts/router/unifi/home-ddns.env.example" \
    root@"${GATEWAY}":/tmp/

ssh root@"${GATEWAY}" 'bash -s' < "${REPO}/scripts/router/unifi/install-home-ddns.sh"
```

Edit secrets on the gateway:

```bash
ssh root@"${GATEWAY}"
install -m 0600 /data/home-ddns/home-ddns.env.example /data/home-ddns/home-ddns.env
vi /data/home-ddns/home-ddns.env   # set DDNS_BEARER_TOKEN from vault
```

Or set values manually:

```sh
DDNS_UPDATE_URL="http://192.168.1.10:8765/ddns/v1/lease"
DDNS_BEARER_TOKEN="<vault_ddns_shared_secret>"
DDNS_DNS_DOMAIN="home.2123studios.com"
DDNS_UPDATE_URL_FALLBACK="http://192.168.1.11:8765/ddns/v1/lease"
```

The wrapper exports `DDNS_ENV_FILE=/data/home-ddns/home-ddns.env` automatically.

### 3. Install on-boot inject script

```bash
scp "${REPO}/scripts/router/unifi/20-home-ddns.sh" \
    root@"${GATEWAY}":/data/on_boot.d/
ssh root@"${GATEWAY}" 'chmod 755 /data/on_boot.d/20-home-ddns.sh'
```

If your boot directory is `/data/onboot.d`, adjust the destination path.

### 4. Apply and verify

Run the inject script once (or reboot):

```bash
ssh root@"${GATEWAY}" '/data/on_boot.d/20-home-ddns.sh'
```

Verify runtime configuration (exactly **one** active `dhcp-script=`):

```bash
grep dhcp-script /run/dnsmasq.dhcp.conf.d/shared.conf
# Expected: dhcp-script=/data/home-ddns/dhcp-script-wrapper.sh

grep -hE '^[^#]*dhcp-script=' /run/dnsmasq.dhcp.conf.d/*.conf
# Must show only one line

test ! -f /run/dnsmasq.dhcp.conf.d/home-ddns.conf && echo "ok: no duplicate inject file"
```

From a DHCP client after lease renew:

```bash
resolvectl status                    # Linux — DNS should list 192.168.1.10
dig @192.168.1.10 dc1.home.2123studios.com A +short
# After renew, check a client hostname:
dig @192.168.1.10 <hostname>.home.2123studios.com A +short
```

From the Ansible control node:

```bash
./scripts/migration/cutover-check.sh --phase post --remote dc1.home.2123studios.com
```

### 5. Remove legacy on-boot scripts

After validation, **disable or remove** old scripts that:

- Added `server=/home.2123studios.com/…` or `_msdcs` forwarding (e.g.
  `07-create-local-dns-conf.sh` → `local_custom_dns.conf`)
- Patched dnsmasq for AD resolver hacks targeting pdc
- Ran obsolete DDNS logic superseded by `dhcp-ddns-hook.sh`

```bash
mv /data/on_boot.d/07-create-local-dns-conf.sh \
   /data/on_boot.d/07-create-local-dns-conf.sh.disabled
rm -f /run/dnsmasq.dhcp.conf.d/local_custom_dns.conf
kill "$(cat /run/dnsmasq-main.pid)"
```

Leave unrelated on-boot scripts untouched. Rename retired scripts to `.disabled`
before deleting, so rollback is easy.

## Troubleshooting

### `illegal repeated keyword` / dnsmasq won't start

Cause: two `dhcp-script=` lines (typically `shared.conf` plus `home-ddns.conf`).

Recovery:

```bash
rm -f /run/dnsmasq.dhcp.conf.d/home-ddns.conf
# Deploy updated 20-home-ddns.sh from repo, then:
/data/on_boot.d/20-home-ddns.sh
grep -hE '^[^#]*dhcp-script=' /run/dnsmasq.dhcp.conf.d/*.conf   # must be one line
```

### Migrating from `07-create-local-dns-conf.sh`

Legacy scripts often wrote `local_custom_dns.conf` with `server=/…/dc1` forwarding
and `domain=` / `dhcp-fqdn`. After DHCP DNS → dc1 in the UniFi UI, the
`server=/` and `srv-host` lines are redundant. Retire the old on-boot script and
remove `local_custom_dns.conf`; use the wrapper-based `20-home-ddns.sh` instead.

If short DHCP hostnames break DDNS after cutover, add `domain=` and `dhcp-fqdn`
to a **non-duplicate** file only when `shared.conf` does not already set them
(check with `grep -E '^domain=' /run/dnsmasq.dhcp.conf.d/*.conf` first).

## Rollback

If cutover must be reversed while pdc is still running:

1. UniFi UI — set **DHCP DNS Server** back to **`192.168.1.2`** (pdc).
2. Disable on-boot inject:
   ```bash
   mv /data/on_boot.d/20-home-ddns.sh /data/on_boot.d/20-home-ddns.sh.disabled
   # Restore original UniFi dhcp-script line if backed up:
   sed -i -E "s|^[[:space:]]*dhcp-script=.*|$(cat /data/home-ddns/shared-dhcp-script.line.bak)|" \
     /run/dnsmasq.dhcp.conf.d/shared.conf
   kill "$(cat /run/dnsmasq-main.pid)"
   ```
3. Re-enable legacy forwarding scripts if needed (restore from `.disabled` backups).
4. Restore member `/etc/resolv.conf` to previous DNS servers.
5. Transfer FSMO back to the previous DC if moved.

See [dc-runbook.md](dc-runbook.md) for replica join rollback context. Legacy **pdc** is retired.

## Firmware updates

After a UniFi OS or Network application upgrade:

1. Confirm `systemctl is-enabled udm-boot` (or your on-boot runner).
2. Confirm `/data/home-ddns/` and `/data/on_boot.d/20-home-ddns.sh` still exist.
3. Verify wrapper in `shared.conf`: `grep dhcp-script /run/dnsmasq.dhcp.conf.d/shared.conf`
4. Re-run `/data/on_boot.d/20-home-ddns.sh` if udapi regenerated `shared.conf`.
5. Confirm UniFi UI still shows dc1 as DHCP DNS (controller setting is independent).

If udapi re-provisions frequently and wipes the inject between boots, add a
cron job under `/etc/cron.d/` that re-runs `20-home-ddns.sh` every 5 minutes.
This is optional; most sites only need the on-boot script.

## Remote sites

The FerryCrossing UCG (`192.168.1.1`) is documented above. Remote-site gateways
(Woodbine `192.168.33.1`, Swanhollow `192.168.65.1`) use **conditional forwarders**
to FerryCrossing DCs until each site has a local DC — see
[remote-site-dns.md](remote-site-dns.md).

## Multi-VLAN (FerryCrossing)

FerryCrossing has multiple VLANs. BIND ACLs on every DC (`dc_trusted_networks` in
`group_vars/dc/vars.yml`) control which subnets may query dc1/dc2.

| VLAN | Subnet | DHCP DNS | Notes |
|---|---|---|---|
| 1 (default) | `192.168.1.0/24` | Pi-hole `.18` + `.22` | Primary LAN; DDNS hook on UCG |
| 2 (IoT) | `192.168.3.0/24` | Pi-hole `.18` + `.22` | Inter-VLAN routing; Pi-hole → dc1/dc2 for AD |
| 3 (restricted) | `192.168.5.0/24` | Router/public only | **Isolated** — not in `dc_trusted_networks` |
| 4 (docker edge) | `192.168.7.0/24` | **None** (L2 trunk only) | Hypervisor br4 + proxy01 docker NIC; not in AD |
| 9 (kubernetes) | `192.168.9.0/24` | Pi-hole `.18` + `.22` or DC `.10`/`.11` | Routed k8s fabric — CP VM + workers; see [adr/003-home-kubernetes.md](adr/003-home-kubernetes.md) |

### VLAN 2 (IoT)

1. UniFi Network → **Settings** → **Networks** → IoT VLAN → **DHCP**.
2. Set **DHCP DNS Server** to **Pi-hole** (`192.168.1.18`, `192.168.1.22`).
3. Confirm firewall rules allow IoT → Pi-hole **UDP/TCP 53** and Pi-hole → DC **UDP/TCP 53**.

MS-SNTP from DCs remains VLAN 1 only (`dc_ntp_allow_cidr`); IoT uses router or public NTP.

### VLAN 4 (Docker edge)

L2-only VLAN for reverse-proxy backends — **no gateway, DHCP, or DNS** on UniFi:

1. UniFi Network → **Settings** → **Networks** → create VLAN **4**.
2. Set subnet `192.168.7.0/24` but **disable** DHCP and **do not** assign a gateway.
3. Tag VLAN 4 on hypervisor switch ports (kif, kvm01 uplinks).
4. Static addresses are configured in Ansible/netplan and proxy01 cloud-init — see
   [hypervisor-runbook.md](hypervisor-runbook.md#vlan-4--docker-edge-network-br4).

Do not add `192.168.7.0/24` to DC ACLs, AD site subnets, or Pi-hole zones unless a
future design explicitly requires it.

### VLAN 9 (Kubernetes)

Routed VLAN for the home kubeadm cluster — **gateway enabled**, static addressing,
DNS via Pi-hole or DCs ([adr/003-home-kubernetes.md](adr/003-home-kubernetes.md)):

1. UniFi Network → **Settings** → **Networks** → create VLAN **9**.
2. Subnet `192.168.9.0/24`, gateway `192.168.9.1` (UCG).
3. **DHCP:** optional small pool for lab; **reserve** CP (`.10`), workers (`.128`/`.129`),
   and MetalLB pool (`.200`–`.210`) as static — do not hand those to DHCP clients.
4. **DHCP DNS Server:** Pi-hole (`192.168.1.18`, `192.168.1.22`) or dc1/dc2 (`.10`/`.11`).
5. Tag VLAN 9 on hypervisor uplinks (kif, kvm01) for br9/libvirt **vlan9**.
6. Firewall (minimum):
   - VLAN 9 → VLAN 1: DNS (53), NFS (2049), HTTPS (443 apt mirrors), ICMP as needed.
   - VLAN 1 → VLAN 9: SSH (22), Kubernetes API (6443 from admin/bastion), proxy01 → MetalLB VIP (80/443).
   - Do not expose NodePort ranges to the Internet — north-south stays on proxy01.

Add `192.168.9.0/24` to `dc_trusted_networks` if nodes query dc1/dc2 directly.
Static BIND A records (via DDNS API or manual): `k8s-cp01`, `k8s-node-1`, `k8s-node-2`,
and the ingress MetalLB VIP hostname.

K8s nodes do **not** join AD. Break-glass local SSH only — see [kubernetes-runbook.md](kubernetes-runbook.md).

### VLAN 3 (restricted)

No changes — clients do not query AD DNS. Do not add `192.168.5.0/24` to DC ACLs or
AD site subnets.

### Cellular failover (5G Backup)

Per-network cellular allow/deny and Traffic Rules live in
[wan-failover-5g.md](wan-failover-5g.md). Summary: VLAN 1 may fail over to the
U5G; VLANs 2, 3, and 9 must not.

## Token rotation

Update `vault_ddns_shared_secret`, re-run `ddns-api.yml` on dc1, then edit
`/data/home-ddns/home-ddns.env` on the gateway. No dnsmasq reload required for
env-only changes.
