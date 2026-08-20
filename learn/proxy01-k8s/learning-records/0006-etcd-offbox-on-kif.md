# etcd snapshot + pki copied off-box to kif

Off-box copies landed on kif under `/archive/backup/`:
`etcd-2026-08-12.db` (~12M) and `k8s-pki-2026-08-12.tgz` (~20K), owned by
misnow1. On-box save + off-box copy complete; Phase 8 gate still needs a
restore drill before Uptime Kuma.
