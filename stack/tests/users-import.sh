#!/usr/bin/env bash
# psm user import / usage: the panel's users on an isolated store (no cores, so
# nothing restarts; users_apply only records what it would serve).

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034  # read by the sourced library
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/users.sh"
USERS_FILE="$CFG_DIR/users.json"

fail() { echo "users-import: $*" >&2; exit 1; }

U1='11111111-2222-4333-8444-555555555555'
U2='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'

# a hand-made user, which an import must leave alone
_users_save '{"users":[{"name":"local","uuid":"'"$U2"'","password":"localpass123","token":"t","nodes":["*"],"enabled":true,"used_bytes":7,"used_month":"2026-01"}]}'

out=$(_users_cmd_import --json <<EOF
{"users":[
  {"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"expires_at":null,"quota_bytes":1073741824,"period":"p1"},
  {"name":"bob","uuid":"$U2","password":"bobpass12345","nodes":["vless-1"],"enabled":false,"period":"p1"}
]}
EOF
)
# no core is installed here, so nothing is restarted (users-apply-retry.sh covers that)
jq -e '.status == "imported" and .managed == 2 and .applied == false and .conflicts == []' <<<"$out" >/dev/null || fail "first import: $out"
jq -e '[.users[].name] | sort == ["alice","bob","local"]' "$USERS_FILE" >/dev/null || fail "store after import"
jq -e '.users[] | select(.name == "alice") | .managed == true and .counter_bytes == 0 and .used_bytes == 0 and (.token | length) == 48' "$USERS_FILE" >/dev/null \
    || fail "alice's fields"
jq -e 'map(.name) == ["alice","local"]' <<<"$(_users_served)" >/dev/null || fail "served set: disabled bob must not be served"

# counters are kept across imports; the same period keeps used_bytes
_users_save "$(jq -c '.users |= map(if .name == "alice" then .counter_bytes = 500 | .used_bytes = 300 else . end)' "$USERS_FILE")"
out=$(_users_cmd_import --json <<EOF
{"users":[
  {"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"quota_bytes":1073741824,"period":"p1"},
  {"name":"bob","uuid":"$U2","password":"bobpass12345","nodes":["vless-1"],"enabled":false,"period":"p1"}
]}
EOF
)
jq -e '.applied == false' <<<"$out" >/dev/null || fail "an import that changes nothing served must not restart: $out"
jq -e '.users[] | select(.name == "alice") | .counter_bytes == 500 and .used_bytes == 300' "$USERS_FILE" >/dev/null || fail "kept counters"

# a new period starts used_bytes over, never counter_bytes; a dropped user leaves
out=$(_users_cmd_import --json <<EOF
{"users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"quota_bytes":1073741824,"period":"p2"}]}
EOF
)
jq -e '.users[] | select(.name == "alice") | .counter_bytes == 500 and .used_bytes == 0 and .period == "p2"' "$USERS_FILE" >/dev/null || fail "new period"
jq -e '[.users[].name] | sort == ["alice","local"]' "$USERS_FILE" >/dev/null || fail "bob should have left"

# the monthly rollover of users_check leaves managed users alone
_users_save "$(jq -c '.users |= map(.used_bytes = 42 | .used_month = "1999-01")' "$USERS_FILE")"
users_check
jq -e '.users[] | select(.name == "alice") | .used_bytes == 42' "$USERS_FILE" >/dev/null || fail "managed user reset by the calendar month"
jq -e '.users[] | select(.name == "local") | .used_bytes == 0' "$USERS_FILE" >/dev/null || fail "hand-made user not reset by the month"

# a panel user may not take over a hand-made one of the same name
out=$(_users_cmd_import --json <<EOF
{"users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"quota_bytes":1073741824,"period":"p2"},
          {"name":"local","uuid":"$U1","password":"otherpass123","nodes":["*"],"enabled":true,"period":"p2"}]}
EOF
)
jq -e '.conflicts == ["local"]' <<<"$out" >/dev/null || fail "conflict not reported: $out"
jq -e '.users[] | select(.name == "local") | .password == "localpass123" and (.managed != true)' "$USERS_FILE" >/dev/null || fail "hand-made user taken over"

# bad input changes nothing
before=$(cat "$USERS_FILE")
for bad in '{"users":[{"name":"Bad Name","uuid":"'"$U1"'","password":"alicepass123"}]}' \
           '{"users":[{"name":"x","uuid":"nope","password":"alicepass123"}]}' \
           '{"users":[{"name":"x","uuid":"'"$U1"'","password":"short"}]}' \
           '{"users":[{"name":"x","uuid":"'"$U1"'","password":"alicepass123","nodes":["a;b"]}]}' \
           '{"users":[{"name":"x","uuid":"'"$U1"'","password":"alicepass123"},{"name":"x","uuid":"'"$U1"'","password":"alicepass123"}]}' \
           'not json'; do
    if _users_cmd_import --json <<<"$bad" >/dev/null 2>&1; then fail "accepted bad input: $bad"; fi
done
[[ "$(cat "$USERS_FILE")" == "$before" ]] || fail "bad input changed the store"

# usage: the panel's view of the counters
out=$(_users_cmd_usage --json)
jq -e '.users | map(select(.name == "alice"))[0] | .managed == true and .counter_bytes == 500 and .period == "p2" and .state == "active"' <<<"$out" >/dev/null \
    || fail "usage: $out"

# online without Xray installed: an empty list, not an error
out=$(XRAY_BIN=/nonexistent _users_cmd_online --json)
jq -e '.users == []' <<<"$out" >/dev/null || fail "online: $out"

# ── revisions: a list older than the one taken changes nothing ──
out=$(_users_cmd_import --json <<EOF
{"revision": 7, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"period":"p2"}]}
EOF
)
jq -e '.status == "imported" and .revision == 7' <<<"$out" >/dev/null || fail "revision 7: $out"
before=$(cat "$USERS_FILE")
out=$(_users_cmd_import --json <<EOF
{"revision": 6, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":false,"period":"p2"}]}
EOF
)
jq -e '.status == "stale" and .revision == 7 and .ok == true' <<<"$out" >/dev/null || fail "stale list: $out"
[[ "$(cat "$USERS_FILE")" == "$before" ]] || fail "a stale list changed the store"

# ── the local pause is this server's own: imports keep it, it never touches .enabled ──
_users_cmd_update alice --local-pause --json >/dev/null
jq -e '.users[] | select(.name == "alice") | .local_paused == true and .enabled == true' "$USERS_FILE" >/dev/null || fail "local pause"
jq -e 'map(.name) | index("alice") | not' <<<"$(_users_served)" >/dev/null || fail "a locally paused user must not be served"
epoch=$(jq -r '.users[] | select(.name == "alice") | .counter_epoch' "$USERS_FILE")
[[ "$epoch" =~ ^[0-9]{10}-[A-Za-z0-9]{6}$ ]] || fail "counter epoch (time first, so newer sorts after older): $epoch"
_users_cmd_import --json >/dev/null <<EOF
{"revision": 8, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"period":"p2"}]}
EOF
jq -e --arg e "$epoch" '.users[] | select(.name == "alice") | .local_paused == true and .counter_epoch == $e' "$USERS_FILE" >/dev/null \
    || fail "an import must keep the local pause and the counter epoch"
# resuming here cannot enable a user the panel disabled
_users_cmd_import --json >/dev/null <<EOF
{"revision": 9, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":false,"period":"p2"}]}
EOF
_users_cmd_update alice --local-resume --json >/dev/null
jq -e '.users[] | select(.name == "alice") | (.local_paused | not) and .enabled == false' "$USERS_FILE" >/dev/null || fail "local resume overrode the panel"
jq -e '.users | map(select(.name == "alice"))[0] | .state == "disabled"' <<<"$(_users_cmd_usage --json)" >/dev/null || fail "usage state"
jq -e '.revision == 9 and (.users[] | select(.name == "alice") | .counter_epoch != null)' <<<"$(_users_cmd_usage --json)" >/dev/null || fail "usage revision/epoch"

# another list under a number already taken: refused, the panel numbers above it
out=$(_users_cmd_import --json <<EOF
{"revision": 9, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":true,"period":"p2"}]}
EOF
)
jq -e '.status == "stale" and .revision == 9' <<<"$out" >/dev/null || fail "same revision, other content: $out"
# the same list again under its number: taken (a retry)
out=$(_users_cmd_import --json <<EOF
{"revision": 9, "users":[{"name":"alice","uuid":"$U1","password":"alicepass123","nodes":["*"],"enabled":false,"period":"p2"}]}
EOF
)
jq -e '.status == "imported"' <<<"$out" >/dev/null || fail "same revision, same content: $out"

# purge (the server leaves the panel): panel users go, hand-made ones stay
out=$(_users_cmd_purge --json)
jq -e '.status == "purged" and .removed == 1 and .ok == true' <<<"$out" >/dev/null || fail "purge: $out"
# with the last reading of the users it removed (for the panel's retirement total)
jq -e '.usage.users | map(select(.managed)) | length == 1' <<<"$out" >/dev/null || fail "purge usage: $out"
jq -e '[.users[].name] == ["local"] and (has("revision") | not)' "$USERS_FILE" >/dev/null || fail "after purge"

# the lock fails closed: a writer that cannot get it (a timeout) changes nothing
before=$(cat "$USERS_FILE")
if ( flock() { return 1; }; _USERS_LOCKED=""; _users_cmd_update local --disable --json ) >/dev/null 2>&1; then
    fail "an update went ahead without the lock"
fi
[[ "$(cat "$USERS_FILE")" == "$before" ]] || fail "the store changed without the lock"

# the checkpoint before an Xray restart lets go of the lock when it is done
# (a menu left open must not keep it)
( _USERS_LOCKED=""; psm_users_checkpoint_quiet; [[ -z "${_USERS_LOCKED:-}" ]] ) || fail "the checkpoint kept the lock in its caller"
if command -v flock >/dev/null 2>&1; then
    exec {_USERS_LOCK_FD}>&- 2>/dev/null || true; _USERS_LOCKED=""
    psm_users_checkpoint_quiet
    exec {probe}>"$USERS_LOCK_FILE"; flock -n "$probe" || fail "the lock is still held after the checkpoint"; exec {probe}>&-
fi

echo "ok: user import, periods, counters, conflicts, revisions, local pause, purge, lock and usage"
