#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local pattern="$1"
  local file="$2"
  if ! grep -Eq "$pattern" "$file"; then
    echo "ASSERTION FAILED: pattern '$pattern' not found in $file" >&2
    exit 1
  fi
}

[[ -f "${ROOT_DIR}/modules/mtproto.sh" ]] || { echo "Missing modules/mtproto.sh" >&2; exit 1; }

assert_contains 'module_mtproto_install\(\)' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mtproto\.sh' "${ROOT_DIR}/install.sh"
assert_contains 'module_mtproto_install' "${ROOT_DIR}/install.sh"
assert_contains 'PORT_MTPROXY' "${ROOT_DIR}/lib/state.sh"
assert_contains 'INSTALL_MTPROXY' "${ROOT_DIR}/lib/state.sh"
assert_contains 'MTPROXY_SECRET' "${ROOT_DIR}/lib/state.sh"
assert_contains '"MTProto"' "${ROOT_DIR}/lib/ui.sh"
assert_contains 'mtproto_proxy_link_tg' "${ROOT_DIR}/lib/ui.sh"
assert_contains 'tg://proxy\?server=' "${ROOT_DIR}/lib/utils.sh"
assert_contains 'MTProto' "${ROOT_DIR}/README.md"

echo "MTProto smoke checks passed."