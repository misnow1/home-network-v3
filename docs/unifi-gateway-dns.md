# UniFi gateway DNS (production)

Production DHCP/DNS runs on a **UniFi Cloud Gateway Fiber** (UCG Fiber, model
`ucgfiber`) under UniFi OS. The gateway runs dnsmasq, managed by
`ubios-udapi-server`. Router configuration is **manual** — not Ansible-managed.

During AD migration, legacy **on-boot scripts** that conditionally forwarded AD
subdomains (`server=/home.2123studios.com/…`) to the old DC are **retired**.
Clients query **dc1** directly for DNS; the gateway keeps only the **dhcp-script**
hook for lease-driven DDNS.

See also:

- [ddns-runbook.md](ddns-runbook.md) — DDNS API, bearer token, hook behaviour, migration timing
- [migration-runbook.md](migration-runbook.md) — when router cutover fits in AD migration
- [dns-architecture.md](dns-architecture.md) — BIND DLZ and DDNS pipeline

## Architecture change

**Before (legacy on-boot):**

```
DHCP client → UCG dnsmasq → server=/home.2123studios.com/ → pdc
                          → upstream public DNS
```

**After (post-migration):**

```
DHCP client ──(option 6)──► dc1 BIND (authoritative AD DNS)
UCG dnsmasq ──(dhcp-script)──► DDNS API on dc1 :8765 ──► BIND
```

- **Retire:** conditional `server=/` forwarding to pdc.
- **UniFi UI:** DHCP DNS server → dc1 (`192.168.1.10`).
- **On-boot inject:** `dhcp-script` only (no UniFi UI for this).

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
| **UniFi UI — DHCP DNS Server** (Settings → Networks → DHCP) | Yes (controller-managed) | **Use** — DHCP option 6 → dc1 |
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
3. Set **DHCP DNS Server** to **`192.168.1.10`** (dc1 only).
   - During validation you may briefly list dc1 and pdc; use dc1 only for steady state.
4. **Apply** changes.

This survives firmware updates without on-boot scripts.

### 2. Install DDNS hook files

From your workstation (repo checkout), copy files to the gateway. Replace
`gateway` with the UCG management IP or hostname.

```bash
GATEWAY=gateway.home.2123studios.com
REPO=/path/to/home-network-v3

scp "${REPO}/scripts/dhcp-ddns-hook.sh" \
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
5. Transfer FSMO back to pdc if moved.

See [migration-runbook.md](migration-runbook.md) § Rollback for full context.

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

The FerryCrossing UCG (`192.168.1.1`) is documented here. Remote-site routers
(e.g. Woodbine `192.168.33.1`) may need site-specific DNS once a local DC
exists — see [ad-sites.md](ad-sites.md). That work is out of scope for this
runbook.

## Token rotation

Update `vault_ddns_shared_secret`, re-run `ddns-api.yml` on dc1, then edit
`/data/home-ddns/home-ddns.env` on the gateway. No dnsmasq reload required for
env-only changes.
