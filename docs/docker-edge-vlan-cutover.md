# Docker edge VLAN cutover

Production migration: split reverse proxy from shell-clt01 onto **proxy01** with
**VLAN 4** (Docker edge network). See [adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md).

## Pre-flight

- [ ] Ansible changes merged and `./scripts/test-quick.sh` passes
- [ ] `inventories/production/group_vars/reverse_proxy/vars.yml` copied from example (`certbot_enabled: true`, backends on `192.168.7.x`)
- [ ] `inventories/production/host_vars/proxy01.../vars.yml` created from example
- [ ] Public DNS: proxied FQDNs that need ACME validation should CNAME through `bastion.2123studios.com`, not directly to `2123studios.noip.me` (required for `kif.2123studios.com` — see [certbot-runbook.md](certbot-runbook.md))
- [ ] Live `hosts.yml` lists proxy01 in `reverse_proxy`, `certbot`, and `linux` groups
- [ ] shell-clt01 removed from `reverse_proxy` and `certbot` groups

## Ordered steps

### 1. UniFi — VLAN 4 trunk

1. Create VLAN 4 (`192.168.7.0/24`) — **no gateway, no DHCP, no DNS**.
2. Tag VLAN 4 on kif and kvm01 hypervisor switch ports.
3. Do **not** change existing VLAN 1/2/3 settings.

See [unifi-gateway-dns.md](unifi-gateway-dns.md#vlan-4-docker-edge).

### 2. Hypervisors — br4 + libvirt vlan4

```bash
PROD='./scripts/prod-run.sh --confirm-production --'
${PROD} playbooks/hypervisor.yml --limit kif.home.2123studios.com --tags hypervisor_netplan,hypervisor_networks
${PROD} playbooks/hypervisor.yml --limit kvm01.home.2123studios.com --tags hypervisor_netplan,hypervisor_networks
```

Verify:

```bash
ip -4 addr show br4          # 192.168.7.152 on kif, 192.168.7.21 on kvm01
virsh net-info vlan4         # active on both hosts
ping -c1 192.168.7.21        # from kif
```

### 3. proxy01 — provision and converge

```bash
./scripts/vm/vm-create.sh -i production --prepare proxy01.home.2123studios.com
# UniFi DHCP reservation → 192.168.1.23
./scripts/vm/vm-start.sh -i production proxy01.home.2123studios.com
./scripts/vm/wait-ssh.sh -i production proxy01.home.2123studios.com

PROXY=proxy01.home.2123studios.com
${PROD} playbooks/baseline.yml --limit "${PROXY}"
# certbot_staging: true first, then false for production cert
${PROD} playbooks/certbot.yml --limit "${PROXY}" -e allow_production=true
${PROD} playbooks/reverse-proxy.yml --limit "${PROXY}" -e allow_production=true
```

Verify dual NICs on proxy01:

```bash
ip -4 addr show               # 192.168.1.23 + 192.168.7.23
ping -c1 192.168.7.152        # from proxy01 to kif br4
curl -s http://192.168.7.152:9191/api/health   # after kif compose updated
```

### 4. kif — Compose port bindings

Update each stack under `/srv/docker/` to bind proxy ports on **192.168.7.152**.
Transmission splits RPC (VLAN 4) from peer port (VLAN 1):

```yaml
# transmission — example
ports:
  - "192.168.7.152:9091:9091"
  - "192.168.1.152:51413:51413"
```

See [authelia-runbook.md](authelia-runbook.md#docker-compose-port-bindings-vlan-4).

Restart stacks: `cd /srv/docker/<stack> && sudo docker compose up -d`

Set Transmission `port_forwarding_enabled: false` if using explicit UniFi forward.

### 5. kif UFW + forwarded-header trust boundary

```bash
${PROD} playbooks/host-firewall.yml --limit kif.home.2123studios.com
```

Authelia does not need a `trusted_proxies` entry in `configuration.yml`. With no
proxy/load balancer in front of proxy01, keep
`reverse_proxy_trusted_proxies: []`. nginx replaces any client-supplied
`X-Forwarded-For` value with `$remote_addr` before forwarding to Authelia.

After running `playbooks/reverse-proxy.yml`, verify that Authelia access logs show
the actual public client address rather than proxy01's `192.168.7.23`.

### 6. Validate before cutover

From a LAN workstation (not proxy01):

```bash
# Should fail — proxy ports not on LAN
curl -m2 http://192.168.1.152:9191 || echo OK-denied
curl -m2 http://192.168.1.152:9091 || echo OK-denied
```

From proxy01:

```bash
curl -s http://192.168.7.152:9191/api/health
curl -Ik https://127.0.0.1/ -H 'Host: auth.2123studios.com' --resolve auth.2123studios.com:443:127.0.0.1
```

Test Transmission peer port still accepts probes on VLAN 1:

```bash
nc -zv 192.168.1.152 51413
```

### 7. UniFi port-forward cutover

| Service | Forward | Target |
|---|---|---|
| SSH | 22 | shell-clt01 `192.168.1.17` (unchanged) |
| HTTP | 80 | proxy01 `192.168.1.23` |
| HTTPS | 443 | proxy01 `192.168.1.23` |
| Transmission peer | (existing port) | kif `192.168.1.152:51413` (unchanged IP) |

Verify public HTTPS for each vhost in `reverse_proxy_sites`.

### 8. Decommission nginx on shell-clt01

```bash
ssh shell-clt01.home.2123studios.com
sudo systemctl disable --now nginx
sudo apt purge nginx nginx-common   # optional — only after proxy01 verified
```

Remove any `reverse_proxy_enabled` / certbot overrides from shell-clt01 host_vars.

### 9. Cleanup

- Remove stale `/etc/letsencrypt` lineage from shell-clt01 if no longer needed
- Update internal docs/bookmarks pointing at shell-clt01 for HTTPS
- Re-run `./scripts/test-quick.sh`

## Rollback

1. Revert UniFi 80/443 forwards to shell-clt01 (`192.168.1.17`).
2. Re-enable nginx on shell-clt01 (if not purged).
3. Revert kif Compose bindings to `0.0.0.0` temporarily.
4. Revert `host_firewall_edge_proxy_cidrs` to shell-clt01 LAN IP.

## Related docs

- [reverse-proxy-runbook.md](reverse-proxy-runbook.md)
- [edge-access-model.md](edge-access-model.md)
- [hypervisor-runbook.md](hypervisor-runbook.md)
