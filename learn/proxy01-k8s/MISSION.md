# Mission: Hybrid edge — proxy01 ↔ Kubernetes

## Why
Build portable Kubernetes networking skills for work clusters by making the home lab’s
public path real: traffic that already terminates on proxy01 (TLS + Authelia) must reach
in-cluster apps via MetalLB and Gateway API. Understanding that seam transfers directly to
how cloud LBs and Gateway/Ingress routing work at work.

## Success looks like
- From outside (or via public FQDN), `curl` a Host that proxy01 fronts and get the
  in-cluster whoami (or equivalent) response — proving Internet → proxy01 → MetalLB VIP →
  Envoy Gateway → Service → Pod. **Done** (whoami.2123studios.com, 2026-08-06).
- Explain, without notes, what MetalLB’s VIP is doing vs what Gateway/`HTTPRoute` is doing.
- Add a `reverse_proxy_sites` entry pointed at the VIP and apply it confidently. **Done**.
- Take an etcd snapshot on k8s-cp01, copy it (and pki) off-box, and treat restore drill as
  the gate before any useful/stateful graduation app. **Done** — safe verify (2026-08-14)
  + full cutover with canary (2026-08-18).
- Phase 9 graduation app (Uptime Kuma) on the same hybrid path, with local-path PVC and
  a drain drill that shows node-locked storage. **Done** (2026-08-20).

## Constraints
- Spaced sessions are fine; no hard deadline.
- Prefer teaching against this repo’s runbook and live cluster over abstract tutorials.
- Reuse existing nginx / Authelia / VLAN fluency — do not re-teach those from scratch.

## Out of scope
- Migrating Authelia (or Plex/Paperless) into the cluster (ADR 003 non-goal for v1).
- Cilium Gateway / Cilium L2 as replacements for Envoy + MetalLB.
- Full Velero/PVC backup story (later milestone; separate from etcd).
