# Kubernetes cluster runbook

Learning-first kubeadm cluster on VLAN 9: single control-plane VM, two bare-metal workers,
hybrid edge via **proxy01** → MetalLB VIP → **ingress-nginx**. See
[adr/003-home-kubernetes.md](adr/003-home-kubernetes.md) for decisions.

**Scope:** Ansible prepares nodes (`k8s-node-prep.yml`); bootstrap steps below are manual in v1.

## Architecture

```
Internet → proxy01 (TLS + Authelia) → MetalLB VIP :80 → ingress-nginx → apps
                                              ↑ VLAN 9
k8s-cp01 (CP VM) + k8s-node-1/2 (workers)
```

| Component | Address / notes |
|---|---|
| VLAN 9 gateway | `192.168.9.1` |
| Control plane | `192.168.9.10` — `k8s-cp01.home.2123studios.com` |
| Worker 1 | `192.168.9.128` — `k8s-node-1.home.2123studios.com` |
| Worker 2 | `192.168.9.129` — `k8s-node-2.home.2123studios.com` |
| MetalLB pool | `192.168.9.200`–`192.168.9.210` |
| Pod CIDR | `10.244.0.0/16` |
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
swapon --show    # empty
sysctl net.ipv4.ip_forward   # 1
```

## Phase 1 — kubeadm bootstrap (control plane)

Run on **k8s-cp01** as root (or sudo). Adjust version flags to match `k8s_kubernetes_version`.

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

## Phase 2 — CNI (Calico)

Install Calico matching your Kubernetes minor version — follow upstream docs, e.g.:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml
```

Wait for calico-node pods Ready on CP. Verify:

```bash
kubectl get nodes
kubectl get pods -A
```

Lab NetworkPolicy: create a deny-all policy in a test namespace, then allow one pod — confirm enforcement.

## Phase 3 — Join workers

On each worker (**k8s-node-1**, **k8s-node-2**), run the `kubeadm join` command from init output.
If token expired:

```bash
# On CP:
kubeadm token create --print-join-command
```

Verify from CP:

```bash
kubectl get nodes -o wide
```

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

Pick a VIP for ingress (e.g. `192.168.9.200`) and add a static DNS A record
(`k8s-ingress.home.2123studios.com`).

From **proxy01** or admin host on VLAN 1, verify reachability:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://192.168.9.200/
# Expect connection refused or 404 until ingress is installed — not timeout
```

## Phase 5 — ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.loadBalancerIP=192.168.9.200
```

Confirm EXTERNAL-IP on the controller Service matches the MetalLB VIP.

## Phase 6 — Platform add-ons

Install before any “useful” app:

| Add-on | Purpose |
|---|---|
| metrics-server | `kubectl top` |
| local-path-provisioner | Default StorageClass for scratch |
| NFS CSI (optional) | RWX PVCs from kif — after NFS server proof |

Smoke test: deploy `whoami` or `nginx` with Ingress, confirm HTTP from CP via VIP.

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

Apply `reverse-proxy.yml` on proxy01. TLS and Authelia remain on proxy01; ingress receives plain HTTP from the LAN side.

For per-app hostnames, configure Ingress resources with matching `host` rules; proxy01 `server_name` must match public DNS/cert SANs.

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

- Ingress + `auth_required` on proxy01
- PVC on local-path or NFS StorageClass
- Confirm pod survives node drain to the other worker

## Later milestones

| Milestone | When |
|---|---|
| Argo CD | After first app works; migrate manifests to GitOps |
| kube-prometheus-stack | Phase 2 ops muscle; watch memory on 16 GB workers |
| kubectl OIDC via Authelia | After ingress path is boring |
| Velero + PVC backup | Before migrating Compose apps off kif |
| CP HA (3 CP nodes) | After etcd restore is routine |
| Longhorn/Ceph | After additional shared disk capacity |

## Explicit non-goals (v1)

- Domain-joining kube nodes
- Idempotent `kubeadm init` in Ansible
- Public NodePort exposure from UniFi
- Migrating Authelia/Plex/Paperless from kif Compose

## Troubleshooting

| Symptom | Check |
|---|---|
| `kubeadm init` fails on swap | `swapon --show`; rerun `k8s-node-prep.yml` |
| `ERROR FileExisting-conntrack` | Rerun `k8s-node-prep.yml` — `k8s_preflight_packages` installs it |
| Warning: sandbox image `""` inconsistent with kubeadm | Cosmetic. kubeadm 1.31 reads `sandboxImage` from the CRI runtime status, which containerd 2.x no longer reports there. Confirm with `containerd config dump \| grep -A2 pinned_images` (expect `sandbox = 'registry.k8s.io/pause:3.10'`) |
| Nodes NotReady | Calico pods, `journalctl -u kubelet` |
| MetalLB VIP unreachable from proxy01 | UniFi firewall VLAN 1→9, ARP on VLAN 9 |
| Ingress 502 from proxy01 | `kubectl get svc -n ingress-nginx`, VIP matches pool |
| DNS failures in pods | Node `/etc/resolv.conf`; Pi-hole or DC reachability from VLAN 9 |
| NFS PVC mount fails | kif exports, firewall 2049, CSI driver logs |

## References

- [adr/003-home-kubernetes.md](adr/003-home-kubernetes.md)
- [edge-access-model.md](edge-access-model.md)
- [cka-runbook.md](cka-runbook.md) — separate CKA practice VMs on vlan3
- [ROADMAP.md](ROADMAP.md) — Slice 31
