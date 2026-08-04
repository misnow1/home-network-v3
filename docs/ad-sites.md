# Active Directory sites — home.2123studios.com

Samba AD uses **sites** and **subnets** so clients and DCs know which physical
location they belong to. Each LAN must have a **unique subnet** mapped to one site.

This domain spans three locations:

| Site | Location | Subnet | Primary DC (planned) |
|---|---|---|---|
| **FerryCrossing** | Main house | `192.168.1.0/24` (VLAN 1) | `dc1` / `dc2` |
| **FerryCrossing** | Main house — IoT | `192.168.3.0/24` (VLAN 2) | Same site; queries dc1/dc2 |
| **Woodbine** | Second house | `192.168.33.0/24` | Future replica DC |
| **Swanhollow** | Parents' house | `192.168.65.0/24` | Future replica DC |

**Not in AD:** `192.168.5.0/24` (VLAN 3, restricted) and `192.168.9.0/24` (VLAN 9,
Kubernetes) — isolated from domain join by design. K8s nodes may query AD DNS if
`192.168.9.0/24` is in `dc_trusted_networks` ([adr/003-home-kubernetes.md](adr/003-home-kubernetes.md)).

`dc1` and `dc2` join and live in **FerryCrossing**. Remote sites can exist in AD before a
local DC is installed — create the site and subnet now; join a DC later with
`--site=Woodbine` or `--site=Swanhollow`.

**Samba limitation:** `samba-tool sites` on a writable DC supports `create`, `list`, `remove`,
`subnet`, and `view` only — there is **no** `site-link` subcommand. Sites created
with `samba-tool sites create` are also **not** added to `DEFAULTIPSITELINK`
automatically. That is fine for dc1 join; manage site links later via RSAT when
remote DCs need inter-site replication ([Samba wiki — AD Sites](https://wiki.samba.org/index.php/Active_Directory_Sites)).

See also:

- [dc-runbook.md](dc-runbook.md) — replica join playbook
- [dns-architecture.md](dns-architecture.md) — DNS and reverse zones per site
- [remote-site-dns.md](remote-site-dns.md) — conditional forwarders until local DCs exist

## Inventory variables

In `inventories/production/group_vars/dc/vars.yml`:

```yaml
samba_dc_join_site: FerryCrossing
```

For a future DC at Woodbine or Swanhollow, set `samba_dc_join_site` on that host
before running `dc-replica-join.yml`.

## One-time setup on the domain (run on dc1)

All commands below run on a **writable** domain controller (**dc1** or **dc2**).
During the historical pdc migration, these ran on pdc first.

### 1. Inspect current state

```bash
sudo samba-tool sites list
sudo samba-tool sites subnet list

sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "CN=Configuration,DC=home,DC=2123studios,DC=com" \
  -s sub "(|(cn=Sites)(cn=FerryCrossing)(cn=Woodbine)(cn=Swanhollow)(cn=Servers))" dn
```

### 2. Create sites

Skip any site that `samba-tool sites list` already shows.

```bash
sudo samba-tool sites create FerryCrossing
sudo samba-tool sites create Woodbine
sudo samba-tool sites create Swanhollow
```

### 3. Map subnets to sites

If `192.168.1.0/24` is still on `Default-First-Site-Name`, remove it first:

```bash
sudo samba-tool sites subnet list
# Only if 192.168.1.0/24 points at Default-First-Site-Name:
sudo samba-tool sites subnet delete 192.168.1.0/24
```

Assign subnets (idempotent — skip or ignore errors if already present):

```bash
sudo samba-tool sites subnet add 192.168.1.0/24 FerryCrossing
sudo samba-tool sites subnet add 192.168.3.0/24 FerryCrossing
sudo samba-tool sites subnet add 192.168.33.0/24 Woodbine
sudo samba-tool sites subnet add 192.168.65.0/24 Swanhollow
```

### 4. Ensure Servers containers and run KCC

Required for `samba-tool domain join … DC` (creates
`CN=<host>,CN=Servers,CN=<site>,…`):

```bash
sudo samba-tool drs kcc
sudo samba-tool dbcheck --cross-ncs --fix
```

Verify FerryCrossing (dc1 join target):

```bash
sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "CN=Servers,CN=FerryCrossing,CN=Sites,CN=Configuration,DC=home,DC=2123studios,DC=com" \
  -s base dn
```

### 5. Inter-site links (defer — not needed for dc1 join)

Site links define **inter-site replication** paths once you have DCs in more than one
site. They are **not** required for `domain join … DC` when `CN=Servers,CN=<site>,…`
already exists (your FerryCrossing target DN is sufficient — proceed with dc1 join).

`samba-tool` does **not** implement site-link management on any current Samba release.
`samba-tool sites create` also does not add the new site to `DEFAULTIPSITELINK`.

**When you add a DC at Woodbine or Swanhollow**, use one of:

1. **RSAT (recommended)** — on a Windows admin machine, install *Remote Server
   Administration Tools* → *Active Directory Sites and Services*. Connect to
   `home.2123studios.com`. Under *Inter-Site Transports* → *IP*, either:
   - Add Woodbine and Swanhollow to the existing **DEFAULTIPSITELINK**, or
   - Create dedicated links (e.g. FerryCrossing–Woodbine) with cost/schedule as needed.

2. **Inspect only (on pdc/dc1)** — see which sites are already in the default link:

```bash
sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "CN=DEFAULTIPSITELINK,CN=IP,CN=Inter-Site Transports,CN=Sites,CN=Configuration,DC=home,DC=2123studios,DC=com" \
  siteList
```

Then run `sudo samba-tool drs kcc` after RSAT changes.

Do **not** hand-edit `siteList` with `ldbmodify` unless you have no RSAT option —
Samba documents direct AD edits as risky for replication topology.

### 6. Retire Default-First-Site-Name (optional, after migration)

Only when no subnets and no DC server objects reference it:

```bash
sudo samba-tool sites subnet list
sudo ldbsearch -H /var/lib/samba/private/sam.ldb \
  -b "CN=Default-First-Site-Name,CN=Sites,CN=Configuration,DC=home,DC=2123studios,DC=com" \
  -s sub "(objectClass=server)" dn
```

If empty, the site can remain unused or be removed manually — do not delete while
legacy objects still reference it.

## Joining a DC at a specific site

**dc1 (FerryCrossing)** — Ansible sets `samba_dc_join_site`; manual equivalent
(historical migration joined against pdc):

```bash
samba-tool domain join home.2123studios.com DC \
  --realm=HOME.2123STUDIOS.COM \
  --server=dc1.home.2123studios.com \
  --dns-backend=BIND9_DLZ \
  --site=FerryCrossing \
  -UAdministrator
```

**Future DC at Woodbine** (example `dc-woodbine`):

```yaml
# group_vars/dc/vars.yml on that host
samba_dc_join_site: Woodbine
samba_dc_join_server: dc1.home.2123studios.com
samba_dc_join_nameservers:
  - 192.168.33.1   # local router/DNS at Woodbine, must resolve the domain
```

**Future DC at Swanhollow** — same pattern with `samba_dc_join_site: Swanhollow` and
`192.168.65.0/24`.

## DNS reverse zones (when each site has a DC)

FerryCrossing reverse zone (already in inventory):

- `192.168.1.0/24` → `1.168.192.in-addr.arpa`

When you add DCs at other sites, extend `samba_dc_reverse_zones` on that DC:

```yaml
# Woodbine example
samba_dc_reverse_zones:
  - 33.168.192.in-addr.arpa

# Swanhollow example
samba_dc_reverse_zones:
  - 65.168.192.in-addr.arpa
```

## Verification

```bash
sudo samba-tool sites list
sudo samba-tool sites subnet list
sudo samba-tool domain info 127.0.0.1
sudo samba-tool drs showrepl
```

From a client on each subnet, `nltest /dsgetsite` (Windows) or Samba's site-aware
lookup should report the matching site once subnets are correct.
