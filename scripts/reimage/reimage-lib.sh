#!/usr/bin/env bash
# Shared helpers for kif/kvm01 reimage scripts (Slice 19).
set -euo pipefail

reimage_repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}

reimage_default_staging_dir() {
  local host_label="${1:-$(hostname -s)}"
  local base="/archive"
  if [[ -d "${base}" ]] && [[ -w "${base}" ]]; then
    printf '/archive/pre-reimage-%s-%s' "${host_label}" "$(date +%Y-%m-%d)"
  else
    printf '/var/tmp/pre-reimage-%s-%s' "${host_label}" "$(date +%Y-%m-%d)"
  fi
}

reimage_staging_writable() {
  local staging="$1"
  local parent
  parent="$(dirname "${staging}")"
  [[ -d "${parent}" ]] && [[ -w "${parent}" ]]
}

reimage_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo): $*" >&2
    exit 1
  fi
}

reimage_mkdir_staging() {
  local staging="$1"
  mkdir -p "${staging}"/{config,config/network,libvirt/domains,libvirt/networks,libvirt/pools,docker,samba,nut,wsdd}
}

reimage_capture_storage() {
  local staging="$1"
  {
    echo "# captured $(date -Iseconds) on $(hostname -f)"
    lsblk -f
    echo "---"
    pvs 2>/dev/null || true
    echo "---"
    vgs 2>/dev/null || true
    echo "---"
    lvs 2>/dev/null || true
    echo "---"
    df -hT
    echo "---"
    blkid
  } > "${staging}/config/storage.txt"
}

reimage_capture_libvirt() {
  local staging="$1"
  if ! command -v virsh >/dev/null 2>&1; then
    echo "virsh not installed — skipping libvirt capture" >&2
    return 0
  fi
  virsh list --all > "${staging}/libvirt/domains-list.txt" 2>&1 || true
  virsh net-list --all > "${staging}/libvirt/networks-list.txt" 2>&1 || true
  virsh pool-list --all > "${staging}/libvirt/pools-list.txt" 2>&1 || true

  local name
  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -z "${name}" ]] && continue
    virsh dumpxml --inactive "${name}" > "${staging}/libvirt/domains/${name}.xml" 2>/dev/null \
      || virsh dumpxml "${name}" > "${staging}/libvirt/domains/${name}.xml" 2>/dev/null \
      || echo "warn: could not dumpxml domain ${name}" >&2
  done < <(virsh list --all --name 2>/dev/null | awk 'NF { print $1 }')

  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -z "${name}" ]] && continue
    virsh net-dumpxml "${name}" > "${staging}/libvirt/networks/${name}.xml" 2>/dev/null \
      || echo "warn: could not dumpxml network ${name}" >&2
  done < <(virsh net-list --all --name 2>/dev/null | awk 'NF { print $1 }')

  while IFS= read -r name; do
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"
    [[ -z "${name}" ]] && continue
    virsh pool-dumpxml "${name}" > "${staging}/libvirt/pools/${name}.xml" 2>/dev/null \
      || echo "warn: could not dumpxml pool ${name}" >&2
  done < <(virsh pool-list --all --name 2>/dev/null | awk 'NF { print $1 }')
}

reimage_capture_docker() {
  local staging="$1"
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not installed — skipping docker capture" >&2
    return 0
  fi
  docker ps -a > "${staging}/docker/ps-a.txt" 2>&1 || true
  docker volume ls > "${staging}/docker/volumes-ls.txt" 2>&1 || true
  docker compose ls > "${staging}/docker/compose-ls.txt" 2>&1 || true
  docker volume ls -q | xargs -r docker volume inspect > "${staging}/docker/volumes.json" 2>&1 || true
}

reimage_capture_config_common() {
  local staging="$1"
  cp -a /etc/fstab "${staging}/config/" 2>/dev/null || true
  cp -a /etc/exports "${staging}/config/" 2>/dev/null || true
  cp -a /etc/auto.master "${staging}/config/" 2>/dev/null || true
  cp -a /etc/auto.home "${staging}/config/" 2>/dev/null || true
  cp -a /etc/auto.misc "${staging}/config/" 2>/dev/null || true
  cp -a /etc/cron.d "${staging}/config/" 2>/dev/null || true
  cp -a /etc/cron.daily "${staging}/config/" 2>/dev/null || true
  reimage_capture_network "${staging}"
}

reimage_capture_network() {
  local staging="$1"
  local net_dir="${staging}/config/network"
  mkdir -p "${net_dir}"

  ip -br link > "${net_dir}/ip-br-link.txt" 2>&1 || true
  ip -br addr > "${net_dir}/ip-br-addr.txt" 2>&1 || true
  ip route show > "${net_dir}/ip-route.txt" 2>&1 || true

  if command -v nmcli >/dev/null 2>&1; then
    nmcli -f NAME,UUID,TYPE,DEVICE,STATE con show > "${net_dir}/nmcli-con-show.txt" 2>&1 || true
    nmcli con show > "${net_dir}/nmcli-con-show-full.txt" 2>&1 || true
    while IFS= read -r con; do
      [[ -z "${con}" ]] && continue
      safe_name="$(echo "${con}" | tr ' /' '__')"
      nmcli con show "${con}" > "${net_dir}/nmcli-con-${safe_name}.txt" 2>&1 || true
    done < <(nmcli -t -f NAME con show 2>/dev/null | sed '/^$/d')
  fi

  if [[ -d /etc/NetworkManager/system-connections ]]; then
    cp -a /etc/NetworkManager/system-connections "${net_dir}/" 2>/dev/null || true
  fi
  if [[ -d /etc/sysconfig/network-scripts ]]; then
    cp -a /etc/sysconfig/network-scripts "${net_dir}/" 2>/dev/null || true
  fi
  if [[ -d /etc/netplan ]]; then
    cp -a /etc/netplan "${net_dir}/" 2>/dev/null || true
  fi
  if [[ -f /etc/qemu/bridge.conf ]]; then
    cp -a /etc/qemu/bridge.conf "${net_dir}/" 2>/dev/null || true
  fi
}

reimage_capture_kif_services() {
  local staging="$1"
  mkdir -p "${staging}/samba/pam.d" "${staging}/nut/udev"

  cp -a /etc/samba/smb.conf "${staging}/samba/" 2>/dev/null || true
  cp -a /etc/krb5.conf "${staging}/samba/" 2>/dev/null || true
  cp -a /etc/krb5.keytab "${staging}/samba/" 2>/dev/null || true
  cp -a /etc/nsswitch.conf "${staging}/samba/" 2>/dev/null || true
  cp -a /etc/pam.d/. "${staging}/samba/pam.d/" 2>/dev/null || true
  cp -a /var/lib/samba/private "${staging}/samba/" 2>/dev/null || true

  if command -v net >/dev/null 2>&1; then
    net ads testjoin -P > "${staging}/samba/testjoin.txt" 2>&1 || true
    net ads info > "${staging}/samba/ads-info.txt" 2>&1 || true
  fi
  if command -v wbinfo >/dev/null 2>&1; then
    wbinfo -u | head -20 > "${staging}/samba/wbinfo-users-sample.txt" 2>&1 || true
  fi

  cp -a /etc/nut "${staging}/nut/" 2>/dev/null || true
  cp -a /etc/udev/rules.d/*nut* "${staging}/nut/udev/" 2>/dev/null || true
  cp -a /etc/udev/rules.d/*ups* "${staging}/nut/udev/" 2>/dev/null || true
  systemctl list-units 'nut-*' --all > "${staging}/nut/systemd-units.txt" 2>&1 || true
  if command -v upsc >/dev/null 2>&1; then
    upsc -l > "${staging}/nut/upsc-l.txt" 2>&1 || true
    local ups
    while IFS= read -r ups; do
      [[ -z "${ups}" ]] && continue
      upsc "${ups}" > "${staging}/nut/upsc-$(echo "${ups}" | tr '/@' '__').txt" 2>/dev/null || true
    done < <(upsc -l 2>/dev/null | sed '/^$/d')
  fi
  command -v nut-scanner >/dev/null && nut-scanner -U > "${staging}/nut/nut-scanner.txt" 2>&1 || true
  lsusb >> "${staging}/nut/lsusb.txt" 2>&1 || true

  mkdir -p "${staging}/wsdd"
  systemctl cat wsdd wsdd2 2>/dev/null > "${staging}/wsdd/systemd.txt" || true
  cp -a /etc/wsdd.conf "${staging}/wsdd/" 2>/dev/null || true
}

reimage_write_manifest() {
  local staging="$1"
  local host_label="$2"
  {
    echo "host=${host_label}"
    echo "fqdn=$(hostname -f 2>/dev/null || hostname)"
    echo "captured=$(date -Iseconds)"
    echo "staging=${staging}"
    echo "tier=1"
    if [[ "${staging}" != /archive/* ]]; then
      echo "rsync_hint=rsync -av ${staging}/ kif:/archive/pre-reimage-${host_label}-$(date +%Y-%m-%d)/"
    fi
    du -sh "${staging}"/* 2>/dev/null || true
  } > "${staging}/MANIFEST.txt"
}
