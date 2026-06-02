#!/usr/bin/env bash
# Download Ubuntu 24.04 cloud image for lab VMs if missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

IMAGE_NAME="noble-server-cloudimg-amd64.img"
IMAGE_URL="${LAB_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

main() {
  "${ROOT}/scripts/lab/dirs-ensure.sh" >/dev/null

  local image_dir image_path
  image_dir="$(lab_images_dir)"
  image_path="$(lab_cloud_image_path)"

  require_cmd curl
  mkdir -p "${image_dir}"

  if [[ -f "${image_path}" ]]; then
    log_info "Cloud image present: ${image_path}"
    return 0
  fi

  log_info "Downloading Ubuntu 24.04 cloud image to ${image_path} (this may take a few minutes)"
  curl -fL --progress-bar "${IMAGE_URL}" -o "${image_path}.partial"
  mv "${image_path}.partial" "${image_path}"
  chmod 664 "${image_path}" 2>/dev/null || true
  log_info "Saved cloud image to ${image_path}"
}

main "$@"
