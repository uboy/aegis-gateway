#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAILED: $1" >&2
  exit 1
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" && fail "pattern '$pattern' unexpectedly found in $file"
  return 0
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  grep -Eq "$pattern" "$file" || fail "pattern '$pattern' not found in $file"
}

# --- Regression guards: fabricated/unsafe behavior must not come back ---

assert_not_contains 'allow-skip-dh' "${ROOT_DIR}/modules/mtproto.sh"
assert_not_contains 'nat-info' "${ROOT_DIR}/modules/mtproto.sh"
assert_not_contains 'PORT_MTPROXY:-443' "${ROOT_DIR}/modules/mtproto.sh"
assert_not_contains 'PORT_MTPROXY:-443' "${ROOT_DIR}/install.sh"
assert_not_contains 'PORT_MTPROXY:-443' "${ROOT_DIR}/lib/ui.sh"
assert_not_contains 'releases/latest' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'MTPROXY_TELEPROXY_VERSION' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'SHA256SUMS' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'sha256sum' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mtproxy-rollback' "${ROOT_DIR}/modules/mtproto.sh"

# The destructive rm of the live install must happen strictly after the
# checksum verification, not before it (a failed download/checksum must never
# be able to wipe a working install).
_checksum_line=$(grep -n 'Проверка целостности' "${ROOT_DIR}/modules/mtproto.sh" | head -1 | cut -d: -f1)
_destructive_rm_line=$(grep -n 'rm -rf "\$mt_repo_dir" "\$mt_conf_dir"$' "${ROOT_DIR}/modules/mtproto.sh" | head -1 | cut -d: -f1)
[[ -n "$_checksum_line" && -n "$_destructive_rm_line" ]] || fail "could not locate checksum-check or destructive-rm lines to order-check"
(( _checksum_line < _destructive_rm_line )) || fail "destructive rm of the live install happens before (or without) checksum verification"
assert_not_contains '"mtg\|mtproxy"' "${ROOT_DIR}/lib/ui.sh"

# --- Regression guards: required fixes must stay in place ---

assert_contains 'resolve_var PORT_MTPROXY *"8443"' "${ROOT_DIR}/install.sh"
assert_contains 'resolve_var MTPROXY_DOMAIN' "${ROOT_DIR}/install.sh"
assert_contains 'CAP_NET_BIND_SERVICE' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'ui_get_mtproto_domain' "${ROOT_DIR}/install.sh"
assert_contains 'ui_get_mtproto_domain\(\)' "${ROOT_DIR}/lib/ui.sh"
assert_contains 'pick_free_port_from_candidates' "${ROOT_DIR}/lib/utils.sh"
assert_contains 'pick_free_port_from_candidates' "${ROOT_DIR}/install.sh"
assert_contains 'hex_decode_ascii' "${ROOT_DIR}/lib/utils.sh"
assert_contains 'teleproxy' "${ROOT_DIR}/lib/ui.sh"

# --- Regression guards: client proxy-link must use the real public host,
# never the Fake-TLS masking domain (MTPROXY_DOMAIN) ---

assert_contains 'mtproto_proxy_link_tg' "${ROOT_DIR}/lib/utils.sh"
assert_contains 'mtproto_proxy_link_https' "${ROOT_DIR}/lib/utils.sh"
assert_contains 'mtproto_proxy_link_tg' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mtproto_proxy_link_https' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mtproto_proxy_link_tg "\$mt_public_host"' "${ROOT_DIR}/modules/mtproto.sh"
assert_not_contains 'mtproto_proxy_link_(tg|https) "\$mt_domain"' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mt_public_host="\$\{DOMAIN:-\}"' "${ROOT_DIR}/modules/mtproto.sh"
assert_contains 'mtproto_proxy_link_tg' "${ROOT_DIR}/lib/ui.sh"

# --- Unit tests for the pure helpers in lib/utils.sh ---

# Provide the small set of functions utils.sh's own definitions don't need
# but that would otherwise be undefined when sourcing it standalone.
log() { :; }
warn() { :; }
error() { :; }

source "${ROOT_DIR}/lib/utils.sh"

# hex_decode_ascii round-trips through the same od encoding mtproto.sh uses.
_encoded=$(printf '%s' "www.google.com" | od -An -tx1 | tr -d ' \n')
_decoded=$(hex_decode_ascii "$_encoded")
[[ "$_decoded" == "www.google.com" ]] || fail "hex_decode_ascii round-trip mismatch: got '$_decoded'"

hex_decode_ascii "abc" >/dev/null 2>&1 && fail "hex_decode_ascii accepted odd-length input"

# pick_free_port_from_candidates: skips used ports and busy ports, returns the
# first candidate that is both unused and free.
check_port_free() { [[ "$1" != "9443" ]]; }  # simulate 9443 already listening
declare -A USED_PORTS=([2083]="SomeOtherService")

_picked=$(pick_free_port_from_candidates USED_PORTS 9443 2083 2087 2096)
[[ "$_picked" == "2087" ]] || fail "pick_free_port_from_candidates picked '$_picked', expected 2087"

if pick_free_port_from_candidates USED_PORTS 9443 2083 >/dev/null; then
  fail "pick_free_port_from_candidates should have failed when no candidate is free"
fi

# mtproto_proxy_link_tg / mtproto_proxy_link_https: correct format, and fail
# closed (non-zero, no output) when any required part is missing rather than
# emitting a link with a blank/placeholder field.
_tg=$(mtproto_proxy_link_tg "203.0.113.1" "2083" "ee1122334455667788112233445566778876f6f676c652e636f6d")
[[ "$_tg" == "tg://proxy?server=203.0.113.1&port=2083&secret=ee1122334455667788112233445566778876f6f676c652e636f6d" ]] \
  || fail "mtproto_proxy_link_tg produced unexpected output: '$_tg'"

_https=$(mtproto_proxy_link_https "203.0.113.1" "2083" "ee1122334455667788112233445566778876f6f676c652e636f6d")
[[ "$_https" == "https://t.me/proxy?server=203.0.113.1&port=2083&secret=ee1122334455667788112233445566778876f6f676c652e636f6d" ]] \
  || fail "mtproto_proxy_link_https produced unexpected output: '$_https'"

mtproto_proxy_link_tg "" "2083" "eeSECRET" >/dev/null 2>&1 && fail "mtproto_proxy_link_tg accepted an empty host"
mtproto_proxy_link_tg "203.0.113.1" "" "eeSECRET" >/dev/null 2>&1 && fail "mtproto_proxy_link_tg accepted an empty port"
mtproto_proxy_link_tg "203.0.113.1" "2083" "" >/dev/null 2>&1 && fail "mtproto_proxy_link_tg accepted an empty secret"
mtproto_proxy_link_https "" "2083" "eeSECRET" >/dev/null 2>&1 && fail "mtproto_proxy_link_https accepted an empty host"

echo "MTProto config checks passed."
