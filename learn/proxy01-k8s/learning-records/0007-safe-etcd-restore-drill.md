# Safe etcd restore drill succeeded (prod, no cutover)

Verified off-box snapshot `/archive/backup/etcd-2026-08-12.db` (hash ea60f78d,
revision 3272676, 1782 keys): status on kif and on staged CP copy matched; restored
into `/var/lib/etcd-restore-drill` on k8s-cp01 (73M, member/snap+wal); live
`/var/lib/etcd` and `etcd.yaml` (`--data-dir=/var/lib/etcd`) untouched; `kubectl get
nodes` remained healthy. Throwaway dirs cleaned; kif archive retained.

## Implications
Partial Phase 8 gate cleared. Full cutover restore drill still required before
Uptime Kuma / graduation apps per runbook ADR wording.
