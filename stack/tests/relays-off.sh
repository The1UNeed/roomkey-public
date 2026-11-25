#!/usr/bin/env bash
# roomkey runs no relays: psm relay add/update are refused, `psm relay off`
# removes every rule and leaves realm and gost verified stopped and disabled,
# and an engine whose state can't be read never counts as stopped.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
LIB_DIR="$PSM_ROOT/lib"
mkdir -p "$CFG_DIR/realm"
# the engines' files (unit, binary, generated config) live here, not in /
export PSM_FS_ROOT="$tmp_dir/root"
fail() { echo "relays-off: $*" >&2; exit 1; }

# One run in a subshell, with the service manager simulated.
#   $1 the store before; $2 "works" | "stays" (an engine stays up) | "mute"
#   (the manager answers nothing) → "<rc> <tags left in the store>"
run_off() {
    local store="$1" mode="$2"
    printf '%s\n' "$store" >"$CFG_DIR/realm/rules.json"
    ( set -euo pipefail
      source "$LIB_DIR/relay_cli.sh"
      source "$LIB_DIR/coreperm.sh"
      up=1
      _coreperm_svc_state() { case "$mode" in mute) echo unknown ;; stays) echo active ;; *) if (( up )); then echo active; else echo inactive; fi ;; esac; }
      _coreperm_svc_boot() { case "$mode" in mute) echo unknown ;; *) if (( up )); then echo enabled; else echo disabled; fi ;; esac; }
      svc_stop() { echo "stop $1" >>"$tmp_dir/actions"; up=0; }
      svc_disable() { :; }
      svc_restart() { echo "restart $1" >>"$tmp_dir/actions"; }
      svc_enable() { echo "enable $1" >>"$tmp_dir/actions"; }
      _relay_engine_apply() { echo "apply $1" >>"$tmp_dir/actions"; }
      _relay_limits_remove() { :; }; _relay_meter_remove() { :; }
      _relay_fw_close() { echo "close $1" >>"$tmp_dir/actions"; }
      : >"$tmp_dir/actions"
      rc=0; psm_relays_off --json >/dev/null 2>&1 || rc=$?
      echo "$rc $(jq -r '[.[].tag] | join(",")' "$CFG_DIR/realm/rules.json" 2>/dev/null)" )
}
two='[{"tag":"a","listen_port":30001,"engine":"realm"},{"tag":"b","listen_port":30002,"engine":"gost"}]'
out=$(run_off "$two" works); [[ "$out" == "0 " ]] || fail "two rules, engines stop: got '$out'"
# both rules' openings closed, the engines stopped before that, nothing ever restarted or applied
acts=$(tr '\n' ' ' <"$tmp_dir/actions")
[[ "$acts" == "stop realm stop psm-gost close 30001 close 30002 " ]] || fail "two rules: actions '$acts'"
same='[{"tag":"x","listen_port":30005,"engine":"realm"},{"tag":"y","listen_port":30006,"engine":"realm"},{"tag":"z z","listen_port":30007,"engine":"realm"}]'
out=$(run_off "$same" works); [[ "$out" == "0 " ]] || fail "three rules on one engine: got '$out'"
acts=$(tr '\n' ' ' <"$tmp_dir/actions")
[[ "$acts" != *restart* && "$acts" != *apply* && "$acts" == *"close 30005 close 30006 close 30007"* ]] || fail "three rules: actions '$acts'"
out=$(run_off "$two" stays); [[ "${out%% *}" == 2 ]] || fail "an engine that stays up must be unsafe (2): got '$out'"
out=$(run_off "$two" mute);  [[ "${out%% *}" == 2 ]] || fail "a service manager that says nothing must be unsafe (2): got '$out'"
out=$(run_off '[]' works);   [[ "$out" == "0 " ]] || fail "nothing to remove: got '$out'"
# an unreadable store: with the engines gone nothing in it can run; it is replaced
out=$(run_off 'not json' works); [[ "$out" == "0 " ]] || fail "an unreadable store, engines gone: got '$out'"
out=$(run_off '[{"tag":"with space","listen_port":30009,"engine":"realm"}]' works); [[ "$out" == "0 " ]] || fail "a tag with a space (older menu): got '$out'"
# a store that could not be emptied is no removal
out=$( printf '%s\n' "$two" >"$CFG_DIR/realm/rules.json"
       source "$LIB_DIR/relay_cli.sh"; source "$LIB_DIR/coreperm.sh"
       _coreperm_svc_state() { echo inactive; }; _coreperm_svc_boot() { echo disabled; }
       _relay_load_gost   # loaded now, so the stub below stays
       _realm_save() { return 1; }
       rc=0; psm_relays_off --json >/dev/null 2>&1 || rc=$?; echo "$rc" )
[[ "$out" == 2 ]] || fail "a store that could not be emptied must be unsafe: got '$out'"

# nothing adds a rule: the CLI and the store writer both refuse
printf '[]\n' >"$CFG_DIR/realm/rules.json"
( source "$LIB_DIR/relay_cli.sh"
  if psm_relay_cli add --json '{"tag":"x","listen_port":30003}' >/dev/null 2>&1; then exit 1; fi
  if psm_relay_cli update x --json '{"listen_port":30004}' >/dev/null 2>&1; then exit 1; fi
  if _realm_upsert '{"tag":"x","listen_port":30003}' >/dev/null 2>&1; then exit 1; fi
  exit 0 ) || fail "a relay could be added"
jq -e 'length == 0' "$CFG_DIR/realm/rules.json" >/dev/null || fail "the store gained a rule: $(cat "$CFG_DIR/realm/rules.json")"

# the last rule's removal needs realm shown down: an unreadable state is a failure
rc=0
( source "$LIB_DIR/relay_cli.sh"; source "$LIB_DIR/coreperm.sh"
  _coreperm_svc_state() { echo unknown; }; _coreperm_svc_boot() { echo unknown; }
  svc_stop() { :; }; svc_disable() { :; }
  _realm_apply >/dev/null 2>&1 ) || rc=$?
[[ "$rc" != 0 ]] || fail "realm with no rule and an unreadable state counted as stopped"
rc=0
( source "$LIB_DIR/relay_cli.sh"; source "$LIB_DIR/coreperm.sh"
  _coreperm_svc_state() { echo unknown; }; _coreperm_svc_boot() { echo unknown; }
  svc_stop() { :; }; svc_disable() { :; }
  gost_apply >/dev/null 2>&1 ) || rc=$?
[[ "$rc" != 0 ]] || fail "gost with no rule and an unreadable state counted as stopped"

# a removal whose engine reload fails keeps the rule, so a retry can finish it
printf '%s\n' "$two" >"$CFG_DIR/realm/rules.json"
rc=0
( source "$LIB_DIR/relay_cli.sh"
  _relay_limits_remove() { :; }; _relay_fw_close() { :; }; _relay_meter_remove() { :; }
  _relay_engine_apply() { return 1; }
  _relay_remove a 0 1 >/dev/null 2>&1 ) || rc=$?
[[ "$rc" != 0 ]] || fail "a removal whose engine did not reload succeeded"
jq -e '[.[].tag] == ["a","b"]' "$CFG_DIR/realm/rules.json" >/dev/null || fail "a failed removal lost the rule: $(cat "$CFG_DIR/realm/rules.json")"

# a retry for a rule already gone reloads every engine, not only an empty one
printf '[{"tag":"b","listen_port":30002,"engine":"realm"}]\n' >"$CFG_DIR/realm/rules.json"
out=$( source "$LIB_DIR/relay_cli.sh"
       _relay_engine_apply() { echo "$1" >>"$tmp_dir/applied"; }
       : >"$tmp_dir/applied"; _relay_remove a 1 1 >/dev/null 2>&1; tr '\n' ' ' <"$tmp_dir/applied" )
[[ "$out" == "realm gost " ]] || fail "a missing-tag retry applied: '$out' (want both engines)"
out=$( source "$LIB_DIR/relay_cli.sh"
       _relay_engine_apply() { [[ $1 == realm ]] && return 1; return 0; }
       _relay_remove a 1 1 >/dev/null 2>&1 && echo ok || echo failed )
[[ "$out" == failed ]] || fail "a missing-tag retry with an engine that did not reload counted as absent"

# psm doctor: a relay rule is critical and fixable, --fix takes it off, the recheck is clean
out=$( printf '%s\n' "$two" >"$CFG_DIR/realm/rules.json"
       source "$LIB_DIR/doctor.sh"; source "$LIB_DIR/relay_cli.sh"; source "$LIB_DIR/coreperm.sh"; _relay_load_gost
       _coreperm_svc_state() { echo inactive; }; _coreperm_svc_boot() { echo disabled; }
       svc_is_active() { return 1; }
       _relay_limits_remove() { :; }; _relay_meter_remove() { :; }; _relay_fw_close() { :; }
       _relay_load_gost() { :; }
       _doctor_reset; _doctor_check_relays
       first="${_DOCTOR_STATUSES[0]} $(_doctor_fixable_count) $(_doctor_summary | cut -f1)"
       _doctor_apply_fixes >/dev/null 2>&1
       _doctor_reset; _doctor_check_relays
       echo "$first | ${_DOCTOR_STATUSES[0]} ${_DOCTOR_FIX_RESULTS[0]:-none} $(jq length "$CFG_DIR/realm/rules.json")" )
[[ "$out" == "critical 1 critical | ok none 0" || "$out" == "critical 1 critical | ok ok 0" ]] || fail "doctor: got '$out'"

# withdrawal takes the engines off for good: unit, binary and generated config
# gone; a file beside them that PSM did not write stays
mk_engines() {
    mkdir -p "$PSM_FS_ROOT/etc/realm" "$PSM_FS_ROOT/etc/psm-gost" "$PSM_FS_ROOT/etc/systemd/system" "$PSM_FS_ROOT/usr/local/bin"
    printf '[[endpoints]]\nlisten = "0.0.0.0:30001"\n' >"$PSM_FS_ROOT/etc/realm/config.toml"
    printf '{"services":[{"addr":":30002"}]}\n' >"$PSM_FS_ROOT/etc/psm-gost/config.json"
    : >"$PSM_FS_ROOT/etc/systemd/system/realm.service"; : >"$PSM_FS_ROOT/etc/systemd/system/psm-gost.service"
    : >"$PSM_FS_ROOT/usr/local/bin/realm"; : >"$PSM_FS_ROOT/usr/local/bin/psm-gost"
    echo inventory >"$PSM_FS_ROOT/etc/realm/notes.txt"
}
mk_engines
out=$(run_off "$two" works); [[ "$out" == "0 " ]] || fail "withdrawal with engine files: got '$out'"
left=$(cd "$PSM_FS_ROOT" && find . -type f | sort | tr '\n' ' ')
[[ "$left" == "./etc/realm/notes.txt " ]] || fail "after withdrawal: left '$left' (want only the foreign file)"
# engines that won't go: nothing else changes (not even their files), so a retry still has every rule
mk_engines
out=$(run_off "$two" stays); [[ "$out" == "2 a,b" ]] || fail "engines up: the store must stay for the retry: got '$out'"
[[ -f "$PSM_FS_ROOT/etc/systemd/system/realm.service" && -f "$PSM_FS_ROOT/etc/realm/config.toml" ]] || fail "engines up: their files were deleted"
rm -rf "$PSM_FS_ROOT"

echo "ok: relays off"
