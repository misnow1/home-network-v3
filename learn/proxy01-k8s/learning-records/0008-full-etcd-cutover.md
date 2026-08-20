# Full etcd cutover restore succeeded on prod

Completed single-CP stacked etcd cutover on `k8s-cp01` (2026-08-18): fresh snapshot
`etcd-pre-cutover-2026-08-17-1419.db`, post-snapshot canary ConfigMap, stopped
apiserver then etcd manifests, restored into `/var/lib/etcd` with kubeadm member
identity (`k8s-cp01.home.2123studios.com` / `192.168.9.10:2380`), brought etcd then
apiserver back. `kubectl get --raw=/readyz` and `kubectl get nodes` healthy;
`etcd-cutover-canary` NotFound. Pre-cutover data left at
`/var/lib/etcd.pre-cutover-bak-2026-08-17` for now.

## Implications
Phase 8 graduation gate cleared. Phase 9 Uptime Kuma is unblocked. Optional cleanup:
remove the `.pre-cutover-bak-*` directory when disk reclaim is desired.
