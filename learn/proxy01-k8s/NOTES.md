# Notes (teacher scratchpad)

## Preferences
- Spaced sessions OK.
- Teaching home: `learn/proxy01-k8s/` inside this repo.
- Success check they like: end-to-end `curl` through proxy01 to in-cluster whoami.

## Prior knowledge (do not re-teach)
- nginx / `reverse_proxy_sites` — strong
- Authelia forward-auth (already Docker on kif) — strong
- VLAN / UniFi firewall — strong

## Foggy (ZPD)
- MetalLB VIP / L2 advertisement — lesson 0001; proven live
- Gateway + HTTPRoute — lesson 0002; whoami HTTPRoute live on public name
- Phase 7 proxy01 wiring — lesson 0003; public HTTPS whoami succeeded
- Failure triage — lesson 0004 shipped
- ReferenceGrant — lesson 0005 shipped
- Phase 8/9 bridge (etcd bar) — lesson 0006 shipped
- Safe verify restore drill — done 2026-08-14
- Full cutover restore — done 2026-08-18; Phase 8 gate cleared
- Phase 9 Uptime Kuma — public path + drain drill 2026-08-20

## Ops note (2026-08-06)
Dreamhost DNS-01: auth hook can show TXT on all three NS while LE secondary
returns NXDOMAIN; retry (or longer settle) usually clears it.

## Ops note (2026-08-12)
Manual etcd snapshot on k8s-cp01 + off-box copy to kif `/archive/backup/`
(etcd db + pki tgz). Long-term automation still undecided (prefer NFS/restic
over root SSH).

## Ops note (2026-08-14)
Safe verify etcd restore drill on prod CP completed (throwaway
`/var/lib/etcd-restore-drill`; API stayed up).

## Ops note (2026-08-18)
Full etcd cutover on prod succeeded (canary absent, API healthy). Optional:
delete `/var/lib/etcd.pre-cutover-bak-2026-08-17` when ready. Phase 9 unblocked.

## Ops note (2026-08-20)
Phase 9: added Dreamhost CNAME `uptime` → `bastion`, force-renewed SAN (settle 180s),
applied reverse-proxy. Public `curl -I https://uptime.2123studios.com/` → Authelia 302.
Drain of `k8s-node-1`: Kuma Pending (local-path affinity); uncordon restored it there.
whoami rescheduled to `k8s-node-2`.
First-run setup completed in the UI using SQLite (2026-08-20).

## Next lesson candidates
1. Optional: automate etcd off-box (NFS drop + kif restic vs restic-on-CP)
2. Optional: intentional break/fix failure labs
3. Later: RWX/replicated storage if Kuma should survive worker loss
