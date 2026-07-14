# Managed by Ansible (linux_baseline). Requires uv from GitHub release.
if command -v uv >/dev/null 2>&1; then
  eval "$(uv generate-shell-completion zsh)"
fi
