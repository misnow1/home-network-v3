# Prior knowledge: edge stack already fluent

Strong existing fluency with nginx (`reverse_proxy_sites`), Authelia forward-auth (Docker
on kif), and UniFi VLAN/firewall. Future lessons should treat those as known and spend
working memory on MetalLB VIP and Gateway/`HTTPRoute` instead.

## Implications
- Map new concepts *to* nginx (upstream IP, `server_name`) rather than teaching reverse
  proxies from scratch.
- Authelia is the edge gate they already run — not the first in-cluster app for Phase 7.
