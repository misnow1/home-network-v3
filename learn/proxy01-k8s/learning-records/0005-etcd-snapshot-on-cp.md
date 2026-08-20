# Manual etcd snapshot succeeded on k8s-cp01

Took `/var/backups/etcd-2026-08-12.db` (~12 MB) with etcdctl after installing
`etcd-client`. On-box save works; off-box copy of snapshot + pki and restore
drill remain for the Phase 8 gate.
