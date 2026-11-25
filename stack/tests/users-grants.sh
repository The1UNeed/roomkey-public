#!/usr/bin/env bash
# A grant that names its core ("xray/hk") reaches that core's node only: a node
# of the same name on another core (made by hand there) does not get the user.
# A plain tag (psm user, by hand) still means that tag on every core.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
XRAY_CFG_DIR="$tmp_dir/xray"; SINGBOX_CFG_DIR="$tmp_dir/sing-box"
mkdir -p "$CFG_DIR" "$XRAY_CFG_DIR" "$SINGBOX_CFG_DIR"
source "$PSM_ROOT/lib/users.sh"
USERS_FILE="$CFG_DIR/users.json"
fail() { echo "users-grants: $*" >&2; exit 1; }

xray_cfg='{"inbounds":[{"tag":"hk","protocol":"trojan","settings":{"clients":[{"password":"ownerpass"}]}}]}'
sb_cfg='{"inbounds":[{"tag":"hk","type":"trojan","users":[{"password":"ownerpass"}]}]}'
U='11111111-2222-4333-8444-555555555555'

run() {   # <alice's nodes JSON> → "<xray has alice> <sing-box has alice>"
    printf '%s\n' "$xray_cfg" >"$XRAY_CFG_DIR/config.json"
    printf '%s\n' "$sb_cfg" >"$SINGBOX_CFG_DIR/config.json"
    printf '{"users":[{"name":"alice","uuid":"%s","password":"alicepass123","nodes":%s,"enabled":true,"managed":true}]}\n' "$U" "$1" >"$USERS_FILE"
    psm_users_inject xray >/dev/null 2>&1 || fail "xray merge failed"
    psm_users_inject sing-box >/dev/null 2>&1 || fail "sing-box merge failed"
    printf '%s %s\n' \
        "$(jq '[.inbounds[0].settings.clients[] | select(.password == "alicepass123")] | length' "$XRAY_CFG_DIR/config.json")" \
        "$(jq '[.inbounds[0].users[] | select(.password == "alicepass123")] | length' "$SINGBOX_CFG_DIR/config.json")"
}
out=$(run '["xray/hk"]');     [[ "$out" == "1 0" ]] || fail "xray/hk: got '$out' (want xray only)"
out=$(run '["sing-box/hk"]'); [[ "$out" == "0 1" ]] || fail "sing-box/hk: got '$out' (want sing-box only)"
out=$(run '["hk"]');          [[ "$out" == "1 1" ]] || fail "plain hk: got '$out' (want both, as before)"
out=$(run '["mihomo/hk"]');   [[ "$out" == "0 0" ]] || fail "mihomo/hk: got '$out' (want neither)"

# the import takes core/tag grants, and nothing else with a slash
ok=$(_users_cmd_import --json <<<'{"users":[{"name":"bob","uuid":"'"$U"'","password":"bobpass12345","nodes":["xray/hk"]}]}' 2>/dev/null | jq -r '.ok // false') || true
[[ "$ok" == true ]] || fail "an import with xray/hk was refused"
if _users_cmd_import --json <<<'{"users":[{"name":"bob","uuid":"'"$U"'","password":"bobpass12345","nodes":["other/hk"]}]}' >/dev/null 2>&1; then
    fail "an import with other/hk was taken"
fi

# psm user links: a core/tag grant gives that core's node's link, not another core's
source "$PSM_ROOT/lib/node_cli.sh"
# (the configs above hold hand-made "hk" listeners, which a new node of that name may not take)
rm -f "$XRAY_CFG_DIR/config.json" "$SINGBOX_CFG_DIR/config.json"
psm_node_cli node add xray trojan --tag hk --port 31100 --domain hk.example.com --password 'ownerpass123' --store-only --json >/dev/null 2>&1 || fail "store-only trojan node"
alice='{"name":"alice","uuid":"'"$U"'","password":"alicepass123","nodes":["xray/hk"]}'
[[ "$(_users_links "$alice" 203.0.113.1 | grep -c '^trojan://' || true)" == 1 ]] || fail "psm user links: xray/hk gave no link"
alice='{"name":"alice","uuid":"'"$U"'","password":"alicepass123","nodes":["sing-box/hk"]}'
[[ "$(_users_links "$alice" 203.0.113.1 | grep -c '^trojan://' || true)" == 0 ]] || fail "psm user links: sing-box/hk gave the xray node's link"

echo "ok: grants by core"
