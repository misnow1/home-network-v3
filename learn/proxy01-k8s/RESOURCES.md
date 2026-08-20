# Hybrid edge resources

## Knowledge

- [MetalLB: Layer 2 mode concepts](https://metallb.io/concepts/layer2/)
  Official explanation of ARP/NDP advertisement, single-node traffic attraction, and failover.
  Use for: what the VIP *is* on the wire; why L2 ≠ true multi-node LB.
- [MetalLB: Configuration (IPAddressPool + L2Advertisement)](https://metallb.io/configuration/)
  Official CR examples for pools and L2 ads. Use for: reading/writing the CRs in Phase 4.
- [Kubernetes docs: Gateway API](https://kubernetes.io/docs/concepts/services-networking/gateway/)
  Upstream conceptual model — GatewayClass, Gateway, HTTPRoute, request flow.
  Use for: role split and how Host/path matching attaches to a Gateway.
- [Repo: kubernetes-runbook.md Phase 4–7](../../docs/kubernetes-runbook.md)
  Local procedure: MetalLB pool, Envoy Gateway pin, whoami HTTPRoute, proxy01 site pattern.
  Use for: hands-on steps on *this* cluster.
- [Repo: ADR 003](../../docs/adr/003-home-kubernetes.md)
  Why hybrid edge (proxy01 TLS/Authelia + MetalLB + Envoy Gateway). Use for: decision context.
- [Repo: edge-access-model.md](../../docs/edge-access-model.md)
  Public-edge principles; k8s north-south path. Use for: where Authelia stays.

- [Gateway API: Security (ReferenceGrant)](https://gateway-api.sigs.k8s.io/docs/concepts/security/)
  Why cross-namespace backend refs need an explicit handshake. Use for: lesson 0005+.
- [Gateway API: ReferenceGrant API](https://gateway-api.sigs.k8s.io/reference/api-types/referencegrant/)
  Field-level grant semantics (`from` / `to`). Use for: writing grants and reading status.
- [Kubernetes: Operating etcd clusters](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/)
  Official backup/restore guidance for etcd used by kubeadm. Use for: Phase 8 snapshot/restore drills.

## Wisdom (Communities)

- [CNCF Slack — #gateway-api](https://cloud-native.slack.com/) (join via cncf.io Slack invite)
  Implementers and operators; use for: Gateway API semantics questions beyond this lab.
- [Kubernetes Slack — #metallb](https://kubernetes.slack.com/)
  MetalLB maintainers/users; use for: L2 ARP / VIP troubleshooting edge cases.

## Gaps

- Employer-specific Gateway implementation docs (once known: Istio / GKE Gateway / etc.) —
  add when work stack is named so transfer lessons can cite the same API kinds there.
