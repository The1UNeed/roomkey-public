#!/usr/bin/env bash
# shellcheck disable=SC2218  # stubs are redefined further down on purpose
# A standalone server (ss-rust, snell-server) changed in place: the new release
# and settings replace the running ones only when they come up; otherwise the
# previous binary, settings and service definition all go back, and recovery
# is reported only once the previous service listens again. With no key given
# the key in use is kept.

set -euo pipefail
export LC_ALL=C

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/standalone_cli.sh" >/dev/null 2>&1
fail() { echo "standalone-activate: $*" >&2; exit 1; }

# ── a pretend machine: the "binary" is a script whose first line says whether
# it can start; the service listens on the port of its config while active ──
SS_BIN="$tmp_dir/bin/ss-rust"; SS_CONF="$tmp_dir/etc/ss-rust/config.json"; SS_SERVICE=ss-rust
mkdir -p "$tmp_dir/bin" "$tmp_dir/etc/ss-rust" "$tmp_dir/units"
STATE="$tmp_dir/svc"; : >"$STATE"
_sa_unit_file() { printf '%s/units/%s' "$tmp_dir" "$1"; }
UNIT_FAILS=0
_sa_write_service() { (( UNIT_FAILS )) && return 1; printf 'exec %s %s\n' "$3" "$4" >"$(_sa_unit_file "$1")"; }
svc_stop() { : >"$STATE"; }
ENABLED="$tmp_dir/enabled"; : >"$ENABLED"
svc_enable() { echo on >"$ENABLED"; }; svc_disable() { : >"$ENABLED"; }
svc_is_enabled() { [[ -s "$ENABLED" ]]; }
svc_restart() {
    : >"$STATE"
    [[ -f "$(_sa_unit_file "$1")" ]] || return 1
    grep -q '^# good' "$SS_BIN" 2>/dev/null || return 1
    jq -r '.server_port' "$SS_CONF" >"$STATE"
}
svc_is_active() { [[ -s "$STATE" ]]; }
_sa_port_listening() { [[ "$(cat "$STATE")" == "$1" ]]; }
svc_log_tail() { :; }
firewall_open_port() { :; }
pkg_install() { :; }; ensure_pkg_deps() { :; }
_uses_systemd() { return 1; }
sleep() { :; }
DL=good
_ssrust_fetch_binary() { printf '%s\n' "$DL" >"$2"; chmod +x "$2"; printf 'v9.9.9'; }
openssl() { command openssl "$@"; }

# the running service: release "good" (old), port 8388
printf '#!/bin/sh\n# good old\n' >"$SS_BIN"; chmod +x "$SS_BIN"
k16=$(openssl rand -base64 16)
jq -n --arg k "$k16" '{server: "::", server_port: 8388, password: $k, method: "2022-blake3-aes-128-gcm"}' >"$SS_CONF"
printf 'exec old unit\n' >"$(_sa_unit_file ss-rust)"
svc_restart ss-rust
_sa_port_listening 8388 || fail "fixture service not up"

# 1. the new release cannot start: everything goes back, and it listens again
DL='bad'
# (a binary that cannot even report its version is refused before any stop)
out=$(_sa_install_ss 9000 "$k16" 2022-blake3-aes-128-gcm 2>&1) && fail "an unrunnable download was installed"
[[ "$out" == *"nothing was changed"* ]] || fail "unrunnable download: $out"
_sa_port_listening 8388 || fail "an unrunnable download stopped the service"
# a binary that runs but does not start as a service
DL='#!/bin/sh'
out=$(_sa_install_ss 9000 "$k16" 2022-blake3-aes-128-gcm 2>&1) && fail "a failed start reported success"
grep -q "# good old" "$SS_BIN" || fail "old binary not restored: $(cat "$SS_BIN")"
[[ "$(jq -r .server_port "$SS_CONF")" == 8388 ]] || fail "old config not restored"
[[ "$(cat "$(_sa_unit_file ss-rust)")" == "exec old unit" ]] || fail "old unit not restored"
_sa_port_listening 8388 || fail "previous service not listening after recovery"
[[ "$out" == *"is back and listening on 8388"* ]] || fail "recovery message: $out"
[[ ! -e "$SS_BIN.new" ]] || fail "staged binary left behind"
ls -d "$tmp_dir"/etc/ss-rust/.prev.* >/dev/null 2>&1 && fail "kept copy left after a recovery"

# (it was not enabled at boot before; the failed start enabled it, and the
# recovery put that back)
[[ ! -s "$ENABLED" ]] || fail "a failed install left a disabled service enabled at boot"

# 2. the service definition cannot be written: recovery runs too
DL=$'#!/bin/sh\n# good new'; UNIT_FAILS=1
out=$(_sa_install_ss 9000 "$k16" 2022-blake3-aes-128-gcm 2>&1) && fail "a failed unit write reported success"
UNIT_FAILS=0
grep -q "# good old" "$SS_BIN" || fail "unit failure: old binary not restored"
_sa_port_listening 8388 || fail "unit failure: previous service not back"
[[ "$out" == *"could not write the ss2022 service"*"is back"* ]] || fail "unit failure message: $out"

# 3. the old one cannot come back either: said so, files kept
DL='#!/bin/sh'
printf '#!/bin/sh\n' >"$SS_BIN"   # the old release no longer starts (disk changed under it)
svc_restart() { : >"$STATE"; return 1; }
printf 'x' >"$STATE"   # "active" before
out=$(_sa_install_ss 9000 "$k16" 2022-blake3-aes-128-gcm 2>&1) && fail "double failure reported success"
[[ "$out" == *"did not come back"* ]] || fail "double failure message: $out"
rm -rf "$tmp_dir"/etc/ss-rust/.prev.*
svc_restart() {
    : >"$STATE"
    [[ -f "$(_sa_unit_file "$1")" ]] || return 1
    grep -q '^# good' "$SS_BIN" 2>/dev/null || return 1
    jq -r '.server_port' "$SS_CONF" >"$STATE"
}
printf '#!/bin/sh\n# good old\n' >"$SS_BIN"; svc_restart ss-rust

# 4. success: the new release, settings and version file are in place
DL=$'#!/bin/sh\n# good new'
_sa_install_ss 9000 "$k16" 2022-blake3-aes-128-gcm >/dev/null 2>&1 || fail "a good install failed"
grep -q "# good new" "$SS_BIN" || fail "new binary not in place"
_sa_port_listening 9000 || fail "new service not listening"
[[ "$(cat "$tmp_dir/etc/ss-rust/ver.txt")" == 9.9.9 ]] || fail "version not recorded"

# 5. no key given: the one in use stays (a port or limit edit does not rotate it)
_sa_root() { :; }
_node_cli_port_is_listening() { return 1; }
_node_cli_check_port_conflict() { :; }
hop_port_taken() { return 1; }
before=$(jq -r .password "$SS_CONF")
psm_standalone_cli install ss2022 --port 9001 --method 2022-blake3-aes-128-gcm --json >/dev/null 2>&1 || fail "keyless reinstall failed"
_sa_port_listening 9001 || fail "keyless reinstall not listening on 9001"
[[ "$(jq -r .password "$SS_CONF")" == "$before" ]] || fail "an install with no key rotated it"
# a different method (another key length) gets a key that fits it
psm_standalone_cli install ss2022 --port 9001 --method 2022-blake3-aes-256-gcm --json >/dev/null 2>&1 || fail "method change failed"
[[ "$(jq -r .password "$SS_CONF" | base64 -d | wc -c)" -eq 32 ]] || fail "method change kept a key of the wrong length"

# 6. a Snell key ending in "=" padding reads back whole (show, export, and the
# key a keyless reinstall keeps)
SNELL_MAIN_CONF="$tmp_dir/etc/snell/snell-server.conf"; mkdir -p "$(dirname "$SNELL_MAIN_CONF")"
printf '#version-choice = v5\n[snell-server]\nlisten = ::0:6160\npsk = Ab+/cdEF12==\nipv6 = true\n' >"$SNELL_MAIN_CONF"
[[ "$(_sa_show_json snell | jq -r .psk)" == 'Ab+/cdEF12==' ]] || fail "padded Snell key read as $(_sa_show_json snell | jq -r .psk)"

# 7. a downloaded binary must execute here before anything stops
printf '\177ELFjunk' >"$tmp_dir/notmine"; chmod +x "$tmp_dir/notmine"
! _sa_runs "$tmp_dir/notmine" || fail "a binary that cannot execute here passed"
# an ELF for another CPU (a launcher would hand it to /bin/sh, exit 2)
printf '\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\2\0\076\0' >"$tmp_dir/x86"; chmod +x "$tmp_dir/x86"
PSM_TEST_ARCH=aarch64 _sa_elf_arch_ok "$tmp_dir/x86" && fail "an x86-64 ELF passed on arm64"
PSM_TEST_ARCH=x86_64 _sa_elf_arch_ok "$tmp_dir/x86" || fail "an x86-64 ELF was refused on x86-64"
! PSM_TEST_ARCH=aarch64 _sa_runs "$tmp_dir/x86" || fail "_sa_runs took a binary for another CPU"
# … and an ss-rust download for another CPU is refused before the service stops
: >"$STATE"; printf '8388' >"$STATE"
_ssrust_fetch_binary() { cp "$tmp_dir/x86" "$2"; printf 'v9.9.9'; }
out=$(PSM_TEST_ARCH=aarch64 _sa_install_ss 9002 "$k16" 2022-blake3-aes-128-gcm 2>&1) && fail "a wrong-CPU ss-rust was installed"
[[ "$out" == *"nothing was changed"* && "$(cat "$STATE")" == 8388 ]] || fail "a wrong-CPU download touched the service: $out"
printf '#!/bin/sh\nexit 1\n' >"$tmp_dir/runs"; chmod +x "$tmp_dir/runs"
_sa_runs "$tmp_dir/runs" || fail "a binary that runs (and exits 1 on --help) was refused"

echo "ok: standalone changes swap in only when the new one runs; recovery (boot setting included) is verified; the key stays, padding and all"
