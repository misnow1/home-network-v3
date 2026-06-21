# UniFi gateway scripts

Example on-boot helpers for **UniFi Cloud Gateway** family devices (UCG Fiber,
UDM, UXG). See **[docs/unifi-gateway-dns.md](../../docs/unifi-gateway-dns.md)**
for the full cutover procedure.

## Files

| File | Install location on gateway |
|---|---|
| `install-home-ddns.sh` | Run once via SSH (not persisted) |
| `dhcp-script-wrapper.sh` | `/data/home-ddns/dhcp-script-wrapper.sh` |
| `home-ddns.env.example` | `/data/home-ddns/home-ddns.env` |
| `20-home-ddns.sh` | `/data/on_boot.d/20-home-ddns.sh` |
| `../dhcp-ddns-hook.sh` (repo `scripts/`) | `/data/home-ddns/dhcp-ddns-hook.sh` |

`20-home-ddns.sh` patches `shared.conf` to use the wrapper (chains UniFi
`dnsmasq-dhcp-script` + DDNS hook). Do not add a second `dhcp-script=` file.

## Quick install

```bash
GATEWAY=gateway.example.com
REPO=/path/to/home-network-v3

scp "${REPO}/scripts/dhcp-ddns-hook.sh" \
    "${REPO}/scripts/router/unifi/dhcp-script-wrapper.sh" \
    "${REPO}/scripts/router/unifi/home-ddns.env.example" \
    root@"${GATEWAY}":/tmp/
ssh root@"${GATEWAY}" 'bash -s' < "${REPO}/scripts/router/unifi/install-home-ddns.sh"

# Edit bearer token on gateway, then:
scp "${REPO}/scripts/router/unifi/20-home-ddns.sh" root@"${GATEWAY}":/data/on_boot.d/
ssh root@"${GATEWAY}" 'chmod 755 /data/on_boot.d/20-home-ddns.sh && /data/on_boot.d/20-home-ddns.sh'
```

## Recovery from duplicate dhcp-script

```bash
rm -f /run/dnsmasq.dhcp.conf.d/home-ddns.conf
/data/on_boot.d/20-home-ddns.sh
```
