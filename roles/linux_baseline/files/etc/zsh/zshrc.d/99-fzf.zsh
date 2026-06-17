# Managed by Ansible (linux_baseline). Requires fzf 0.48+ from GitHub release.
if command -v fzf >/dev/null 2>&1; then
  eval "$(fzf --zsh)"
fi
