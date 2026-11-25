#!/usr/bin/env bash
# Quota meters, against a simulated iptables:
#  - moving a paused meter lifts only its own pause (a node on the same port
#    number over the other transport stays blocked);
#  - moving a meter keeps its usage (old-port bytes are banked, the new rules
#    count from zero);
#  - pausing an Xray node behind nginx closes only its own backend's sockets,
#    never every connection on the public 443.

set -euo pipefail
export LC_ALL=C

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"; LOG_DIR="$tmp_dir/log"; mkdir -p "$CFG_DIR" "$LOG_DIR"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
XRAY_CFG_DIR="$tmp_dir/xray"; mkdir -p "$XRAY_CFG_DIR"
source "$PSM_ROOT/lib/traffic_cli.sh" >/dev/null 2>&1
XRAY_CFG="$XRAY_CFG_DIR/config.json"
fail() { echo "traffic-move: $*" >&2; exit 1; }

# ── a small iptables: one rule per line, "table|chain|spec|bytes" ──────────
RULES="$tmp_dir/rules"; : >"$RULES"
fake_ipt() {
    local table=filter op="" chain="" spec
    if [[ "$1" == -t ]]; then table="$2"; shift 2; fi
    case "$1" in
        -nvxL) chain="$2"
            if [[ -s "$tmp_dir/fail_lists" ]]; then
                local left; left=$(cat "$tmp_dir/fail_lists"); echo $(( left - 1 )) >"$tmp_dir/fail_lists"
                (( left > 0 )) && return 1
            fi
            awk -F'|' -v t="$table" -v c="$chain" '$1 == t && $2 == c {
                n = split($3, a, " "); cm = ""
                for (i = 1; i < n; i++) if (a[i] == "--comment") cm = a[i + 1]
                printf "0 %s RETURN %s /* %s */ \n", $4, $3, cm }' "$RULES"
            return 0 ;;
        -N) return 0 ;;
        -C|-A|-D|-I) op="$1"; chain="$2"; shift 2 ;;
        *) return 0 ;;
    esac
    [[ "$op" == -I && "$1" =~ ^[0-9]+$ ]] && shift
    spec="$*"
    local line="$table|$chain|$spec|"
    case "$op" in
        -C) # traffic that arrives while an edit runs (between its reads)
            if [[ -n "${MIDWAY:-}" && "$spec" == *psm-in-* && ! -e "$tmp_dir/midway.done" ]]; then
                : >"$tmp_dir/midway.done"; add_bytes "${MIDWAY% *}" "${MIDWAY#* }"
            fi
            grep -qF -- "$line" "$RULES" ;;
        -A|-I) printf '%s0\n' "$line" >>"$RULES" ;;
        -D) grep -qF -- "$line" "$RULES" || return 1
            awk -v l="$line" 'index($0, l) == 1 && !done { done = 1; next } { print }' "$RULES" >"$RULES.n"
            mv "$RULES.n" "$RULES" ;;
    esac
}
_IPT=fake_ipt
ss() { echo "ss $*" >>"$tmp_dir/ss.log"; }
conntrack() { :; }
_trf_ensure_iptables() { :; }
_trf_cli_root() { :; }
_trf_timer_active() { :; }
_trf_stats_enabled() { return 1; }
_trf_enable_stats() { :; }
log_ok() { :; }; log_warn() { :; }; log_info() { :; }

count() { awk -F'|' -v c="$1" 'index($3, "--comment " c " ") || $3 ~ ("--comment " c "$") { s += $4 } END { print s + 0 }' "$RULES"; }
add_bytes() {   # <comment> <bytes> [proto]: traffic through that node's counting rules
    awk -F'|' -v OFS='|' -v c="$1" -v b="$2" -v p="${3:-}" 'index($3, "--comment " c " ") && (p == "" || index($3, "-p " p " ")) { $4 += b } { print }' "$RULES" >"$RULES.n"
    mv "$RULES.n" "$RULES"
}
blocks() { grep -c "^filter|INPUT|.*--dport $1 .*psm-pause-$2 .*REJECT" "$RULES" || true; }
has_block() { grep -q "^filter|INPUT|-p $1 --dport $2 -m comment --comment psm-pause-$3 " "$RULES"; }

# where each node is, as the node store would say
declare -A LOC
_trf_cli_locate() { printf '%s\n' "${LOC[$1]}"; }

# two nodes on port 5000: "u" over UDP, "t" over TCP, both metered
LOC[u]='5000|iptables|5000||udp'; LOC[t]='5000|iptables|5000||tcp'
_trf_cli_set u --limit-bytes 1000 >/dev/null
_trf_cli_set t --limit-bytes 1000 >/dev/null
add_bytes psm-in-u 98; _trf_checkpoint_all
[[ "$(_trf_get u accumulated_bytes)" == 98 ]] || fail "first count: $(_trf_get u accumulated_bytes)"

# both over their quota and paused
add_bytes psm-in-u 1196; add_bytes psm-in-t 2000
_trf_checkpoint_all; _trf_enforce >/dev/null 2>&1
[[ "$(_trf_get u paused)" == true && "$(_trf_get t paused)" == true ]] || fail "not paused: $(cat "$TRAFFIC_STATE")"
has_block udp 5000 u && has_block tcp 5000 t || fail "pause rules: $(cat "$RULES")"
! has_block tcp 5000 u || fail "the UDP node's pause blocked TCP"

# u moves to 6000 with 196 bytes the state has not seen yet
add_bytes psm-in-u 196
before=$(_trf_get u accumulated_bytes)
LOC[u]='6000|iptables|6000||udp'
_trf_cli_set u --limit-bytes 1000 >/dev/null
has_block tcp 5000 t || fail "moving the UDP meter lifted the TCP node's pause: $(cat "$RULES")"
! has_block udp 5000 u || fail "u's old pause stayed on 5000"
has_block udp 6000 u || fail "u's pause did not follow it to 6000"
[[ "$(count psm-in-u)" == 0 ]] || fail "old counting rules survived the move"
[[ "$(_trf_get u accumulated_bytes)" == $(( before + 196 )) ]] || fail "old-port bytes lost: $(_trf_get u accumulated_bytes) want $(( before + 196 ))"
add_bytes psm-in-u 294; _trf_checkpoint_all
[[ "$(_trf_get u accumulated_bytes)" == $(( before + 196 + 294 )) ]] || fail "new-port bytes lost: $(_trf_get u accumulated_bytes) want $(( before + 490 ))"

# a raised limit lifts u's pause only
_trf_cli_set u --limit-bytes 100000 >/dev/null
! has_block udp 6000 u || fail "raised limit kept the pause"
has_block tcp 5000 t || fail "lifting u's pause lifted t's"

# resetting t lifts t's pause and nothing else (and a reset of a UDP node next
# to it would not have touched TCP)
LOC[t2]='5000|iptables|5000||udp'
_trf_cli_set t2 --limit-bytes 10 >/dev/null; add_bytes psm-in-t2 50
_trf_checkpoint_all; _trf_enforce >/dev/null 2>&1
has_block udp 5000 t2 || fail "t2 not paused"
_trf_cli_reset t2 >/dev/null
has_block tcp 5000 t || fail "resetting the UDP node lifted the TCP node's pause"
! has_block udp 5000 t2 || fail "reset kept t2's pause"

# deleting a node: its own rules only
_trf_cleanup_node t >/dev/null
! has_block tcp 5000 t || fail "deleted node's pause stayed"
grep -q 'psm-in-t2 ' "$RULES" || fail "deleting t removed t2's counting rules"

# an edit that moves nothing (a new limit) keeps the checkpoint it took:
# traffic that arrives while it runs is counted, not swallowed
LOC[e]='7000|iptables|7000||udp'
_trf_cli_set e --limit-bytes 100000 >/dev/null
add_bytes psm-in-e 98; _trf_checkpoint_all
rm -f "$tmp_dir/midway.done"; MIDWAY="psm-in-e 98"
_trf_cli_set e --limit-bytes 200000 >/dev/null
MIDWAY=""; _trf_checkpoint_all
[[ "$(_trf_get e accumulated_bytes)" == 196 ]] || fail "traffic during a limit edit was lost: $(_trf_get e accumulated_bytes) want 196"

# a node that drops a transport: the rules that stay keep their baseline, the
# dropped one's last bytes are banked, and arrivals on the kept rule count
LOC[b]='7100|iptables|7100||tcp udp'
_trf_cli_set b --limit-bytes 100000 >/dev/null
add_bytes psm-in-b 100 tcp; add_bytes psm-in-b 50 udp; _trf_checkpoint_all
add_bytes psm-in-b 7 udp
rm -f "$tmp_dir/midway.done"; MIDWAY="psm-in-b 30"
LOC[b]='7100|iptables|7100||tcp'
_trf_cli_set b --limit-bytes 100000 >/dev/null
MIDWAY=""; _trf_checkpoint_all
[[ "$(_trf_get b accumulated_bytes)" == 187 ]] || fail "dropping a transport miscounted: $(_trf_get b accumulated_bytes) want 187"
! grep -q -- '-p udp --dport 7100 .*psm-in-b' "$RULES" || fail "the dropped transport's rule stayed"
add_bytes psm-in-b 13 tcp; _trf_checkpoint_all
[[ "$(_trf_get b accumulated_bytes)" == 200 ]] || fail "the kept rule's later bytes: $(_trf_get b accumulated_bytes) want 200"

# the counters cannot be read before an edit: nothing changes (no guess banked)
cp "$TRAFFIC_STATE" "$tmp_dir/state.before"
LOC[b]='7300|iptables|7300||tcp'
real_ipt=$(declare -f fake_ipt)
fake_ipt() { [[ "$*" == *-nvxL* ]] && return 1; return 0; }
! _trf_cli_set b --limit-bytes 1200 >/dev/null 2>&1 || fail "an edit went on without reading the counters"
cmp -s "$TRAFFIC_STATE" "$tmp_dir/state.before" || fail "a failed read changed the state"
eval "$real_ipt"; LOC[b]='7100|iptables|7100||tcp'

# one poll whose listing fails: no reading, the checkpoint stays (read as zero
# it looked like a counter reset later, and charged everything again)
LOC[f]='7400|iptables|7400||tcp'
_trf_cli_set f --limit-bytes 1200 >/dev/null
add_bytes psm-in-f 900; _trf_checkpoint_all
echo 1 >"$tmp_dir/fail_lists"; _trf_checkpoint_all; : >"$tmp_dir/fail_lists"
_trf_checkpoint_all; _trf_enforce >/dev/null 2>&1
[[ "$(_trf_get f accumulated_bytes)" == 900 && "$(_trf_get f paused)" != true ]] || fail "a failed poll doubled usage: $(_trf_get f accumulated_bytes) paused=$(_trf_get f paused)"

# every read after an edit fails: the next good reading is the new baseline,
# never charged again
LOC[g]='7500|iptables|7500||tcp udp'
_trf_cli_set g --limit-bytes 1200 >/dev/null
add_bytes psm-in-g 800 tcp; add_bytes psm-in-g 100 udp; _trf_checkpoint_all
LOC[g]='7500|iptables|7500||tcp'
sleep() { :; }
# the edit's own first read succeeds; its three reads afterwards fail
fake_ipt_real=$(declare -f fake_ipt)
echo 0 >"$tmp_dir/n_lists"   # (a file: the reads run in subshells)
eval "$(declare -f fake_ipt | sed '1s/fake_ipt/fake_ipt_inner/')"
fake_ipt() {
    if [[ "$*" == *-nvxL* ]]; then
        local n; n=$(( $(cat "$tmp_dir/n_lists") + 1 )); echo "$n" >"$tmp_dir/n_lists"
        (( n >= 2 && n <= 4 )) && return 1
    fi
    fake_ipt_inner "$@"
}
_trf_cli_set g --limit-bytes 1200 >/dev/null 2>&1
eval "$fake_ipt_real"; unset -f sleep
[[ "$(_trf_get g rebase)" == true ]] || fail "lost baseline not marked: $(_trf_get g rebase)"
_trf_checkpoint_all; _trf_enforce >/dev/null 2>&1
[[ "$(_trf_get g accumulated_bytes)" == 900 && "$(_trf_get g paused)" != true ]] || fail "exhausted reads double-counted: $(_trf_get g accumulated_bytes)"
add_bytes psm-in-g 50 tcp; _trf_checkpoint_all
[[ "$(_trf_get g accumulated_bytes)" == 950 ]] || fail "counting did not resume after the new baseline: $(_trf_get g accumulated_bytes)"

# a menu reset waits for a poll that holds the traffic lock (else the poll,
# having read the old total, writes it back after the reset)
if command -v flock >/dev/null 2>&1; then
    mkdir -p "$TRAFFIC_DIR"
    # (this shell took the lock in the edits above: let it go first)
    [[ -n "${_TRF_LOCK_FD:-}" ]] && exec {_TRF_LOCK_FD}>&-
    unset _TRF_LOCKED _TRF_LOCK_FD
    ( exec 9>"$TRAFFIC_DIR/.lock"; timeout 10 flock 9 || exit 1; echo held >"$tmp_dir/held"; command sleep 2 ) &
    for _ in $(seq 1 50); do [[ -e "$tmp_dir/held" ]] && break; command sleep 0.1; done
    [[ -e "$tmp_dir/held" ]] || fail "the poll stand-in could not take the lock"
    t0=$(date +%s)
    grep -q '( _trf_lock; _trf_menu_reset_tag' "$PSM_ROOT/lib/traffic.sh" || fail "the menu reset does not take the lock"
    ( _trf_lock; _trf_menu_reset_tag f )
    (( $(date +%s) - t0 >= 1 )) || fail "the menu reset did not wait for the poll's lock"
    [[ "$(_trf_get f accumulated_bytes)" == 0 ]] || fail "menu reset: $(_trf_get f accumulated_bytes)"
    wait
fi

# a tag's resume never touches a rule PSM did not tag (an admin's own block)
printf 'filter|INPUT|-p tcp --dport 7200 -j REJECT --reject-with tcp-reset|0\n' >>"$RULES"
_trf_iptables_resume 7200 x "tcp udp"
grep -q '^filter|INPUT|-p tcp --dport 7200 -j REJECT' "$RULES" || fail "a tag's resume removed an untagged rule"

# an Xray node behind nginx: its pause closes its 127.0.0.1 backend's sockets
cat >"$XRAY_CFG" <<'EOF'
{"inbounds":[{"tag":"m","listen":"127.0.0.1","port":20001,"protocol":"vless"},
             {"tag":"h","port":443,"protocol":"hysteria"}],
 "outbounds":[{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[]}}
EOF
psm_file_replace() { cat "$2" >"$1"; }
xray_test_restart() { :; }
LOC[m]='443|xray|20001||tcp'; LOC[h]='443|xray|443||udp'
_trf_cli_set m --limit-bytes 10 >/dev/null; _trf_cli_set h --limit-bytes 10 >/dev/null
: >"$tmp_dir/ss.log"
_trf_pause_tag m >/dev/null 2>&1
grep -q 'sport = :20001' "$tmp_dir/ss.log" || fail "mounted pause closed nothing: $(cat "$tmp_dir/ss.log")"
! grep -q 'sport = :443' "$tmp_dir/ss.log" || fail "mounted pause closed every connection on 443"
jq -e '.routing.rules[0] | .outboundTag == "blocked" and .inboundTag == ["m"]' "$XRAY_CFG" >/dev/null || fail "no blackhole rule"
: >"$tmp_dir/ss.log"
_trf_pause_tag h >/dev/null 2>&1
[[ ! -s "$tmp_dir/ss.log" ]] || fail "UDP Xray pause closed TCP sockets: $(cat "$tmp_dir/ss.log")"

# an Xray port edit: the tag's counter survives, so the banked checkpoint stays
XQ=100
_trf_stats_enabled() { return 0; }
_trf_query_bytes() { echo "$XQ"; XQ=150; }
LOC[xp]='9000|xray|9000||tcp'
_trf_cli_set xp --limit-bytes 100000 >/dev/null 2>&1   # newly metered: baseline 100 (then 150 arrives)
XQ=150; _trf_query_bytes() { echo "$XQ"; }
_trf_checkpoint_all
a1=$(_trf_get xp accumulated_bytes)
XQ=200; _trf_query_bytes() { echo "$XQ"; XQ=260; }    # 60 more arrive during the edit
LOC[xp]='9100|xray|9100||tcp'
_trf_cli_set xp --limit-bytes 100000 >/dev/null 2>&1
_trf_query_bytes() { echo 260; }; _trf_checkpoint_all
[[ "$(_trf_get xp accumulated_bytes)" == $(( a1 + 110 )) ]] || fail "an Xray port edit lost traffic: $(_trf_get xp accumulated_bytes) want $(( a1 + 110 ))"
_trf_stats_enabled() { return 1; }

echo "ok: meters keep usage (across moves, transport changes and edits) and their own pause; a mounted pause closes only its backend"
