#!/usr/bin/env bash
# Verify Dreamhost DNS API access (dns-list_records).
#
# Usage:
#   DREAMHOST_API_KEY='…' ./scripts/certbot/dreamhost-api-check.sh
#   ./scripts/certbot/dreamhost-api-check.sh /etc/letsencrypt/dreamhost.env
set -euo pipefail

ENV_FILE="${1:-}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: ${0} [/etc/letsencrypt/dreamhost.env]"
  exit 0
fi

if [[ -n "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

: "${DREAMHOST_API_KEY:?Set DREAMHOST_API_KEY or pass env file}"

unique_id="$(uuidgen)"
tmp_body="$(mktemp)"
trap 'rm -f "${tmp_body}"' EXIT

http_code="$(
  curl -sS -G "https://api.dreamhost.com/" \
    --data-urlencode "key=${DREAMHOST_API_KEY}" \
    --data-urlencode "cmd=dns-list_records" \
    --data-urlencode "format=json" \
    --data-urlencode "unique_id=${unique_id}" \
    -o "${tmp_body}" \
    -w '%{http_code}'
)"

response="$(cat "${tmp_body}")"
echo "http_code=${http_code}"
if command -v python3 >/dev/null 2>&1; then
  printf '%s\n' "${response}" | python3 -m json.tool 2>/dev/null || printf '%s\n' "${response}"
else
  printf '%s\n' "${response}"
fi

if [[ "${http_code}" != "200" ]]; then
  echo "error: Dreamhost API HTTP ${http_code}" >&2
  exit 1
fi

if ! grep -q '"result"[[:space:]]*:[[:space:]]*"success"' <<<"${response}"; then
  echo "error: Dreamhost dns-list_records returned non-success" >&2
  exit 1
fi

echo "ok: Dreamhost dns-list_records succeeded"
