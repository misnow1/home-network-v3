# Managed by Ansible (k8s_node). kubectl tab completion — kubernetes.io docs.
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion zsh)
fi
