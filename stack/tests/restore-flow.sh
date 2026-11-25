#!/usr/bin/env bash
# psm restore, end to end against a pretend machine:
#  - a restore that stops half way, tried again, starts what ran before the
#    first try (and leaves what was stopped stopped);
#  - certificates nginx rejects go back, and the restore says it failed;
#  - a selective backup of Docker volumes alone is a backup.

set -euo pipefail
export LC_ALL=C

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/psm/config"; mkdir -p "$CFG_DIR"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/backup.sh" >/dev/null 2>&1
fail() { echo "restore-flow: $*" >&2; exit 1; }

BAK_ROOT="$tmp_dir/backups"; XRAY_CFG_DIR="$tmp_dir/xray"; NGINX_SSL_DIR="$tmp_dir/ssl"
mkdir -p "$BAK_ROOT" "$XRAY_CFG_DIR" "$NGINX_SSL_DIR"
SVC="$tmp_dir/svc"; mkdir -p "$SVC"
svc_is_active() { [[ -e "$SVC/$1" ]]; }
svc_stop() { rm -f "$SVC/$1"; }
svc_start() { : >"$SVC/$1"; }
BOOT="$tmp_dir/boot"; mkdir -p "$BOOT"
svc_is_enabled() { [[ -e "$BOOT/$1" ]]; }; svc_enable() { : >"$BOOT/$1"; }; svc_disable() { rm -f "$BOOT/$1"; }
ask() { printf -v "$1" '%s' "$PICK"; }
ask_yn() { return 0; }
list_backups() { :; }
do_quick_backup() { echo "$BAK_ROOT/pre"; }
log_info() { :; }; log_ok() { :; }
NGINX_OK=1
nginx() { [[ "$1" == -t ]] && (( NGINX_OK )); }

# a backup: Xray settings and a certificate
b="$BAK_ROOT/20260101_000000_quick"; mkdir -p "$b/xray" "$b/ssl"
echo '{"from":"backup"}' >"$b/xray/config.json"
echo 'cert from backup' >"$b/ssl/n1.pem"; touch -d '2030-01-01' "$b/ssl/n1.pem"
PICK=20260101_000000_quick

# nginx and xray run (nginx enabled at boot), hysteria does not
: >"$SVC/nginx"; : >"$SVC/xray"; : >"$BOOT/nginx"
# 1. the stores cannot be put right once (a full disk): it fails, and the
# cores stay down
real_relay=$(declare -f _restore_relay_store)
_restore_relay_store() { return 1; }
out=$(printf '2\n' | do_restore 2>&1) && fail "a restore whose stores failed reported success"
[[ ! -e "$SVC/nginx" && ! -e "$SVC/xray" ]] || fail "services started after a failed restore"
# … and none comes back at a reboot meanwhile: off boot until a restore finishes
[[ ! -e "$BOOT/nginx" ]] || fail "nginx stays enabled at boot while the restore is unfinished"
# 2. the cause fixed, tried again: what ran before the first try runs again
eval "$real_relay"
out=$(printf '2\n' | do_restore 2>&1) || fail "the retry failed: $out"
[[ -e "$SVC/nginx" && -e "$SVC/xray" ]] || fail "the retry left nginx/xray down: $(ls "$SVC")"
[[ ! -e "$SVC/hysteria-server" ]] || fail "the retry started hysteria, which was not running"
[[ ! -e "$RESTORE_SERVICES_FILE" ]] || fail "the service list stayed after a full recovery"
[[ -e "$BOOT/nginx" && ! -e "$BOOT/xray" ]] || fail "boot settings not put back as they were: $(ls "$BOOT")"
[[ "$(jq -r .from "$XRAY_CFG_DIR/config.json")" == backup ]] || fail "xray not restored"

# 3. certificates nginx rejects: the ones here go back, the restore fails,
# and nginx runs again
echo 'cert here' >"$NGINX_SSL_DIR/n1.pem"; touch -d '2020-01-01' "$NGINX_SSL_DIR/n1.pem"
NGINX_OK=0
out=$(printf '5\n' | do_restore 2>&1) && fail "a rejected certificate restore reported success: $out"
[[ "$(cat "$NGINX_SSL_DIR/n1.pem")" == 'cert here' ]] || fail "the previous certificate did not come back"
[[ "$out" == *"could not be restored"* ]] || fail "no failure said: $out"
[[ -e "$SVC/nginx" ]] || fail "nginx not started again after the certificate rollback"
NGINX_OK=1

# 4. the list of what runs cannot be written: nothing stops, nothing restored
: >"$SVC/nginx"
real_mktemp=$(declare -f mktemp || true)
mktemp() { if [[ "${1:-}" == "$RESTORE_SERVICES_FILE".* ]]; then return 1; fi; command mktemp "$@"; }
out=$(printf '2\n' | do_restore 2>&1) && fail "a restore that could not note its services went on"
[[ -e "$SVC/nginx" ]] || fail "nginx was stopped although the list could not be written"
unset -f mktemp; [[ -z "$real_mktemp" ]] || eval "$real_mktemp"

# 4a. the service manager does not stop a service: nothing is copied, and
# what was already changed is put back
: >"$SVC/nginx"; : >"$SVC/xray"; : >"$BOOT/nginx"
echo '{"from":"here"}' >"$XRAY_CFG_DIR/config.json"
real_stop=$(declare -f svc_stop)
svc_stop() { [[ "$1" == xray ]] && return 1; rm -f "$SVC/$1"; }
out=$(printf '2\n' | do_restore 2>&1) && fail "a restore went on with a service still running"
[[ "$out" == *"xray (still running)"* ]] || fail "the stubborn service was not named: $out"
[[ "$(jq -r .from "$XRAY_CFG_DIR/config.json")" == here ]] || fail "files were restored with a service still running"
[[ -e "$SVC/nginx" && -e "$BOOT/nginx" && ! -e "$RESTORE_SERVICES_FILE" ]] || fail "nginx not put back as it was: svc=$(ls "$SVC") boot=$(ls "$BOOT")"
eval "$real_stop"

# 4b. a directory where the list goes: refused before anything stops
mkdir "$RESTORE_SERVICES_FILE"
out=$(printf '2\n' | do_restore 2>&1) && fail "a restore went on with a directory for its list"
[[ -e "$SVC/nginx" ]] || fail "nginx was stopped although the list could not be written"
rmdir "$RESTORE_SERVICES_FILE"

# 5. a restore left unfinished, then a retry that cannot get the user lock:
# nothing it stopped starts while the restore is unfinished
_restore_relay_store() { return 1; }
out=$(printf '2\n' | do_restore 2>&1) && fail "store failure reported success"
[[ ! -e "$SVC/nginx" ]] || fail "nginx up after a failed restore"
eval "$real_relay"
real_lock=$(declare -f _restore_keep_begin)
_restore_keep_begin() { return 1; }    # stands in for "the lock is held" (exit 1 path)
: >"$SVC/hysteria-server"   # something running now
out=$(printf '2\n' | do_restore 2>&1) && fail "a retry without the lock reported success"
[[ ! -e "$SVC/nginx" ]] || fail "a retry that did not finish started nginx while the restore was unfinished: $out"
eval "$real_lock"
out=$(printf '2\n' | do_restore 2>&1) || fail "the final retry failed: $out"
[[ -e "$SVC/nginx" && -e "$SVC/xray" && -e "$SVC/hysteria-server" ]] || fail "the final retry left services down: $(ls "$SVC")"

# 6. a selective backup of Docker volumes alone is one
mkdir -p "$tmp_dir/dv/docker_volumes"; : >"$tmp_dir/dv/docker_volumes/v.tar.gz"
_restore_layout_ok "$tmp_dir/dv" || fail "a Docker-volumes-only backup was refused"
mkdir -p "$tmp_dir/dv/files"
! _restore_layout_ok "$tmp_dir/dv" || fail "a migration layout passed"
# … a damaged volume archive leaves the live volume as it was; a good one
# replaces it (the helper container's command, run here with its mounts mapped)
VOL="$tmp_dir/vol"; mkdir -p "$VOL"; echo keep >"$VOL/data"
docker() {
    local a vol_src="" bak="" cmd=""
    [[ "$1" == volume ]] && return 0
    while (( $# )); do case "$1" in -v) case "$2" in *:/vol_data*) vol_src="$VOL" ;; *:/backup*) bak="${2%%:*}" ;; esac; shift 2 ;; -c) cmd="$2"; shift 2 ;; *) shift ;; esac; done
    cmd="${cmd//\/vol_data/$vol_src}"; cmd="${cmd//\/backup/$bak}"; cmd="${cmd//\/psm-new/$tmp_dir/psm-new}"
    rm -rf "$tmp_dir/psm-new"; sh -c "$cmd"
}
mkdir -p "$tmp_dir/dv2/docker_volumes"; printf 'not a tarball' >"$tmp_dir/dv2/docker_volumes/v.tar.gz"
( source "$PSM_ROOT/lib/docker/backup.sh" >/dev/null 2>&1; ! docker_restore_volumes "$tmp_dir/dv2" >/dev/null 2>&1 ) || fail "a damaged volume archive reported success"
[[ "$(cat "$VOL/data" 2>/dev/null)" == keep ]] || fail "a damaged archive erased the live volume"
mkdir -p "$tmp_dir/newvol"; echo fresh >"$tmp_dir/newvol/data2"; tar -czf "$tmp_dir/dv2/docker_volumes/v.tar.gz" -C "$tmp_dir/newvol" .
( source "$PSM_ROOT/lib/docker/backup.sh" >/dev/null 2>&1; docker_restore_volumes "$tmp_dir/dv2" >/dev/null 2>&1 ) || fail "a good volume archive failed"
[[ "$(cat "$VOL/data2")" == fresh && ! -e "$VOL/data" ]] || fail "a good archive did not replace the volume: $(ls "$VOL")"
unset -f docker

# … and restoring volumes without Docker fails rather than reporting success
source "$PSM_ROOT/lib/docker/backup.sh" >/dev/null 2>&1
( command() { [[ "$1 $2" == "-v docker" ]] && return 1; builtin command "$@"; }
  ! docker_restore_volumes "$tmp_dir/dv" >/dev/null 2>&1 ) || fail "volumes 'restored' without Docker"

echo "ok: a retried restore starts what ran before, never while unfinished; the service list is written first; failed parts fail the restore"
