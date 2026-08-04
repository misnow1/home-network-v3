# UniFi 5G Backup — WAN failover policy

FerryCrossing primary internet is the ISP on the **UniFi Cloud Gateway Fiber**
(UCG Fiber, `192.168.1.1`). A **UniFi 5G Backup** (U5G, 5G RedCap) provides
metered cellular failover (10 / 50 / 100 GB plans). Router configuration is
**manual** — not Ansible-managed.

See also:

- [unifi-gateway-dns.md](unifi-gateway-dns.md) — VLANs, DHCP, DDNS hook
- [edge-access-model.md](edge-access-model.md) — public edge services and WAN exposure
- [remote-site-dns.md](remote-site-dns.md) — Woodbine / Swanhollow site-to-site VPN
- [backup-runbook.md](backup-runbook.md) — restic offsite (block on cellular)

## Goals

| Keep working on cellular | Starve / block on cellular |
|---|---|
| Phone/laptop messaging (Signal, iMessage, WhatsApp, etc.) | BitTorrent / Transmission |
| Light web browsing (bandwidth-capped) | Streaming media (YouTube, Netflix, Plex remote) |
| On-LAN SSH; outbound SSH from VLAN 1 | OS / app-store update storms |
| Pi-hole upstream DNS; mail → Gmail alerts | Cloud backup / restic offsite bulk |
| Optional site-to-site VPN (rate-limited) | IoT cloud chatter; K8s image pulls |

**Do not** load-balance primary ISP and 5G. Failover only.

## CGNAT / inbound expectation

Carrier cellular is usually **CGNAT**. During failover:

- **Outbound** apps (messaging, DNS, mail, light browsing) work.
- **Inbound** UniFi port-forwards (SSH → shell-clt01, HTTPS → proxy01,
  Transmission peer) often **do not** reach the site from the internet.
- On-LAN SSH to shell-clt01 still works.
- Do not open extra port-forwards “for failover” — they will not fix CGNAT.

Optional later (not required day one): UniFi Teleport / site VPN, or an always-on
overlay (e.g. Tailscale on bastion) for inbound admin during primary-WAN outages.

```
VLAN 1 / 2 / 9 ──► UCG Fiber ──► Primary ISP (active)
                      │
                      └── GRE ◄── U5G (PoE LAN, standby failover)
```

## Hardware setup

1. **Place for signal** — window or high-signal spot. Power from any PoE switch
   port on the LAN (**VLAN 1** untagged). Do **not** put the U5G on IoT or
   restricted VLANs.
2. UniFi Network → adopt the U5G; activate SIM / data plan.
3. Confirm it appears as a cellular / backup internet interface.
4. **Settings → Internet** — role **Failover only** (never Load Balancing).
5. **SLA probes** — leave Auto unless the primary flaps; avoid brief bounce onto
   cellular that burns quota.
6. **Usage alerts** — notify at ~50% and ~80% of the plan (10 / 50 / 100 GB).

No new VLANs are required. Existing segmentation is enough; policy is which
networks may use cellular.

## Per-network failover matrix

In each UniFi **Network** (Settings → Networks → … → Internet / failover), set
whether that network may use the cellular backup:

| Network | Subnet | Cellular failover | Why |
|---|---|---|---|
| VLAN 1 LAN | `192.168.1.0/24` | **Allow** | Phones/laptops (messaging, light web); DCs/Pi-hole upstream DNS; mail→Gmail |
| VLAN 2 IoT | `192.168.3.0/24` | **Deny** | Cloud keepalives and firmware pulls waste the plan; local IoT still works |
| VLAN 3 Restricted | `192.168.5.0/24` | **Deny** | Isolated; no need |
| VLAN 4 Docker edge | `192.168.7.0/24` | N/A | L2-only — no UniFi gateway ([adr/002-docker-edge-vlan.md](adr/002-docker-edge-vlan.md)) |
| VLAN 9 Kubernetes | `192.168.9.0/24` | **Deny** | Image pulls / telemetry can exhaust a small plan; cluster stays LAN-usable |

Woodbine (`192.168.33.0/24`) and Swanhollow (`192.168.65.0/24`) keep their own
WANs. If FerryCrossing primary is down, **site-to-site VPN** from those sites to
FerryCrossing rides cellular — allow but rate-limit (see Traffic Rules).

## Traffic Rules (cellular-scoped)

**Settings → Traffic Management → Traffic Rules.** Scope rules to the
**5G Backup / cellular** interface (or “when using failover WAN”), **not** the
primary ISP.

UI category names vary by Network application version; map to the closest match.

### Block on cellular

| Target | Rationale |
|---|---|
| P2P / BitTorrent | Transmission on kif — trackers + peers burn quota |
| Streaming Media | Netflix, YouTube, Plex remote, etc. |
| OS Updates / App Stores | Windows / macOS / iOS update storms |
| Cloud Backup / file sync | restic offsite, OneDrive / iCloud bulk sync |
| Social Media (video-heavy) | Optional if still too chatty after streaming block |

Device/IP fallthrough when categories miss Docker NAT:

- Prefer confirming **P2P** matches kif (`192.168.1.152`) Docker outbound.
- If not, add an explicit block for that client on the cellular interface.
- Transmission peer port-forward remains primary-WAN only; ignore under CGNAT.

### Allow on cellular

| Target | Rationale |
|---|---|
| Messaging / VoIP / conferencing | Signal, iMessage, WhatsApp, Slack text, FaceTime audio |
| DNS | Pi-hole → upstream (tiny); AD zones stay LAN |
| Mail | mail/mail2 → Gmail (alerts, Authelia, NUT) |
| SSH / admin tools from VLAN 1 | Outbound and on-LAN admin |
| Web | Limited browsing (pair with rate limits below) |

### Rate-limit on cellular

| Target | Suggested posture |
|---|---|
| Downloads / Web | Cap so browsing works but HD streams stall (~1–3 Mbps per client if the UI allows) |
| Site-to-site VPN (Woodbine / Swanhollow) | Allow for AD DNS continuity; rate-limit so remotes do not stream via FerryCrossing cellular |
| Unknown / Other | Low rate limit as a safety net |

Exact Mbps knobs depend on UniFi Network version. Pick values that make 1080p
painful while chat and maps remain usable.

## Service priority (operational model)

**Survives without WAN (ignore cellular):** AD/Kerberos, LDAP VIP, Samba/NFS,
local Plex/Guacamole/Paperless via LAN URLs, K8s east-west on VLAN 9, DHCP.

**Should use cellular (small):** Phone messaging, light web on VLAN 1, Pi-hole
recursion, mail relay → Gmail, optional rate-limited site-to-site VPN.

**Must not use cellular:** Transmission, Plex remote streaming, restic offsite,
K8s image pulls, IoT cloud, large OS updates, bulk downloads.

**Likely broken inbound on cellular:** Public SSH, public HTTPS, Transmission
peer port (CGNAT). On-LAN SSH still works.

## Host-side notes

UniFi rules are the primary control. Complements:

- If P2P categories miss Docker NAT, add a kif client block on cellular and
  re-test Transmission during failover.
- Pause restic schedules during known long outages, or rely on the Cloud Backup
  traffic block.
- Do not change VLAN 4 L2 design or deferred edge VIP HA for this policy.

## Validation checklist

1. U5G adopted, Failover-only, strong signal, usage alerts configured.
2. Per-network matrix applied (VLAN 1 allow; 2 / 3 / 9 deny).
3. Cellular-scoped Traffic Rules in place (block / allow / rate-limit).
4. Simulate primary WAN failure (unplug ISP or disable WAN in UI).
5. **Phone on VLAN 1:** messaging works; YouTube/Plex stream fails or crawls;
   web search works slowly.
6. **IoT VLAN:** no cellular path (cloud offline is expected).
7. **kif:** Transmission transfers stop; no large restic upload.
8. **VLAN 9:** no egress via cellular.
9. **Off-site:** expect SSH/HTTPS to public IP to fail under CGNAT.
10. Restore primary WAN; confirm traffic returns and cellular bytes stop climbing.

## What not to do

- Do not load-balance primary + 5G.
- Do not enable cellular failover on IoT or K8s “just in case.”
- Do not create a parallel “failover VLAN” / SSID unless Traffic Rules prove
  insufficient — extra DHCP and Wi-Fi SSIDs add cost for little gain here.
- Do not rely on RedCap for remote Plex or torrenting.

## Review cadence

Revisit this document when:

- Changing the cellular data plan size
- Adding a VLAN or moving phones/IoT between networks
- Adding a high-bandwidth service on VLAN 1 (new Docker app, backup target)
- Adopting inbound-admin overlay (Teleport / Tailscale) for CGNAT outages
