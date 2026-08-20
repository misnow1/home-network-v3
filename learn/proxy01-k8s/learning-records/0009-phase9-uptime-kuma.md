# Phase 9 Uptime Kuma live

Graduation app is on the same hybrid edge as whoami: public HTTPS through proxy01
(Authelia) → MetalLB VIP → HTTPRoute `uptime.2123studios.com` → local-path PVC.
First-run setup completed in the UI using SQLite (2026-08-20).

## Implications
- Missing public CNAME is a hard LE fail, not the Dreamhost secondary flake. Create
  `uptime` → `bastion` before force-renewal.
- local-path + SQLite is node-locked: drain leaves the pod Pending; uncordon recovers
  on the same worker. The runbook “move to the other worker” expectation is wrong here.
- `certbot_domains` still does not compare SANs; `-e certbot_force_renewal=true` plus
  a longer settle (`180s`) issued the cert after retries.
