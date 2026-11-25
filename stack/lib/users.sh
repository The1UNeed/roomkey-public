#!/usr/bin/env bash
# users.sh — accounts on top of PSM's nodes (psm user …)
#
#   psm user add NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD] [--quota SIZE] [--json]
#   psm user list [--json]
#   psm user show NAME [--json] [--show-secrets]
#   psm user update NAME [--nodes …] [--days N | --expires DATE | --no-expiry]
#                        [--quota SIZE | --no-quota] [--reset-usage] [--enable | --disable] [--json]
#   psm user delete NAME [--json]
#   psm user links NAME [--server ADDR]
#   psm user token NAME [--json]          new subscription URL; the old one stops working
#   psm user import [--json] < STORE      the panel's users for this server (below)
#   psm user usage [--json]               each user's counters, for the panel
#   psm user online [--json]              each user's client IPs now (Xray)
#
# Panel-managed users (roomkey): `psm user import` takes the complete list of
# users the panel lets onto this server, as JSON on stdin:
#
#   {"users": [{"name", "uuid", "password", "nodes": [TAG…] | ["*"],
#               "enabled", "expires_at": epoch|null, "quota_bytes": n|null,
#               "period": "<id of the panel's current period>"}]}
#
# plus "revision": the panel's number for this list. A list older than the one
# already taken is ignored (a task delivered late must not undo a newer one).
#
# Imported users carry "managed": true. The panel owns their periods: their
# usage never starts over with the calendar month here, only when the panel
# sends another "period". Users made with `psm user add` stay as they are. The
# cores restart only when what they serve differs from what each core last
# took successfully ("applied_fp", per core), not on every import — and a core
# that rolled back is tried again. Every user also has "counter_bytes": all the
# traffic Xray ever counted for them, never reset, and "counter_epoch", which
# changes only when the counter starts over (the store was lost), so the panel
# can tell a new counter from a late report. "local_paused" is this server's
# own pause (the local page): imports keep it, and only `--local-resume` lifts
# it — it never overrides what the panel decided.
#
# One writer at a time: import, the CLI and the minute timer take the same
# lock (flock on .psm-users.lock beside the config directory) for their whole read-change-write.
#
# A user has one UUID and one password, used on every node assigned to them:
# VLESS / VMess / TUIC take the UUID; Trojan / Hysteria2 / AnyTLS / TUIC /
# SOCKS the password (SOCKS login psmu-NAME). The node's own credential stays
# as it is, so existing links keep working. Shadowsocks 2022, Snell and
# WireGuard stay single-key: users on an SS2022 server would change its
# owner's link.
#
# Accounts are merged into a core's config on every restart PSM does
# (xray_test_restart / sb_test_restart / mh_test_restart), after the node
# builders wrote their owner-only inbounds. Entries PSM added before carry the
# name psmu-NAME (Xray: email psmu-NAME@psm) and are replaced each time;
# mihomo's TUIC users are a {uuid: password} map, where everything after the
# owner's first entry is PSM's. Disabled, expired and over-quota users are
# left out.
#
# Xray counts traffic per user, so a quota counts a user's traffic through
# Xray nodes, per calendar month; reaching it pauses the account everywhere.
# sing-box and mihomo keep node-level quotas (psm traffic): neither exposes
# per-user counters.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

USERS_FILE="$CFG_DIR/users.json"
# beside the config directory, not in it: a backup restore replaces that
# directory, and a lock file inside would be a different file before and after
USERS_LOCK_FILE="$(dirname "$CFG_DIR")/.psm-users.lock"
USERS_PREFIX="psmu-"

_users_err()  { printf 'psm user: %s\n' "$*" >&2; }
_users_usage() {
    cat <<'EOF'
Usage:
  psm user add NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD] [--quota SIZE] [--json]
  psm user list [--json]
  psm user show NAME [--json] [--show-secrets]
  psm user update NAME [--nodes all|TAG,TAG] [--days N | --expires YYYY-MM-DD | --no-expiry]
                       [--quota SIZE | --no-quota] [--reset-usage] [--enable | --disable] [--json]
  psm user delete NAME [--json]
  psm user links NAME [--server ADDR]
  psm user token NAME [--json]
  psm user import [--json] < STORE
  psm user usage [--json]
  psm user online [--json]

SIZE is bytes or a number with K, M, G or T (1G = 1024^3). A quota counts
the user's traffic through Xray nodes per calendar month.
EOF
}

# ── Store ─────────────────────────────────────────────────────────────────────
# A store that no longer parses (a power cut, a full disk) must never read as
# "no users": the periodic check would write that back over it, and every
# core restart would take the accounts out of the configs. So a load fails
# instead — falling back to the copy of the last good store kept beside it —
# and a save writes only a store that is one, atomically, next to the file.
_USERS_OK='type == "object" and ((.users // []) | type) == "array"'
_users_load() {
    [[ -f "$USERS_FILE" ]] || { echo '{"users":[]}'; return 0; }
    local j
    if j=$(jq -ce "if $_USERS_OK then . else error(\"not a store\") end" "$USERS_FILE" 2>/dev/null); then
        printf '%s\n' "$j"; return 0
    fi
    if [[ -f "$USERS_FILE.prev" ]] && j=$(jq -ce "if $_USERS_OK then . else error(\"not a store\") end" "$USERS_FILE.prev" 2>/dev/null); then
        _users_err "$USERS_FILE does not parse: using the last good copy, $USERS_FILE.prev"
        printf '%s\n' "$j"; return 0
    fi
    _users_err "$USERS_FILE does not parse and there is no good copy of it; fix or remove it (nothing was changed)"
    return 1
}
_users_save() {
    mkdir -p "$(dirname "$USERS_FILE")"
    local tmp; tmp=$(mktemp "$USERS_FILE.XXXXXX") || return 1
    if printf '%s' "$1" | jq -e "$_USERS_OK" >/dev/null 2>&1 && printf '%s' "$1" | jq '.' > "$tmp" && [[ -s "$tmp" ]]; then
        chmod 600 "$tmp"
        # the store being replaced, while it is a good one, is the fallback
        jq -e "$_USERS_OK" "$USERS_FILE" >/dev/null 2>&1 && cp -p "$USERS_FILE" "$USERS_FILE.prev"
        mv -f "$tmp" "$USERS_FILE"
    else
        rm -f "$tmp"; return 1
    fi
}
_users_get() { _users_load | jq -c --arg n "$1" '.users[]? | select(.name == $n)'; }

# Held until the process ends (like _trf_lock): every command that changes the
# store takes it before reading it, and fails when it cannot. Where flock is
# missing (not on the servers PSM runs on) there is no lock, as before.
_users_lock() {
    [[ -n "${_USERS_LOCKED:-}" ]] && return 0
    mkdir -p "$(dirname "$USERS_FILE")" 2>/dev/null || { _users_err "cannot create $(dirname "$USERS_FILE")"; return 1; }
    # one writer at a time is not optional: without flock nothing is changed
    command -v flock &>/dev/null || { _users_err "flock is missing (util-linux): nothing was changed"; return 1; }
    { exec {_USERS_LOCK_FD}>"$USERS_LOCK_FILE"; } 2>/dev/null || { _users_err "cannot open $USERS_LOCK_FILE"; return 1; }
    # a core restart can take a while; a writer that cannot get the lock stops
    # rather than writing over another's change
    flock -w 120 "$_USERS_LOCK_FD" 2>/dev/null || { _users_err "another psm user command holds the lock; nothing was changed"; return 1; }
    _USERS_LOCKED=1
}

# The store and one user, both on jq's stdin: `_users_with USER FILTER` runs
# FILTER with the store as .[0] and the user as $u (no secret in argv).
_users_with() {
    { _users_load || return 1; printf '%s\n' "$1"; } | jq -cs ".[1] as \$u | $2"
}

_users_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

_users_size() {   # 50G / 500M / 1T / bytes → bytes
    local v="${1^^}" n u
    [[ "$v" =~ ^([0-9]+)([KMGT]?)B?$ ]] || return 1
    n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
    case "$u" in K) n=$((n * 1024)) ;; M) n=$((n * 1024 ** 2)) ;; G) n=$((n * 1024 ** 3)) ;; T) n=$((n * 1024 ** 4)) ;; esac
    printf '%s' "$n"
}

_users_date() {   # YYYY-MM-DD → end of that day, epoch
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    date -d "$1 23:59:59" +%s 2>/dev/null
}

_users_nodes_arg() {   # all | TAG,TAG → JSON array
    if [[ "$1" == all || "$1" == "*" ]]; then echo '["*"]'; return 0; fi
    jq -cn --arg s "$1" '$s | split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))'
}

# Users that go into the cores right now.
_users_active_json() {
    [[ -f "$USERS_FILE" ]] || { echo '[]'; return 0; }
    local u; u=$(_users_load) || return 1
    jq -c --argjson now "$(date +%s)" '[.users[]?
        | select(.enabled != false and .local_paused != true)
        | select(.expires_at == null or .expires_at > $now)
        | select(.quota_bytes == null or (.used_bytes // 0) < .quota_bytes)
        | {name, uuid, password, nodes: (.nodes // ["*"])}]' <<<"$u"
}

_users_state() {   # user JSON → active / disabled / expired / over_quota
    jq -r --argjson now "$(date +%s)" '
        if .enabled == false then "disabled"
        elif .local_paused == true then "paused_here"
        elif (.expires_at != null and .expires_at <= $now) then "expired"
        elif (.quota_bytes != null and (.used_bytes // 0) >= .quota_bytes) then "over_quota"
        else "active" end' <<<"$1"
}

# ── Merge into the cores' configs ─────────────────────────────────────────────
# Owner credentials → node tag, so an inbound shared by several nodes (Xray
# REALITY on one port) still gets the users of each of them.
_users_owner_map() {
    # straight from the node stores (files): no node's credentials pass
    # through any command's arguments
    source "$LIB_DIR/node_cli.sh" || return 1
    local core proto path map='{}'
    while IFS=$'\t' read -r core proto; do
        path=$(_node_cli_store_path "$core" "$proto")
        [[ -f "$path" ]] || continue
        # a store that is not a list of nodes is an error, not "no owners"
        jq -e 'type == "array"' "$path" >/dev/null 2>&1 || { _users_err "invalid node store: $path"; return 1; }
        map=$( { printf '%s\n' "$map"; cat "$path"; } | jq -cs '.[0] + ([(.[1] // [])[]? | .tag as $t
            | ((.uuid // empty), (.password // empty)) | select(type == "string" and . != "") | {key: ., value: $t}] | from_entries)') || return 1
    done < <(_node_cli_pairs)
    printf '%s' "$map"
}

_USERS_JQ_DEFS='
def mark: "'"$USERS_PREFIX"'" + .name;
def assigned($tags): . as $u
    | (($u.nodes | index("*")) != null) or any($tags[]; . as $t | ($u.nodes | index($t)) != null);
def psm_added: (. // "") | tostring | startswith("'"$USERS_PREFIX"'");
'

_USERS_JQ_XRAY='
.inbounds |= map(
  if ((.protocol // "") | IN("vless", "vmess", "trojan", "hysteria"))
     or (.protocol == "socks" and ([(.settings.accounts // [])[] | select(.user | psm_added | not)] | length) > 0) then
    . as $in
    | ([.tag] + ([((.settings.clients // [])[] | (.id // .password // .auth // empty)),
                  ((.settings.accounts // [])[] | (.pass // empty))] | map($owners[.] // empty))) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | if .protocol == "socks" then
        .settings.accounts = ([.settings.accounts[] | select(.user | psm_added | not)]
                              + [$mine[] | {user: mark, pass: .password}])
      else
        .settings.clients = [(.settings.clients // [])[] | select(.email | psm_added | not)]
        | if .protocol == "vless" then
            .settings.clients += [$mine[] | {id: .uuid, flow: ($in.settings.clients[0].flow // ""), email: (mark + "@psm")}]
          elif .protocol == "vmess" then .settings.clients += [$mine[] | {id: .uuid, email: (mark + "@psm")}]
          elif .protocol == "trojan" then .settings.clients += [$mine[] | {password: .password, email: (mark + "@psm")}]
          else .settings.clients += [$mine[] | {auth: .password, email: (mark + "@psm")}] end
      end
  else . end)
| if ($users | length) > 0 then
    .policy.levels."0" = ((.policy.levels."0" // {}) + {statsUserUplink: true, statsUserDownlink: true, statsUserOnline: true})
  else . end'

_USERS_JQ_SB='
.inbounds |= map(
  if ((.type // "") | IN("vless", "vmess", "trojan", "hysteria2", "anytls", "tuic"))
     or (.type == "socks" and ([(.users // [])[] | select(.username | psm_added | not)] | length) > 0) then
    . as $in
    | ([.tag] + ([(.users // [])[] | (.uuid // .password // empty)] | map($owners[.] // empty))) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | .users = [(.users // [])[] | select((.name // .username) | psm_added | not)]
    | if .type == "vless" then
        .users += [$mine[] | ({name: mark, uuid: .uuid}
                              + (if ($in.users[0].flow // "") != "" then {flow: $in.users[0].flow} else {} end))]
      elif .type == "vmess" then .users += [$mine[] | {name: mark, uuid: .uuid, alterId: 0}]
      elif .type == "tuic"  then .users += [$mine[] | {name: mark, uuid: .uuid, password: .password}]
      elif .type == "socks" then .users += [$mine[] | {username: mark, password: .password}]
      else .users += [$mine[] | {name: mark, password: .password}] end
  else . end)'

_USERS_JQ_MH='
.listeners |= map(
  if ((.type // "") | IN("vless", "vmess", "trojan", "hysteria2", "anytls", "tuic"))
     or (.type == "socks" and ([(.users // [])[] | select(.username | psm_added | not)] | length) > 0) then
    . as $in
    | ((if (.users | type) == "object" then [.users | to_entries[] | .key, .value]
        else [(.users // [])[] | (.uuid // .password // empty)] end) | map($owners[.] // empty)) as $o
    | ([.name] + $o) as $tags
    | [$users[] | select(assigned($tags))] as $mine
    | if (.users | type) == "object" then
        if .type == "tuic" then
          .users = ((.users | to_entries | .[0:1] | from_entries) + ([$mine[] | {key: .uuid, value: .password}] | from_entries))
        else
          .users = ((.users | with_entries(select(.key | psm_added | not))) + ([$mine[] | {key: mark, value: .password}] | from_entries))
        end
      else
        .users = [(.users // [])[] | select(.username | psm_added | not)]
        | if .type == "vless" then
            .users += [$mine[] | ({username: mark, uuid: .uuid}
                                  + (if ($in.users[0].flow // "") != "" then {flow: $in.users[0].flow} else {} end))]
          elif .type == "vmess" then .users += [$mine[] | {username: mark, uuid: .uuid, alterId: 0}]
          else .users += [$mine[] | {username: mark, password: .password}] end
      end
  else . end)'

# psm_users_inject <xray|sing-box|mihomo>: puts the current accounts into that
# core's config, in place. Called by the core's restart path before its check.
psm_users_inject() {
    local core="$1" cfg filter
    case "$core" in
        xray)     cfg="$XRAY_CFG_DIR/config.json";    filter="$_USERS_JQ_XRAY" ;;
        sing-box) cfg="$SINGBOX_CFG_DIR/config.json"; filter="$_USERS_JQ_SB" ;;
        mihomo)   cfg="$MIHOMO_CFG_DIR/config.yaml";  filter="$_USERS_JQ_MH" ;;
        *) return 0 ;;
    esac
    [[ -f "$cfg" ]] || return 0
    # nothing to add and nothing of ours to remove
    [[ -f "$USERS_FILE" ]] || grep -q "$USERS_PREFIX" "$cfg" 2>/dev/null || return 0
    local users owners tmp
    # accounts that cannot be read, or a merge that fails, refuse the restart:
    # the core keeps its last good config rather than one that is not what
    # the store says (and the caller reports the failure)
    users=$(_users_active_json) || { _users_err "cannot read the accounts for $core"; return 1; }
    # a grant naming its core ("xray/hk-1") counts on that core only, as the
    # plain tag; one for another core is no grant here
    users=$(jq -c --arg c "$core" 'map(.nodes |= map(if test("/") then (if startswith($c + "/") then ltrimstr($c + "/") else empty end) else . end))' <<<"$users") \
        || { _users_err "cannot read the accounts for $core"; return 1; }
    owners=$(_users_owner_map) || { _users_err "cannot read the node stores for $core"; return 1; }
    tmp=$(mktemp) || return 1
    # the accounts reach jq on stdin, never in its arguments (ps shows those)
    if printf '%s\n%s\n' "$users" "$owners" \
        | jq -n --slurpfile cfg "$cfg" "$_USERS_JQ_DEFS input as \$users | input as \$owners | \$cfg[0] | ($filter)" > "$tmp" 2>/dev/null \
        && [[ -s "$tmp" ]]; then
        # unchanged: leave it; changed: replaced atomically (mode and owner
        # kept) — and a write that fails refuses the restart
        local rc=0
        cmp -s "$tmp" "$cfg" || psm_file_replace "$cfg" "$tmp" || rc=1
        rm -f "$tmp"
        return "$rc"
    fi
    rm -f "$tmp"
    return 1
}

_users_core_installed() {
    case "$1" in
        xray)     [[ -x "$XRAY_BIN" && -f "$XRAY_CFG_DIR/config.json" ]] ;;
        sing-box) [[ -x "$SINGBOX_BIN" && -f "$SINGBOX_CFG_DIR/config.json" ]] ;;
        mihomo)   [[ -x "$MIHOMO_BIN" && -f "$MIHOMO_CFG_DIR/config.yaml" ]] ;;
    esac
}

# Restart, through its own path (which merges the users), every installed core
# that has not taken what it should serve now — not the others — then bring the
# per-user subscriptions up to date. Xray's counters are banked first: a
# restart resets them. The caller holds the lock.
users_apply() {
    local core rc=0 u
    _users_checkpoint || true
    u=$(_users_load) || return 1
    # Xray counts each account from the start (a quota set later must see the
    # traffic before it); expiry and quotas need the periodic check
    if jq -e '(.users // []) | length > 0' <<<"$u" >/dev/null 2>&1 && _users_core_installed xray; then
        ( source "$LIB_DIR/traffic.sh"; _trf_stats_enabled || _trf_enable_stats ) >/dev/null 2>&1 || true
    fi
    if jq -e '[.users[]? | (.quota_bytes != null or .expires_at != null)] | any' <<<"$u" >/dev/null 2>&1; then
        ( source "$LIB_DIR/traffic.sh"; _trf_timer_active || _trf_install_timer ) >/dev/null 2>&1 || true
    fi
    local fp ok_cores='[]' bad_cores='[]' have
    fp=$(_users_fp)
    have=$(jq -c '.applied_fp // {}' <<<"$u")
    for core in xray sing-box mihomo; do
        _users_core_installed "$core" || continue
        [[ "$(jq -r --arg c "$core" '.[$c] // ""' <<<"$have")" == "$fp" ]] && continue
        if ( case "$core" in
                 xray)     source "$LIB_DIR/xray/core.sh";    xray_test_restart ;;
                 sing-box) source "$LIB_DIR/singbox/core.sh"; sb_test_restart ;;
                 mihomo)   source "$LIB_DIR/mihomo/core.sh";  mh_test_restart ;;
             esac ) >&2; then
            ok_cores=$(jq -c --arg c "$core" '. + [$c]' <<<"$ok_cores")
        else
            _users_err "$core did not accept the accounts; its previous config was restored"; rc=1
            bad_cores=$(jq -c --arg c "$core" '. + [$c]' <<<"$bad_cores")
        fi
    done
    # what each core took: a core that rolled back keeps its old fingerprint,
    # so the next import or check tries it again
    _users_save "$(_users_load | jq --argjson a "$(_users_active_json | jq -c '[.[].name]')" --arg fp "$fp" \
        --argjson ok "$ok_cores" --argjson bad "$bad_cores" --argjson now "$(date +%s)" '
        .applied = $a
        | .applied_fp = ((.applied_fp // {}) + ([$ok[] | {key: ., value: $fp}] | from_entries))
        | .applied_fp |= with_entries(select(.key as $k | $bad | index($k) | not))
        | if ($bad | length) > 0 then .apply_failed_at = $now else del(.apply_failed_at) end')" || true
    _users_online_refresh
    return "$rc"
}

# ── Per-user links and subscriptions ──────────────────────────────────────────
# Prints the share links of one user (their credentials, their nodes).
_users_links() {   # <user JSON> <server>
    local user="$1" server="$2"
    source "$LIB_DIR/subscribe.sh"
    _SUB_USER="$user" _sub_collect_uris "$server"
}

_users_online_domain() { ( source "$LIB_DIR/subscribe.sh"; _sub_state_get '.domain' ) 2>/dev/null; }

_users_online_url() {   # <user JSON> → URL, or nothing when online subscriptions are off
    local d; d=$(_users_online_domain)
    [[ -n "$d" ]] || return 0
    printf 'https://%s/psm-sub/%s/sub.txt' "$d" "$(jq -r '.token' <<<"$1")"
}

# Rewrites the subscription of every active user; removes those of the others.
_users_online_refresh() {
    local domain server u tok
    domain=$(_users_online_domain)
    [[ -n "$domain" ]] || return 0
    ( source "$LIB_DIR/subscribe.sh"
      server=$(_sub_state_get '.server'); [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || echo "$domain")
      active=$(_users_active_json | jq -r '.[].name')
      # the panel's users have the panel's subscriptions: PSM's own is for users made here
      while IFS= read -r u; do
          [[ -n "$u" ]] || continue
          tok=$(jq -r '.token' <<<"$u")
          if grep -qxF "$(jq -r '.name' <<<"$u")" <<<"$active"; then
              _SUB_USER="$u" _sub_online_write "$tok" "$domain" "$server" || true
          else
              rm -rf "$(_sub_token_dir "$tok")"
          fi
      done < <(_users_load | jq -c '.users[]? | select(.managed != true)') ) >/dev/null 2>&1 || true
    return 0
}

# ── Periodic check (traffic_check, every minute) ──────────────────────────────
# Adds this month's Xray traffic to each user, then re-applies when the set of
# active users differs from the one last applied (expiry, quota, month rollover).
users_check() {
    [[ -f "$USERS_FILE" ]] || return 0
    _users_lock || return 0
    local month st
    month=$(date +%Y-%m)
    local cur; cur=$(_users_load) || return 0
    # the panel's users start over when the panel says (a new "period"), not here
    st=$(jq -c --arg m "$month" '.users |= map(
        if .managed == true then .
        elif (.used_month // "") != $m then .used_bytes = 0 | .used_month = $m else . end)' <<<"$cur")
    _users_save "$st" || return 0
    _users_checkpoint || true
    # a core behind what it should serve (expiry, a quota, a rollback): apply
    # again — after a failed try, not more often than every ten minutes
    if _users_pending; then
        local failed; failed=$(_users_load | jq -r '.apply_failed_at // 0')
        (( $(date +%s) - failed >= 600 )) && { users_apply >/dev/null 2>&1 || true; }
    fi
    return 0
}

# Adds what Xray counted per user since the last time (and resets its
# counters) to each user's period usage and lifetime counter. Before a
# restart, a period switch or a removal, so the last sample is not lost. The
# caller holds the lock.
_users_checkpoint() {
    _users_core_installed xray || return 0
    local q st
    q=$( source "$LIB_DIR/traffic.sh" 2>/dev/null
         "$XRAY_BIN" api statsquery -s "$XRAY_API_ADDR" -pattern "user>>>${USERS_PREFIX}" -reset 2>/dev/null ) || return 0
    [[ -n "$q" ]] || return 0
    st=$( { _users_load || return 1; printf '%s\n' "$q"; } | jq -cs --arg p "$USERS_PREFIX" '
        .[0] as $st | ([.[1].stat[]? | {n: (.name | split(">>>")[1] | sub("@psm$"; "")), v: ((.value // 0) | tonumber)}]) as $q
        | $st | .users |= map(. as $u
            | ([$q[] | select(.n == ($p + $u.name)) | .v] | add // 0) as $d
            | .used_bytes = ((.used_bytes // 0) + $d)
            | .counter_bytes = ((.counter_bytes // 0) + $d))' 2>/dev/null) || return 1
    _users_save "$st"
}

# Before any Xray restart (lib/common.sh psm_users_merge): bank the counters,
# but never wait for the lock — a restart must not hang on a user command.
psm_users_checkpoint_quiet() {
    [[ -f "$USERS_FILE" ]] || return 0
    # a caller that holds the lock (an import) banks under it
    if [[ -n "${_USERS_LOCKED:-}" ]]; then _users_checkpoint >/dev/null 2>&1; return; fi
    # otherwise in a subshell, so the lock is let go as soon as it is done
    # (a menu left open must not keep it)
    ( command -v flock &>/dev/null || exit 0
      exec {fd}>"$USERS_LOCK_FILE" || exit 0
      flock -n "$fd" || exit 0
      _USERS_LOCKED=1
      _users_checkpoint ) >/dev/null 2>&1
}

# The fingerprint of what the cores should serve now.
_users_fp() { _users_served | sha256sum | cut -c1-16; }

# Whether an installed core has not taken what it should serve now.
_users_pending() {
    local fp core have
    fp=$(_users_fp)
    have=$(_users_load | jq -c '.applied_fp // {}') || return 1
    for core in xray sing-box mihomo; do
        _users_core_installed "$core" || continue
        [[ "$(jq -r --arg c "$core" '.[$c] // ""' <<<"$have")" == "$fp" ]] || return 0
    done
    return 1
}

# ── CLI ───────────────────────────────────────────────────────────────────────
_users_redact() { if [[ "$1" == 1 ]]; then cat; else jq -c '.uuid = "***" | .password = "***" | .token = "***"'; fi; }

_users_view() {   # <user JSON> <show secrets 0|1> → JSON with state and URL
    local u="$1"
    jq -c --arg s "$(_users_state "$u")" --arg url "$(_users_online_url "$u")" \
        '. + {state: $s, subscription: (if $url == "" then null else $url end)}' <<<"$u" | _users_redact "$2"
}

_users_print() {   # <view JSON>: one user, for people
    jq -r '
        def gib: if . == null then "-" else ((. / 1073741824 * 100 | round) / 100 | tostring) + " GiB" end;
        "  name          \(.name)",
        "  state         \(.state)",
        "  nodes         \(.nodes | join(","))",
        "  expires       \(if .expires_at == null then "never" else (.expires_at | strftime("%Y-%m-%d %H:%M UTC")) end)",
        "  quota         \(.quota_bytes | gib)   used this month: \(.used_bytes // 0 | gib)",
        "  uuid          \(.uuid)",
        "  password      \(.password)",
        "  subscription  \(.subscription // "online subscriptions are off (psm user links NAME prints the links)")"' <<<"$1"
}

_users_cmd_add() {
    local name="${1:-}" nodes='["*"]' exp="null" quota="null" json=0 v
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    _users_valid_name "$name" || { _users_err "NAME: lowercase letters, digits, - and _ (up to 32)"; return 2; }
    while (( $# )); do
        case "$1" in
            --nodes)   [[ -n "${2:-}" ]] || { _users_usage >&2; return 2; }; nodes=$(_users_nodes_arg "$2"); shift 2; continue ;;
            --days)    [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { _users_err "--days needs a positive number"; return 2; }
                       exp=$(( $(date +%s) + $2 * 86400 )); shift 2; continue ;;
            --expires) v=$(_users_date "${2:-}") || { _users_err "--expires needs YYYY-MM-DD"; return 2; }; exp="$v"; shift 2; continue ;;
            --quota)   v=$(_users_size "${2:-}") || { _users_err "--quota needs a size such as 50G"; return 2; }
                       (( v > 0 )) && quota="$v" || quota="null"; shift 2; continue ;;
            --json) json=1 ;;
            *) _users_err "unknown option: $1"; return 2 ;;
        esac
        shift
    done
    _users_lock || return 1
    [[ -z "$(_users_get "$name")" ]] || { _users_err "user $name already exists"; return 1; }
    local uuid pass tok user
    uuid=$(uuid_gen) && pass=$(rand_str 24) && tok=$(rand_str 48) || { _users_err "cannot generate credentials"; return 1; }
    # the secrets go to jq on stdin, never in its arguments (ps shows those)
    user=$(printf '%s\n%s\n%s\n' "$uuid" "$pass" "$tok" | jq -cRn --arg n "$name" --argjson nodes "$nodes" \
        --argjson exp "$exp" --argjson q "$quota" --argjson now "$(date +%s)" --arg m "$(date +%Y-%m)" \
        '[inputs] as [$u, $p, $t] | {name: $n, uuid: $u, password: $p, token: $t, nodes: $nodes, created_at: $now,
          expires_at: $exp, quota_bytes: $q, used_bytes: 0, used_month: $m, enabled: true}')
    _users_save "$(_users_with "$user" '.[0] | .users += [$u]')" || { _users_err "cannot write $USERS_FILE"; return 1; }
    users_apply >/dev/null || true
    if (( json )); then jq -c '{status: "created", user: .}' <<<"$(_users_view "$user" 1)"
    else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_update() {
    local name="${1:-}" json=0 v
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    _users_lock || return 1
    local user; user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    local f=''   # jq assignments collected from the options
    while (( $# )); do
        case "$1" in
            --nodes)       [[ -n "${2:-}" ]] || { _users_usage >&2; return 2; }; f+=" | .nodes = $(_users_nodes_arg "$2")"; shift 2; continue ;;
            --days)        [[ "${2:-}" =~ ^[0-9]+$ && "$2" -gt 0 ]] || { _users_err "--days needs a positive number"; return 2; }
                           f+=" | .expires_at = $(( $(date +%s) + $2 * 86400 ))"; shift 2; continue ;;
            --expires)     v=$(_users_date "${2:-}") || { _users_err "--expires needs YYYY-MM-DD"; return 2; }; f+=" | .expires_at = $v"; shift 2; continue ;;
            --no-expiry)   f+=' | .expires_at = null' ;;
            --quota)       v=$(_users_size "${2:-}") || { _users_err "--quota needs a size such as 50G"; return 2; }
                           if (( v > 0 )); then f+=" | .quota_bytes = $v"; else f+=' | .quota_bytes = null'; fi; shift 2; continue ;;
            --no-quota)    f+=' | .quota_bytes = null' ;;
            --reset-usage) f+=' | .used_bytes = 0' ;;
            --enable)      f+=' | .enabled = true' ;;
            --disable)     f+=' | .enabled = false' ;;
            # this server's own pause (the local page): never touches .enabled,
            # which is the panel's for its users
            --local-pause)  f+=' | .local_paused = true' ;;
            --local-resume) f+=' | del(.local_paused)' ;;
            --json) json=1 ;;
            *) _users_err "unknown option: $1"; return 2 ;;
        esac
        shift
    done
    [[ -n "$f" ]] || { _users_err "nothing to change"; return 2; }
    user=$(jq -c ". ${f}" <<<"$user") || { _users_err "invalid change"; return 2; }
    _users_save "$(_users_with "$user" '.[0] | .users |= map(if .name == $u.name then $u else . end)')" \
        || { _users_err "cannot write $USERS_FILE"; return 1; }
    # saved; a core that does not take it is a failure the caller hears about
    # (the local page's pause must not say done when the core refused it)
    users_apply >/dev/null || { _users_err "saved, but a core did not accept the change (it keeps its previous config; the next check tries again)"; return 1; }
    if (( json )); then jq -c '{status: "updated", user: .}' <<<"$(_users_view "$user" 1)"
    else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_delete() {
    local name="${1:-}" json=0 user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    [[ "${2:-}" == --json ]] && json=1
    _users_lock || return 1
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    # the subscription goes first, so the link is dead even if a core restart fails
    ( source "$LIB_DIR/subscribe.sh"; rm -rf "$(_sub_token_dir "$(jq -r '.token' <<<"$user")")" ) 2>/dev/null || true
    _users_save "$(_users_load | jq -c --arg n "$name" '.users |= map(select(.name != $n))')" \
        || { _users_err "cannot write $USERS_FILE"; return 1; }
    users_apply >/dev/null || true
    if (( json )); then jq -cn --arg n "$name" '{status: "deleted", name: $n}'; else echo "deleted $name"; fi
}

_users_cmd_token() {
    local name="${1:-}" json=0 user old tok
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    [[ "${2:-}" == --json ]] && json=1
    _users_lock || return 1
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    old=$(jq -r '.token' <<<"$user"); tok=$(rand_str 48) || return 1
    ( source "$LIB_DIR/subscribe.sh"; rm -rf "$(_sub_token_dir "$old")" ) 2>/dev/null || true
    user=$(printf '%s\n%s\n' "$user" "$tok" | jq -cR -n 'input as $u | input as $t | ($u | fromjson) | .token = $t')
    _users_save "$(_users_with "$user" '.[0] | .users |= map(if .name == $u.name then $u else . end)')" || return 1
    _users_online_refresh
    local url; url=$(_users_online_url "$user")
    if (( json )); then jq -cn --arg n "$name" --arg u "$url" '{status: "rotated", name: $n, subscription: (if $u == "" then null else $u end)}'
    else echo "${url:-new token saved; online subscriptions are off}"; fi
}

_users_cmd_list() {
    local json=0; [[ "${1:-}" == --json ]] && json=1
    local all='[]' u
    while IFS= read -r u; do
        [[ -n "$u" ]] || continue
        all=$(jq -c --argjson v "$(_users_view "$u" 0)" '. + [$v]' <<<"$all")
    done < <(_users_load | jq -c '.users[]?')
    if (( json )); then jq -c '{users: .}' <<<"$all"; return 0; fi
    [[ "$all" != '[]' ]] || { echo "no users"; return 0; }
    jq -r '
        def gib: if . == null then "-" else ((. / 1073741824 * 10 | round) / 10 | tostring) + "G" end;
        ["NAME", "STATE", "EXPIRES", "USED/QUOTA", "NODES"],
        (.[] | [.name, .state,
                (if .expires_at == null then "never" else (.expires_at | strftime("%Y-%m-%d")) end),
                ((.used_bytes // 0 | gib) + "/" + (.quota_bytes | gib)),
                (.nodes | join(","))])
        | @tsv' <<<"$all" | psm_table
}

_users_cmd_show() {
    local name="${1:-}" json=0 secrets=0 user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    while (( $# )); do
        case "$1" in --json) json=1 ;; --show-secrets) secrets=1 ;; *) _users_err "unknown option: $1"; return 2 ;; esac
        shift
    done
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    if (( json )); then _users_view "$user" "$secrets"; else _users_print "$(_users_view "$user" 1)"; fi
}

_users_cmd_links() {
    local name="${1:-}" server="" user
    [[ -n "$name" && "$name" != -* ]] || { _users_usage >&2; return 2; }
    shift
    [[ "${1:-}" == --server ]] && server="${2:-}"
    user=$(_users_get "$name")
    [[ -n "$user" ]] || { _users_err "no user $name"; return 1; }
    [[ -n "$server" ]] || server=$(get_ipv4 2>/dev/null || true)
    [[ -n "$server" ]] || { _users_err "cannot detect this server's address; pass --server"; return 1; }
    _users_links "$user" "$server"
}

# ── Panel-managed users ───────────────────────────────────────────────────────
# What the cores serve: who, with which credentials, on which nodes.
_users_served() { _users_active_json | jq -cS 'sort_by(.name)'; }

_USERS_IMPORT_CHECK='
def bad($m): error($m);
# a node: its tag, or core/tag (the panel names the core: a node of the same
# name on another core, made by hand, is not the one granted)
def tag: type == "string" and (. == "*" or test("^((xray|sing-box|mihomo)/)?[A-Za-z0-9._-]{1,64}$"));
if type != "object" or ((.users // null) | type) != "array" then bad("expected {\"users\": [...]}")
elif (.users | length) > 5000 then bad("too many users (5000 at most)")
elif (.revision // 0 | type) != "number" or (.revision // 0) < 0 then bad("bad revision")
else {revision: ((.revision // 0) | floor), users: (.users | map(
    if type != "object" then bad("a user is not an object")
    elif ((.name // "") | test("^[a-z0-9][a-z0-9_-]{0,31}$") | not) then bad("bad name: \(.name)")
    elif ((.uuid // "") | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") | not) then bad("bad uuid for \(.name)")
    elif ((.password // "") | test("^[A-Za-z0-9_-]{8,64}$") | not) then bad("bad password for \(.name)")
    elif ((.nodes // ["*"]) | type != "array" or length == 0 or length > 200 or (map(tag) | all | not)) then bad("bad nodes for \(.name)")
    elif (.expires_at != null and ((.expires_at | type) != "number" or .expires_at < 0)) then bad("bad expires_at for \(.name)")
    elif (.quota_bytes != null and ((.quota_bytes | type) != "number" or .quota_bytes <= 0)) then bad("bad quota_bytes for \(.name)")
    elif ((.period // "") | type != "string" or (test("^[A-Za-z0-9:._-]{0,40}$") | not)) then bad("bad period for \(.name)")
    else {name, uuid, password, nodes: (.nodes // ["*"]), enabled: (.enabled != false),
          expires_at: (if .expires_at == null then null else (.expires_at | floor) end),
          quota_bytes: (if .quota_bytes == null then null else (.quota_bytes | floor) end),
          period: (.period // "")} end)
  | if (map(.name) | unique | length) != length then bad("a name appears twice") else . end)}
end'

# Merges the panel's list (as .[1]) into the store (as .[0]); .[2] holds fresh
# random strings for new users' tokens and counter epochs (on stdin too: a
# token is a secret). Epochs start with the time, so a newer counter
# generation always sorts after an older one.
_USERS_IMPORT_MERGE='
.[0] as $cur | .[1] as $in | .[2] as $seeds
| ($cur.users // []) as $old
| ($old | map({key: .name, value: .}) | from_entries) as $by
| ([$in.users[].name]) as $names
| $cur
| .revision = $in.revision
| .revision_fp = $fp
| .users = ([$old[] | select(.managed != true and (.name as $n | $names | index($n) | not))]
    + [$in.users | to_entries[] | .key as $i | .value as $u | ($by[$u.name] // {}) as $o
       | if ($o | length) > 0 and $o.managed != true then $o
         else $u + {managed: true,
                    token: ($o.token // $seeds[$i].token),
                    counter_epoch: ($o.counter_epoch // $seeds[$i].epoch),
                    created_at: ($o.created_at // $now),
                    counter_bytes: ($o.counter_bytes // 0),
                    used_bytes: (if ($o.period // null) == $u.period then ($o.used_bytes // 0) else 0 end)}
              + (if $o.local_paused == true then {local_paused: true} else {} end)
         end])'

# The list holds every user's credentials: it stays in a private directory and
# on jq's stdin, never in a command line.
_users_cmd_import() {
    local dir rc
    dir=$(mktemp -d) || return 1
    chmod 700 "$dir"
    _users_import_in "$dir" "$@"; rc=$?
    rm -rf "$dir"
    return "$rc"
}

_users_import_in() {
    local dir="$1" json=0
    [[ "${2:-}" == --json ]] && json=1
    head -c 4194304 > "$dir/in" || { _users_err "cannot read stdin"; return 2; }
    local err
    if ! jq -c "$_USERS_IMPORT_CHECK" < "$dir/in" > "$dir/checked" 2> "$dir/err"; then
        err=$(sed -E 's/^jq: error \(at [^)]*\): //' "$dir/err" | head -1)
        _users_err "import: ${err:-not JSON}"; return 2
    fi
    _users_lock || return 1
    # a restore or migration that did not finish: what it kept aside, not the
    # half-restored store, is what the next try puts back, so no list is taken now
    if [[ -e "$(dirname "$CFG_DIR")/.psm-restore/incomplete" ]]; then
        _users_err "a restore did not finish on this server: run it again (psm restore) before users can be imported"; return 1
    fi
    local cur stored incoming fp stored_fp
    cur=$(_users_load) || return 1
    stored=$(jq -r '.revision // 0' <<<"$cur")
    stored_fp=$(jq -r '.revision_fp // ""' <<<"$cur")
    incoming=$(jq -r '.revision' "$dir/checked")
    fp=$(jq -cS '.users' "$dir/checked" | sha256sum | cut -c1-16)
    # A list older than the one taken (a task delivered late), or another list
    # under the same number, changes nothing: the panel numbers above it.
    if (( incoming < stored )) || { (( incoming == stored && incoming > 0 )) && [[ -n "$stored_fp" && "$fp" != "$stored_fp" ]]; }; then
        if (( json )); then jq -cn --argjson r "$stored" '{status: "stale", revision: $r, applied: false, ok: true, conflicts: []}'
        else echo "ignored: revision $incoming is older than $stored"; fi
        return 0
    fi
    # the last sample of the period being left is banked first
    _users_checkpoint || true
    cur=$(_users_load) || return 1
    local n i now
    n=$(jq '.users | length' "$dir/checked")
    now=$(date +%s)
    for (( i = 0; i < n; i++ )); do
        printf '{"token":"%s","epoch":"%010d-%s"}\n' "$(rand_str 48)" "$now" "$(rand_str 6)"
    done | jq -cs '.' > "$dir/seeds" || return 1
    local next
    next=$( { printf '%s\n' "$cur"; cat "$dir/checked" "$dir/seeds"; } | jq -cs --argjson now "$now" --arg fp "$fp" "$_USERS_IMPORT_MERGE") \
        || { _users_err "import: cannot merge"; return 1; }
    local conflicts
    conflicts=$( { printf '%s\n' "$next"; cat "$dir/checked"; } | jq -cs '.[1].users as $in
        | [.[0].users[] | select(.managed != true) | .name | select(. as $n | [$in[].name] | index($n))]')
    _users_save "$next" || { _users_err "cannot write $USERS_FILE"; return 1; }
    local applied=false rc=0
    # every core that has not taken this exact set gets it (a core that rolled
    # back on the last import is tried again, even when the list is the same)
    if _users_pending; then
        users_apply >/dev/null || rc=1
        applied=true
    fi
    local managed; managed=$(jq '.users | map(select(.managed == true)) | length' <<<"$next")
    if (( json )); then
        jq -cn --argjson n "$managed" --argjson a "$applied" --argjson t "$conflicts" --argjson r "$incoming" \
            --argjson ok "$([[ $rc == 0 ]] && echo true || echo false)" \
            '{status: "imported", revision: $r, managed: $n, applied: $a, ok: $ok, conflicts: $t}'
    else
        echo "imported revision $incoming: $managed panel users$([[ $applied == true ]] && echo ', cores restarted')"
    fi
    return "$rc"
}

# The server leaves the panel: every panel user goes (hand-made ones stay), and
# the cores are restarted without them. Fails when a core does not take it.
_users_cmd_purge() {
    local json=0; [[ "${1:-}" == --json ]] && json=1
    _users_lock || return 1
    if [[ ! -f "$USERS_FILE" ]]; then
        # no store, but a core config may still carry panel accounts (the
        # store lost): an empty store, applied, takes them out
        local c found=0
        for c in "$XRAY_CFG_DIR/config.json" "$SINGBOX_CFG_DIR/config.json" "$MIHOMO_CFG_DIR/config.yaml"; do
            [[ -f "$c" ]] && grep -q "$USERS_PREFIX" "$c" 2>/dev/null && found=1
        done
        if (( ! found )); then (( json )) && echo '{"status":"purged","removed":0,"ok":true}'; return 0; fi
        _users_save '{"users":[]}' || return 1
    fi
    _users_checkpoint || true
    local cur n rc=0 usage
    cur=$(_users_load) || return 1
    # the last reading, after the checkpoint and under the lock: the panel
    # counts it toward this period before the server goes
    usage=$(_users_usage_of <<<"$cur" 2>/dev/null) || usage=null
    n=$(jq '[.users[]? | select(.managed == true)] | length' <<<"$cur")
    _users_save "$(jq -c '.users |= map(select(.managed != true)) | del(.revision, .revision_fp)' <<<"$cur")" || return 1
    users_apply >/dev/null || rc=1
    if (( json )); then jq -cn --argjson n "$n" --argjson ok "$([[ $rc == 0 ]] && echo true || echo false)" --argjson usage "${usage:-null}" \
        '{status: "purged", removed: $n, ok: $ok, usage: $usage}'
    else echo "removed $n panel users"; fi
    return "$rc"
}

# Each user's counters as the panel reads them (one jq over the store: no
# user's data in any argument). counter_bytes only grows within an epoch.
_users_cmd_usage() {
    local json=0; [[ "${1:-}" == --json ]] && json=1
    local out
    out=$(_users_load | _users_usage_of) || return 1
    if (( json )); then printf '%s\n' "$out"
    else jq -r '.users[] | "\(.name)\t\(.state)\t\(.counter_bytes)"' <<<"$out"; fi
}

# The usage report of the store on stdin.
_users_usage_of() {
    jq -c --argjson now "$(date +%s)" '{revision: (.revision // 0), users: [(.users // [])[] | {
        name, managed: (.managed == true), counter_bytes: (.counter_bytes // 0), counter_epoch: (.counter_epoch // null),
        used_bytes: (.used_bytes // 0), period: (.period // null), local_paused: (.local_paused == true),
        state: (if .enabled == false then "disabled" elif .local_paused == true then "paused_here"
                elif (.expires_at != null and .expires_at <= $now) then "expired"
                elif (.quota_bytes != null and (.used_bytes // 0) >= .quota_bytes) then "over_quota" else "active" end)}]}'
}

# Each active user's client IPs right now, from Xray's online statistics
# (policy statsUserOnline, set with the users). Loopback addresses are left
# out: behind the shared 443 (nginx stream) every client arrives from
# 127.0.0.1, which says nothing about how many devices there are.
_users_cmd_online() {
    local json=0; [[ "${1:-}" == --json ]] && json=1
    local all='[]' n out
    if _users_core_installed xray; then
        # shellcheck source=/dev/null
        source "$LIB_DIR/traffic.sh" 2>/dev/null || true
        for n in $(_users_active_json | jq -r '.[].name'); do
            out=$("$XRAY_BIN" api statsonlineiplist -s "$XRAY_API_ADDR" -email "${USERS_PREFIX}${n}@psm" 2>/dev/null) || continue
            all=$( { printf '%s\n' "$all"; printf '%s\n' "$out"; } | jq -cs --arg n "$n" '.[0] + [{name: $n, ips: (((.[1].ips // {}) | keys)
                | map(select(test("^[0-9a-fA-F:.]{2,45}$") and (test("^127\\.|^::1$|^::ffff:127\\.") | not))) | .[0:128])}]' 2>/dev/null) || true
        done
    fi
    if (( json )); then jq -c '{users: .}' <<<"$all"
    else jq -r '.[] | "\(.name)\t\(.ips | length)\t\(.ips | join(","))"' <<<"$all"; fi
}

psm_users_cli() {
    command -v jq >/dev/null 2>&1 || { _users_err 'jq is required'; return 127; }
    local cmd="${1:-}"
    (( $# )) && shift
    case "$cmd" in
        add)    require_root; _users_cmd_add "$@" ;;
        update) require_root; _users_cmd_update "$@" ;;
        delete|remove|rm) require_root; _users_cmd_delete "$@" ;;
        token)  require_root; _users_cmd_token "$@" ;;
        list)   require_root; _users_cmd_list "$@" ;;
        show)   require_root; _users_cmd_show "$@" ;;
        links)  require_root; _users_cmd_links "$@" ;;
        import) require_root; _users_cmd_import "$@" ;;
        usage)  require_root; _users_cmd_usage "$@" ;;
        online) require_root; _users_cmd_online "$@" ;;
        purge)  require_root; _users_cmd_purge "$@" ;;
        help|--help|-h) _users_usage ;;
        *) _users_usage >&2; return 2 ;;
    esac
}
