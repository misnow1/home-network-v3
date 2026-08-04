# Managed by Ansible (k8s_node). kubectl tab completion — kubernetes.io docs.
if [ -n "${BASH_VERSION:-}" ]; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  fi
  if [ -r /etc/bash_completion.d/kubectl ]; then
    . /etc/bash_completion.d/kubectl
  fi
fi
