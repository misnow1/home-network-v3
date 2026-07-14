# Managed by Ansible (linux_baseline). Requires pyenv git install.
export PYENV_ROOT="/usr/local/lib/pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init - zsh)"
fi
