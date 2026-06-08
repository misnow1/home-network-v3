#!/usr/bin/env bash
# Download Ubuntu 24.04 cloud image for lab VMs if missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

IMAGE_NAME="noble-server-cloudimg-amd64.img"
IMAGE_BASE_URL="${LAB_IMAGE_BASE_URL:-https://cloud-images.ubuntu.com/noble/current}"
IMAGE_URL="${LAB_IMAGE_URL:-${IMAGE_BASE_URL}/${IMAGE_NAME}}"
CHECKSUM_URL="${LAB_IMAGE_CHECKSUM_URL:-${IMAGE_BASE_URL}/SHA256SUMS}"
# Set LAB_IMAGE_SKIP_CHECKSUM=1 only for an offline mirror without SHA256SUMS.
SKIP_CHECKSUM="${LAB_IMAGE_SKIP_CHECKSUM:-0}"

verify_checksum() {
  local image_path="$1"
  if [[ "${SKIP_CHECKSUM}" == "1" ]]; then
    log_warn "LAB_IMAGE_SKIP_CHECKSUM=1 — skipping cloud image integrity check"
    return 0
  fi
  require_cmd sha256sum
  local expected
  expected="$(curl -fsSL "${CHECKSUM_URL}" | awk -v f="*${IMAGE_NAME}" '$2 == f {print $1}')"
  [[ -n "${expected}" ]] || die "Could not find ${IMAGE_NAME} in ${CHECKSUM_URL}"
  local actual
  actual="$(sha256sum "${image_path}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${image_path}"
    die "Checksum mismatch for ${IMAGE_NAME} (expected ${expected}, got ${actual}) — removed download"
  fi
  log_info "Verified cloud image SHA256 (${expected})"
}

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
  verify_checksum "${image_path}.partial"
  mv "${image_path}.partial" "${image_path}"
  chmod 664 "${image_path}" 2>/dev/null || true
  log_info "Saved cloud image to ${image_path}"
}

main "$@"
