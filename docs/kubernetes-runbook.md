# Kubernetes cluster runbook

Learning-first kubeadm cluster on VLAN 9: single control-plane VM, two bare-metal workers,
hybrid edge via **proxy01** → MetalLB VIP → **Envoy Gateway** (Gateway API). See
[adr/003-home-kubernetes.md](adr/003-home-kubernetes.md) for decisions.

**Scope:** Ansible prepares nodes (`k8s-node-prep.yml`); bootstrap steps below are manual in v1.

## Architecture

```
Internet → proxy01 (TLS + Authelia) → MetalLB VIP :80 → Envoy Gateway → apps
                                              ↑ VLAN 9
k8s-cp01 (CP VM) + k8s-node-1/2 (workers) + Cilium CNI
```

| Component | Address / notes |
|---|---|
| VLAN 9 gateway | `192.168.9.1` |
| Control plane | `192.168.9.10` — `k8s-cp01.home.2123studios.com` |
| Worker 1 | `192.168.9.128` — `k8s-node-1.home.2123studios.com` |
| Worker 2 | `192.168.9.129` — `k8s-node-2.home.2123studios.com` |
| MetalLB pool | `192.168.9.200`–`192.168.9.210` |
| Pod CIDR | `10.244.0.0/16` (Cilium cluster-pool) |
| Service CIDR | `10.96.0.0/12` |

## Prerequisites

1. **UniFi VLAN 9** — routed, DNS, firewall — [unifi-gateway-dns.md](unifi-gateway-dns.md#vlan-9-kubernetes)
2. **Hypervisor br9/vlan9** on kvm01 — [hypervisor-runbook.md](hypervisor-runbook.md#vlan-9--kubernetes-fabric-br9)
3. **Inventory** — copy templates from `inventories/production/hosts.yml.example` and
   `group_vars/k8s/vars.yml.example` (optional CP-only `host_vars/k8s-cp01...`; workers
   share group_vars — no per-worker host_vars unless they diverge)
4. **NFS from kif** (optional, for RWX PVCs) — prove Slice 15+ before relying on it
   ([nfs-server-runbook.md](nfs-server-runbook.md))
5. **Slice 26 edge** — proxy01 operational ([reverse-proxy-runbook.md](reverse-proxy-runbook.md))
6. **Helm** — installed on k8s nodes by `k8s_node` (`k8s_helm_version`, default 4.x). Helm 4
   runs Chart API v2 charts unchanged; install it separately if you drive charts from an
   admin workstation instead.

## Phase 0 — Node provisioning

### Workers (bare metal)

1. Generate cloud-init and reimage HP Z2 Minis via USB (existing workflow).
2. Static VLAN 9 addressing per `hosts.yml` (`.128`/`.129`, gateway `.1`, Pi-hole DNS).
3. Ensure SSH as `ansible` user works from your admin workstation or bastion.

### Control plane (VM on kvm01)

```bash
# After hypervisor br9 converged:
./scripts/vm/vm-create.sh -i production k8s-cp01.home.2123studios.com
```

### Ansible node prep

```bash
cp inventories/production/group_vars/k8s/vars.yml.example \
   inventories/production/group_vars/k8s/vars.yml
# Set k8s_operator_ssh_keys in vars.yml

./scripts/prod-run.sh --confirm-production -- playbooks/baseline.yml --limit k8s
./scripts/prod-run.sh --confirm-production -- playbooks/k8s-node-prep.yml
```

Verify on each node:

```bash
containerd --version
kubeadm version -o short
kubelet --version
helm version --short
cilium version --client
swapon --show    # empty
sysctl net.ipv4.ip_forward   # 1
# Optional: compare CRI sandbox to kubeadm
containerd config dump | grep -A2 pinned_images
kubeadm config images list | grep pause
```

Open a **new** interactive bash or zsh session and confirm kubectl tab completion works
(`kubectl get <TAB>`). Nodes install system-wide completion via `/etc/bash_completion.d/kubectl`
and drop-ins under `/etc/bash.bashrc.d` / `/etc/zsh/zshrc.d`.

## Phase 1 — kubeadm bootstrap (control plane)

Run on **k8s-cp01** as root (or sudo). Adjust version flags to match `k8s_kubernetes_version`
(currently **1.36**).

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.9.10 \
  --control-plane-endpoint=192.168.9.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --node-name=k8s-cp01.home.2123studios.com

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

Save the `kubeadm join` command output for workers. Taint CP so workloads schedule on workers only:

```bash
kubectl taint nodes k8s-cp01.home.2123studios.com node-role.kubernetes.io/control-plane:NoSchedule
```

Copy `admin.conf` to your workstation (via bastion). Restrict file mode `600`.

## Phase 2 — CNI (Cilium)

Install Cilium via Helm. Align cluster-pool pod CIDR with kubeadm. Enable Hubble; leave
Cilium Gateway API and L2 announcements **off** (Envoy Gateway + MetalLB own those).

Pin the chart version to a current stable release and verify against
[Cilium kubeadm install docs](https://docs.cilium.io/en/stable/installation/k8s-install-kubeadm/)
before running (example pin below — bump after checking release notes):

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium --version 1.19.6 \
  --namespace kube-system \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="{10.244.0.0/16}" \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

Wait for the node to go Ready and the Cilium DaemonSet to roll out:

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl get nodes                 # k8s-cp01 Ready
kubectl -n kube-system get pods -l k8s-app=kube-dns   # coredns Running once CNI is up
```

**Do not run `cilium status --wait` yet — it cannot go green on a single control plane.**
Three components stay `Pending` by design until Phase 3 adds an untainted worker:

| Pending pod | Why | Clears when |
|---|---|---|
| `cilium-operator` (2nd of 2 replicas) | `hostNetwork: true` with hostPorts 9234/9963; two replicas cannot bind the same ports on one node | A second node joins |
| `hubble-relay` | No toleration for `node-role.kubernetes.io/control-plane:NoSchedule` | An untainted worker joins |
| `hubble-ui` | Same — ordinary workload, CP is tainted per ADR 003 | An untainted worker joins |

`cilium` and `cilium-envoy` DaemonSets tolerate the CP taint and should be `1/1` now. If you
want a fully green single-node cluster before the workers exist, install with
`--set operator.replicas=1 --set hubble.relay.enabled=false --set hubble.ui.enabled=false`
and `helm upgrade` those back on after Phase 3 — do **not** untaint the control plane, which
would violate the workers-only decision in ADR 003.

Lab NetworkPolicy: create a deny-all policy in a test namespace, then allow one pod — confirm
enforcement. Optional: open Hubble UI (`cilium hubble ui`) once workers are joined.

## Phase 3 — Join workers

On each worker (**k8s-node-1**, **k8s-node-2**), run the `kubeadm join` command from init output.
If token expired:

```bash
# On CP:
kubeadm token create --print-join-command
```

Verify from CP, and only now expect Cilium to converge fully:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide | grep -E 'cilium|hubble'
cilium status --wait      # should now be all OK
```

The `cilium-operator` second replica, `hubble-relay`, and `hubble-ui` should leave `Pending`
and land on workers. If they do not, check worker taints and `kubectl -n kube-system describe
pod <name>` for the scheduling reason.

Practice: `kubectl drain`, `kubectl uncordon`, delete a test pod and confirm reschedule.

## Phase 4 — MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml
# Wait for metallb controller/speaker Ready
```

Create `IPAddressPool` and `L2Advertisement` (adjust pool to reserved range):

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: vlan9-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.9.200-192.168.9.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: vlan9-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - vlan9-pool
```

Pick a VIP for Envoy Gateway (e.g. `192.168.9.200`) and add a static DNS A record
(`k8s-gw.home.2123studios.com`).

From **proxy01** or admin host on VLAN 1, verify reachability after Phase 5:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.9.200/
# Expect connection refused or 404 until a Gateway/HTTPRoute exists — not timeout
```

## Phase 5 — Envoy Gateway (Gateway API)

Install Gateway API + Envoy Gateway CRDs explicitly, then the controller with CRD install
disabled (avoids Helm silently downgrading CRDs). Pin versions — verify against
[Envoy Gateway Helm install](https://gateway.envoyproxy.io/v1.8/install/install-helm/)
before running:

```bash
# CRDs (standard Gateway API channel + Envoy Gateway CRDs)
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version v1.8.3 \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.3 \
  -n envoy-gateway-system \
  --create-namespace \
  --set crds.enabled=false

kubectl wait --timeout=5m -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available
```

Create a shared `GatewayClass`, pin MetalLB VIP on the Envoy proxy Service, and a cluster
HTTP `Gateway` listening on port 80 (proxy01 terminates TLS):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: eg-proxy-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        annotations:
          metallb.universe.tf/loadBalancerIPs: "192.168.9.200"
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: envoy-gateway-system
spec:
  gatewayClassName: eg
  infrastructure:
    parametersRef:
      group: gateway.envoyproxy.io
      kind: EnvoyProxy
      name: eg-proxy-config
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

Confirm EXTERNAL-IP on the Envoy proxy Service is `192.168.9.200`:

```bash
kubectl get svc -n envoy-gateway-system
kubectl get gateway -n envoy-gateway-system
```

Smoke test: deploy a tiny app + `HTTPRoute` attaching to `gatewayRef` `eg` /
`envoy-gateway-system`. Confirm HTTP via the MetalLB VIP and `Host` header.

## Phase 6 — Platform add-ons

Install before any “useful” app:

| Add-on | Purpose |
|---|---|
| metrics-server | `kubectl top` |
| local-path-provisioner | Default StorageClass for scratch |
| NFS CSI (optional) | RWX PVCs from kif — after NFS server proof |

Defer **cert-manager** until the Gateway HTTP path from proxy01 is boring (public TLS stays
on proxy01).

## Phase 7 — proxy01 integration

Add a site in `reverse_proxy_sites` (group_vars) pointing at the MetalLB VIP. Example pattern:

```yaml
- name: k8s_apps
  server_names:
    - uptime.example.com
  upstream: http://192.168.9.200
  auth_required: true
  locations:
    - path: /
      proxy_pass: http://192.168.9.200
```

Apply `reverse-proxy.yml` on proxy01. TLS and Authelia remain on proxy01; Envoy Gateway
receives plain HTTP from the LAN side.

For per-app hostnames, configure `HTTPRoute` hostnames matching proxy01 `server_name` /
public DNS/cert SANs. Use `ReferenceGrant` when routes and Services live in different
namespaces.

## Phase 8 — etcd backup (required before graduation app)

On **k8s-cp01**, schedule snapshots:

```bash
# Manual test:
sudo ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Copy snapshots and `/etc/kubernetes/pki` off-box (kif restic scope or rsync). Document restore:

```bash
# Disaster recovery outline — practice in lab first:
# 1. Reimage CP VM, rerun k8s-node-prep
# 2. kubeadm init --ignore-preflight-errors=all (or restore static pods from backup procedure)
# 3. etcdctl snapshot restore ...
# 4. Rejoin workers or rebuild cluster per upstream disaster recovery docs
```

**Do not deploy Uptime Kuma or other useful apps until a snapshot restore drill succeeds.**

## Phase 9 — Graduation app

Deploy **Uptime Kuma** (or similar) with:

- `HTTPRoute` + `auth_required` on proxy01
- PVC on local-path or NFS StorageClass
- Confirm pod survives node drain to the other worker

## Later milestones

| Milestone | When |
|---|---|
| Argo CD | After first app works; migrate manifests to GitOps |
| cert-manager | After Gateway HTTP from proxy01 is boring |
| kube-prometheus-stack | Phase 2 ops muscle; watch memory on 16 GB workers |
| kubectl OIDC via Authelia | After gateway path is boring |
| Cilium kube-proxy replacement | After CNI/Gateway are routine |
| Velero + PVC backup | Before migrating Compose apps off kif |
| CP HA (3 CP nodes) | After etcd restore is routine |
| Longhorn/Ceph | After additional shared disk capacity |
| Cilium Gateway / L2 (optional) | Only if consolidating away from Envoy/MetalLB intentionally |

## Explicit non-goals (v1)

- Domain-joining kube nodes
- Idempotent `kubeadm init` in Ansible
- Public NodePort exposure from UniFi
- Community ingress-nginx (EOL)
- Migrating Authelia/Plex/Paperless from kif Compose

## Troubleshooting

| Symptom | Check |
|---|---|
| `kubeadm init` fails on swap | `swapon --show`; rerun `k8s-node-prep.yml` |
| `ERROR FileExisting-conntrack` | Rerun `k8s-node-prep.yml` — `k8s_preflight_packages` installs it |
| Warning: sandbox image `""` inconsistent with kubeadm | Cosmetic. kubeadm reads `sandboxImage` from the CRI runtime status, which containerd 2.x no longer reports there. Confirm with `containerd config dump \| grep -A2 pinned_images` and compare against `kubeadm config images list`; set `k8s_pause_image` if they differ |
| Nodes NotReady | Cilium pods / `cilium status`; `journalctl -u kubelet` |
| `cilium status` never converges; operator/hubble `Pending` | Expected before workers join — see Phase 2. `didn't have free ports` = operator replica 2 needs a second node; `untolerated taint` = hubble needs an untainted worker |
| MetalLB VIP unreachable from proxy01 | UniFi firewall VLAN 1→9, ARP on VLAN 9 |
| Gateway 502 from proxy01 | `kubectl get gateway,httproute -A`; Envoy proxy Service EXTERNAL-IP matches pool |
| HTTPRoute Accepted=False | Gateway `allowedRoutes`, ReferenceGrant, Service/port names |
| DNS failures in pods | Node `/etc/resolv.conf`; Pi-hole or DC reachability from VLAN 9 |
| NFS PVC mount fails | kif exports, firewall 2049, CSI driver logs |

## References

- [adr/003-home-kubernetes.md](adr/003-home-kubernetes.md)
- [home-lab-k8s-stack.md](home-lab-k8s-stack.md)
- [edge-access-model.md](edge-access-model.md)
- [cka-runbook.md](cka-runbook.md) — separate CKA practice VMs on vlan3
- [ROADMAP.md](ROADMAP.md) — Slice 31
