#!/usr/bin/env bash
# A core that rolls back is tried again: the next import (even of the same
# list) restarts it, and only a core that took the list counts as applied.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# a copy of lib/ whose Xray "restart" fails while $tmp_dir/fail exists
cp -R "$PSM_ROOT/lib" "$tmp_dir/lib"
cat > "$tmp_dir/lib/xray/core.sh" <<EOF
xray_test_restart() { echo restart >> "$tmp_dir/restarts"; [[ ! -f "$tmp_dir/fail" ]]; }
EOF
source "$PSM_ROOT/lib/common.sh"
# shellcheck disable=SC2034  # read by the sourced library
LIB_DIR="$tmp_dir/lib"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034  # read by the sourced library
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/users.sh"
USERS_FILE="$CFG_DIR/users.json"
XRAY_BIN="$tmp_dir/xray"; XRAY_CFG_DIR="$tmp_dir/xray-cfg"
mkdir -p "$XRAY_CFG_DIR"; echo '{}' > "$XRAY_CFG_DIR/config.json"; printf '#!/bin/sh\nexit 0\n' > "$XRAY_BIN"; chmod +x "$XRAY_BIN"
_users_core_installed() { [[ "$1" == xray ]]; }

fail() { echo "users-apply-retry: $*" >&2; exit 1; }
restarts() { wc -l < "$tmp_dir/restarts" 2>/dev/null | tr -d ' ' || echo 0; }
list='{"revision": 1, "users":[{"name":"bob","uuid":"11111111-2222-4333-8444-555555555555","password":"bobpass12345","nodes":["*"],"enabled":true,"period":"p"}]}'

touch "$tmp_dir/fail"
out=$(_users_cmd_import --json <<<"$list" 2>/dev/null) || true
jq -e '.ok == false and .applied == true' <<<"$out" >/dev/null || fail "a failed core must make the import not ok: $out"
[[ "$(restarts)" == 1 ]] || fail "one restart expected, got $(restarts)"
jq -e '(.applied_fp // {}) | has("xray") | not' "$USERS_FILE" >/dev/null || fail "a core that rolled back must not count as applied"

# the same list again: the core is behind, so it is restarted again
rm -f "$tmp_dir/fail"
out=$(_users_cmd_import --json <<<"$list")
jq -e '.ok == true and .applied == true' <<<"$out" >/dev/null || fail "retry: $out"
[[ "$(restarts)" == 2 ]] || fail "the retry did not restart the core ($(restarts) restarts)"
jq -e '.applied_fp.xray | length == 16' "$USERS_FILE" >/dev/null || fail "applied fingerprint"

# and once applied, the same list again restarts nothing
out=$(_users_cmd_import --json <<<"$list")
jq -e '.applied == false' <<<"$out" >/dev/null || fail "nothing pending, yet: $out"
[[ "$(restarts)" == 2 ]] || fail "an unchanged list restarted the core"

echo "ok: a core that rolled back is applied again"
