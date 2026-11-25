#!/usr/bin/env bash
# An inbound PSM did not make (a direct Xray install's own) is never dropped by
# a node change: the rebuild that would remove it is undone, store and config.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"; XRAY_CFG_DIR="$tmp_dir/xray"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
mkdir -p "$CFG_DIR" "$XRAY_CFG_DIR"
source "$PSM_ROOT/lib/node_cli.sh"
fail() { echo "xray-unmanaged: $*" >&2; exit 1; }

before='{"inbounds":[{"tag":"handmade","port":443,"protocol":"vless","streamSettings":{"network":"tcp","security":"reality"}},
                     {"tag":"old-psm","port":8443,"protocol":"vless"},{"tag":"api","port":10085}]}'
after='{"inbounds":[{"tag":"panel","port":2443,"protocol":"vless"},{"tag":"api","port":10085}]}'
printf '%s\n' "$before" >"$tmp_dir/before.json"; printf '%s\n' "$after" >"$tmp_dir/after.json"
# old-psm was a PSM node (the old store), panel is the new one: only handmade is lost
lost=$(_node_cli_lost_inbounds xray "$tmp_dir/before.json" "$tmp_dir/after.json" '[{"tag":"old-psm"}]' '[{"tag":"panel"}]')
[[ "$lost" == handmade ]] || fail "lost: got '$lost'"
# another protocol's node is not the edited store's either: losing it is refused too
printf '%s\n' '{"inbounds":[{"tag":"reality-xhttp"},{"tag":"friends"}]}' >"$tmp_dir/b2.json"
printf '%s\n' '{"inbounds":[{"tag":"friends"}]}' >"$tmp_dir/a2.json"
lost=$(_node_cli_lost_inbounds xray "$tmp_dir/b2.json" "$tmp_dir/a2.json" '[]' '[{"tag":"friends"}]')
[[ "$lost" == reality-xhttp ]] || fail "another store's node lost: got '$lost'"
lost=$(_node_cli_lost_inbounds xray "$tmp_dir/before.json" "$tmp_dir/before.json" '[]' '[]')
[[ -z "$lost" ]] || fail "nothing lost: got '$lost'"

# a change whose rebuild drops it is undone: the store and the live config as they were
printf '%s\n' "$before" >"$XRAY_CFG_DIR/config.json"
XRAY_BIN="$tmp_dir/xray-bin"; printf '#!/bin/sh\n' >"$XRAY_BIN"; chmod +x "$XRAY_BIN"
: >"$tmp_dir/module.sh"
_node_cli_module_path() { printf '%s' "$tmp_dir/module.sh"; }
_node_cli_live_cfg() { printf '%s' "$XRAY_CFG_DIR/config.json"; }
_node_cli_core_bin() { printf '%s' "$XRAY_BIN"; }
_node_cli_apply_fn() { printf fake_apply; }
_node_cli_restart_old_cfg() { echo restarted-old >>"$tmp_dir/log"; }
_node_cli_core_restart() { echo "restart $(jq -c '[.inbounds[].tag]' "$XRAY_CFG_DIR/config.json")" >>"$tmp_dir/log"; }
: >"$tmp_dir/log"
fake_apply() { printf '%s\n' "$after" >"$XRAY_CFG_DIR/config.json"; }
store=$(_node_cli_store_path xray reality)
mkdir -p "$(dirname "$store")"; printf '[{"tag":"old-psm"}]\n' >"$store"
if _node_cli_commit_store xray reality '[{"tag":"panel"}]' 0 2>/dev/null; then fail "the change went ahead over a hand-made inbound"; fi
jq -e '[.inbounds[].tag] == ["handmade","old-psm","api"]' "$XRAY_CFG_DIR/config.json" >/dev/null || fail "config not restored: $(cat "$XRAY_CFG_DIR/config.json")"
jq -e '[.[].tag] == ["old-psm"]' "$store" >/dev/null || fail "store not restored: $(cat "$store")"
[[ ! -s "$tmp_dir/log" ]] || fail "something restarted with the refused config: $(cat "$tmp_dir/log")"
# without the hand-made inbound the same change goes through, restarted once with the new config
printf '%s\n' '{"inbounds":[{"tag":"old-psm","port":8443},{"tag":"api","port":10085}]}' >"$XRAY_CFG_DIR/config.json"
_node_cli_commit_store xray reality '[{"tag":"panel"}]' 0 2>/dev/null || fail "an ordinary change was refused"
[[ "$(cat "$tmp_dir/log")" == 'restart ["panel","api"]' ]] || fail "restart: $(cat "$tmp_dir/log")"

# a live config that is a relative symlink: compared and put back through the link
: >"$tmp_dir/log"
mkdir -p "$tmp_dir/real"; printf '%s\n' "$before" >"$tmp_dir/real/xray.json"
rm -f "$XRAY_CFG_DIR/config.json"; ln -s ../real/xray.json "$XRAY_CFG_DIR/config.json"
fake_apply() { printf '%s\n' "$after" >"$XRAY_CFG_DIR/config.json"; }
printf '[{"tag":"old-psm"}]\n' >"$store"
if _node_cli_commit_store xray reality '[{"tag":"panel"}]' 0 2>/dev/null; then fail "symlinked config: the change went ahead"; fi
[[ -L "$XRAY_CFG_DIR/config.json" ]] || fail "symlinked config: the link was replaced"
jq -e '[.inbounds[].tag] | index("handmade") != null' "$tmp_dir/real/xray.json" >/dev/null || fail "symlinked config: not restored"
rm -f "$XRAY_CFG_DIR/config.json"

# a new node cannot take the tag of a listener PSM did not make
printf '%s\n' "$before" >"$XRAY_CFG_DIR/config.json"
if _node_cli_check_tag_unique xray trojan handmade 2>/dev/null; then fail "a new node took a hand-made listener's tag"; fi
_node_cli_check_tag_unique xray trojan fresh-tag 2>/dev/null || fail "a free tag was refused"

echo "ok: hand-made inbounds are never dropped by a node change"
