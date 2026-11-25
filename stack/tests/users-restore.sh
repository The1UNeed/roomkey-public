#!/usr/bin/env bash
# A backup restore never brings back the archive's panel users: the store that
# was here stays, and on a rebuilt server the archive's panel users are
# dropped until the panel sends its list.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/users.sh"
source "$PSM_ROOT/lib/backup.sh"
fail() { echo "users-restore: $*" >&2; exit 1; }
mkdir -p "$CFG_DIR"

[[ "$USERS_LOCK_FILE" == "$tmp_dir/.psm-users.lock" ]] || fail "the user lock is inside the config directory: $USERS_LOCK_FILE"

archive='{"revision":5,"revision_fp":"r5","applied_fp":"old","users":[{"name":"local","managed":false},{"name":"alice","managed":true,"enabled":true},{"name":"revoked","managed":true,"enabled":true}]}'
current='{"revision":9,"revision_fp":"r9","applied_fp":"now","users":[{"name":"local","managed":false},{"name":"alice","managed":true,"enabled":true}]}'

# a store was here: it stays (revision 9, no "revoked"), and the cores take it again
printf '%s\n' "$archive" >"$USERS_FILE"   # what restoring the PSM config just put there
_restore_users_store "$current"
jq -e '.revision == 9 and ([.users[].name] == ["local","alice"]) and (has("applied_fp") | not)' "$USERS_FILE" >/dev/null \
    || fail "existing store: $(cat "$USERS_FILE")"

# a rebuilt server: the archive's panel users are dropped until the panel sends its list
printf '%s\n' "$archive" >"$USERS_FILE"
_restore_users_store ""
jq -e '([.users[].name] == ["local"]) and (has("revision") | not) and (has("applied_fp") | not)' "$USERS_FILE" >/dev/null \
    || fail "rebuilt server: $(cat "$USERS_FILE")"

# no store at all: nothing is made
rm -f "$USERS_FILE"
_restore_users_store ""
[[ ! -e "$USERS_FILE" ]] || fail "a store appeared from nothing"

# relay rules: the archive's never come back (doctor --fix would start them)
[[ "$RELAY_STORE_FILE" == "$CFG_DIR/realm/rules.json" ]] || fail "relay store path: $RELAY_STORE_FILE"
mkdir -p "$CFG_DIR/realm"
printf '[{"tag":"old","port":30001}]\n' >"$RELAY_STORE_FILE"   # restored from the archive
_restore_relay_store '[]'
jq -e 'length == 0' "$RELAY_STORE_FILE" >/dev/null || fail "existing empty relay store: $(cat "$RELAY_STORE_FILE")"
printf '[{"tag":"old","port":30001}]\n' >"$RELAY_STORE_FILE"
_restore_relay_store ""
jq -e 'length == 0' "$RELAY_STORE_FILE" >/dev/null || fail "rebuilt server kept the archive's relays: $(cat "$RELAY_STORE_FILE")"
rm -rf "$CFG_DIR/realm"
_restore_relay_store ""
[[ ! -e "$RELAY_STORE_FILE" ]] || fail "a relay store appeared from nothing"

# a restore that did not finish keeps every core from starting until it is redone
mkdir -p "$tmp_dir/.psm-restore" && : >"$tmp_dir/.psm-restore/incomplete"
if psm_users_merge xray >/dev/null 2>&1; then fail "a core start passed with a restore unfinished"; fi
if _users_cmd_import --json <<<'{"revision":3,"users":[]}' >/dev/null 2>&1; then fail "a user import was taken with a restore unfinished"; fi
rm -rf "$tmp_dir/.psm-restore"

# the kept stores: a first try keeps what is here, a retry takes what was kept, success clears them
printf '%s\n' "$current" >"$USERS_FILE"
mkdir -p "$(dirname "$RELAY_STORE_FILE")"; printf '[]\n' >"$RELAY_STORE_FILE"
( _restore_keep_begin ) || fail "keep: begin"
[[ -e "$RESTORE_KEEP/incomplete" ]] || fail "keep: no marker"
printf '%s\n' "$archive" >"$USERS_FILE"   # the restore's copy lands, then fails
( _restore_keep_begin; [[ "$RESTORE_CUR_USERS" == *'"revision":9'* ]] ) || fail "keep: a retry did not take the kept store"
( _restore_keep_begin && _restore_keep_end ) || fail "keep: end"
[[ ! -e "$RESTORE_KEEP" ]] && jq -e '.revision == 9' "$USERS_FILE" >/dev/null || fail "keep: after success: $(cat "$USERS_FILE")"

echo "ok: users and relay rules after a restore"
