# Home Lab Kubernetes Stack Recommendations

Brief for planning a personal Kubernetes learning cluster. Focus: modern replacements for community `ingress-nginx` (EOL March 2026), plus a sensible surrounding stack.

## Context

- Community **ingress-nginx** reached end-of-life in March 2026; remaining on it is a security risk (no supported fixes).
- The Kubernetes Ingress API remains available but is **feature-frozen**.
- Upstream direction is the **Gateway API** (`GatewayClass`, `Gateway`, `HTTPRoute`, etc.), not another Ingress annotation dialect.
- Migration tooling: SIG Network’s [ingress2gateway](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/).

## Ingress / Gateway Decision

**Learn Gateway API, not another Ingress controller.**

### Options compared

| Option | API you learn | Homelab fit | Notes |
|---|---|---|---|
| **Envoy Gateway** | Gateway API | Best pure ingress successor | CNCF project, strong conformance, common migration target in community writeups. Keeps CNI separate. |
| **Cilium Gateway** | Gateway API (+ CNI, NetworkPolicy, Hubble, optional LB) | Best “fewer moving parts” | Can replace Calico + often MetalLB + Ingress. Watch Gateway API CRD version pairing with Cilium. |
| **Traefik** | Ingress and/or Gateway API | Easy, popular in labs | Fast to stand up; weaker long-term skill investment than Envoy/Cilium for platform networking. |
| **F5 NGINX Ingress Controller (NIC)** | Still **Ingress** (+ vendor CRDs) | Weak for learning goals | Different project from community ingress-nginx (`nginx.org/*` annotations, different CRDs). Continuity play, not future skills. |
| **NGINX Gateway Fabric (NGF)** | Gateway API on NGINX | Only if you want NGINX *and* Gateway API | F5’s Gateway-native product — **not** the same as NIC. |

### Recommendation

1. **Default:** **Cilium as CNI** + **Envoy Gateway** for L7  
   - Cilium: eBPF networking, NetworkPolicy, Hubble observability.  
   - Envoy Gateway: portable Gateway API model without tying L7 to the CNI.

2. **Simpler stack:** **Cilium only** (CNI + Gateway API + L2 load balancing)  
   - One chart, fewer VIPs/components. Slightly less portable Gateway experience if you later move to a cloud LB + different controller.

3. **Avoid for learning:** F5 NIC (stays on feature-frozen Ingress). Prefer NGF only if deliberately staying on NGINX while adopting Gateway API.

4. **Traefik:** Acceptable for “get HTTP working this weekend”; plan to move to Envoy or Cilium Gateway when studying Gateway semantics.

## Recommended Home Lab Stack

Pin to the **latest stable patch** of each component. Prefer **Kubernetes n−1** if you want fewer sharp edges on day one.

| Layer | Pick | Why |
|---|---|---|
| Distro | **Talos** or **kubeadm** (or **k3s** for speed) | Talos/kubeadm feel closer to “real” clusters; if using k3s, disable its bundled Traefik when installing your own gateway |
| Kubernetes | **1.33.x or 1.34.x** (current stable, or n−1) | Stay current without chasing every brand-new minor on day one |
| CNI | **Cilium** (recent stable; if using Cilium Gateway, prefer a release that documents **Gateway API ~1.6.x** support — e.g. 1.20+) | Strong learning surface; Hubble for observability |
| Gateway | **Envoy Gateway ~1.8.x** *or* Cilium Gateway | Install matching **Gateway API CRDs** first; do not let Helm silently downgrade CRDs |
| LB (bare metal) | Cilium L2 announcements **or** MetalLB | Needed for `LoadBalancer` Services without a cloud provider |
| TLS | **cert-manager** + Let’s Encrypt (DNS-01 if no public HTTP-01 path) | Homelab staple |
| GitOps | **Argo CD** | Industry-standard GitOps; good learning investment |
| Storage | local-path-provisioner or Longhorn | Keep boring until CSI is an intentional learning goal |

### Version pairing caveats

- **Gateway API CRDs must match the controller.** Cilium and Envoy Gateway each document a supported Gateway API version/channel. Mismatches (especially around `TLSRoute` standard vs experimental) cause confusing controller errors.
- When Helm charts bundle Gateway API CRDs, prefer installing CRDs explicitly first, then install the chart with CRD install skipped / disabled if your CRDs are already newer.
- Example pairings seen in recent docs/homelab writeups (verify against current release notes before locking a plan):
  - Envoy Gateway **v1.8.x** + compatible Gateway API CRDs
  - Cilium **1.20+** + Gateway API **v1.6.1** (earlier Cilium may need older Gateway API / TLSRoute channel)

## Suggested Learning Path

1. Bring up cluster + Cilium + Hubble.
2. Install Gateway API CRDs → Envoy Gateway (or enable Cilium Gateway).
3. Deploy one shared `Gateway` + an `HTTPRoute` + cert-manager TLS.
4. Add NetworkPolicies; then ReferenceGrants / multi-namespace routing.
5. Optional: convert sample Ingress YAML with `ingress2gateway` to see annotation → route mapping.

## Decision Summary for the Planning Agent

- **Do not** plan on community ingress-nginx.
- **Do** target Gateway API as the north-star traffic API.
- **Preferred default stack:** Cilium (CNI) + Envoy Gateway (L7) + cert-manager + (Cilium L2 or MetalLB) + Argo CD.
- **Acceptable simplification:** Cilium alone for CNI + Gateway + LB.
- **Deprioritize:** F5 NIC (Ingress-only continuity); Traefik unless speed-to-HTTP is the only near-term goal.

## Useful References

- [Ingress2Gateway 1.0 (Kubernetes blog)](https://kubernetes.io/blog/2026/03/20/ingress2gateway-1-0-release/)
- [CNCF: Navigating the ingress-NGINX retirement](https://www.cncf.io/blog/2026/07/09/navigating-the-ingress-nginx-retirement/)
- [CNCF: Zero-downtime migration to Envoy Gateway](https://www.cncf.io/blog/2026/05/25/zero-downtime-migration-from-ingress-nginx-to-envoy-gateway/)
- [Envoy Gateway Helm install](https://gateway.envoyproxy.io/v1.8/install/install-helm/)
- [Cilium Gateway API docs](https://docs.cilium.io/en/latest/network/servicemesh/gateway-api/gateway-api/)

## Adoption note

**Path A adopted** (2026-07-29) in [adr/003-home-kubernetes.md](adr/003-home-kubernetes.md): Cilium CNI + Envoy Gateway + MetalLB; hybrid edge via proxy01. See [kubernetes-runbook.md](kubernetes-runbook.md).
