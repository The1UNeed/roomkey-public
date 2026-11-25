#!/usr/bin/env bash
# psm guard's hook detection: a unit counts as checked only with an executable
# ExecStartPre running coreperm.sh for that core. Upstream's systemd 219 unit
# names coreperm.sh in a comment and has no ExecStartPre at all.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/coreperm.sh"
fail() { echo "guard-hook: $*" >&2; exit 1; }

_PSM_INIT=systemd
# upstream main's 219 unit, as its own psm_core_unit_lines wrote it
cat >"$tmp_dir/upstream.service" <<'UNIT'
[Service]
# systemd older than 231: too old to start the core unprivileged (lib/coreperm.sh).
# Root keeps all its capabilities: files a newer PSM gave to psm-core stay readable.
User=root
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray
UNIT
if _coreperm_has_hook "$tmp_dir/upstream.service" xray; then fail "a comment naming coreperm.sh counted as a hook"; fi

for v in 219 250; do
    { echo '[Service]'; PSM_SYSTEMD_VERSION=$v psm_core_unit_lines xray; echo 'ExecStart=/usr/local/bin/xray run'; } >"$tmp_dir/v$v.service"
    _coreperm_has_hook "$tmp_dir/v$v.service" xray || fail "systemd $v: the unit PSM writes was not recognised"
    if _coreperm_has_hook "$tmp_dir/v$v.service" sing-box; then fail "systemd $v: xray's hook counted for sing-box"; fi
done

# a commented-out directive is no hook either
sed 's/^ExecStartPre=/#ExecStartPre=/' "$tmp_dir/v250.service" >"$tmp_dir/off.service"
if _coreperm_has_hook "$tmp_dir/off.service" xray; then fail "a commented-out ExecStartPre counted"; fi

# OpenRC: start_pre running it, comments ignored
_PSM_INIT=openrc
printf '#!/sbin/openrc-run\n# runs lib/coreperm.sh xray before start\nstart_pre() { :; }\n' >"$tmp_dir/rc-off"
if _coreperm_has_hook "$tmp_dir/rc-off" xray; then fail "OpenRC: a comment counted"; fi
printf '#!/sbin/openrc-run\nstart_pre() {\n    /bin/bash /opt/psm/lib/coreperm.sh xray || return 1\n}\n' >"$tmp_dir/rc-on"
_coreperm_has_hook "$tmp_dir/rc-on" xray || fail "OpenRC: start_pre not recognised"

# psm guard's outcomes, with the service manager simulated. Run as manager.sh
# runs it (errexit): a unit writer that fails must not end the guard before
# the core is stopped, and only a verified stop is "stopped" (10).
guard_case() {   # <unit writer's exit code> <1: stopping works, 0: the core stays up> [1: the service manager can't answer] → "<guard exit> <actions>"
    local writer_rc="$1" stop_works="$2" mute="${3:-0}"
    ( set -euo pipefail
      _PSM_INIT=systemd; PSM_SYSTEMD_DIR="$tmp_dir/units"; mkdir -p "$PSM_SYSTEMD_DIR"
      CFG_DIR="$tmp_dir/config"   # the relay check reads (and makes) its store here
      PSM_PROC_DIR="$tmp_dir/noproc"; mkdir -p "$PSM_PROC_DIR"   # no stray proxies
      # an ordinary boot service (sshd), last in the list: never a reason to stop
      mkdir -p "$PSM_SYSTEMD_DIR/multi-user.target.wants"
      printf '[Service]\nExecStart=/usr/sbin/sshd -D\n' >"$PSM_SYSTEMD_DIR/ssh.service"
      ln -sf ../ssh.service "$PSM_SYSTEMD_DIR/multi-user.target.wants/zz-ssh.service"
      export PSM_FS_ROOT="$tmp_dir/fsroot"                        # relay engine files: none
      cp "$tmp_dir/upstream.service" "$PSM_SYSTEMD_DIR/xray.service"
      XRAY_BIN="$tmp_dir/xray"; printf '#!/bin/sh\n' >"$XRAY_BIN"; chmod +x "$XRAY_BIN"
      SINGBOX_BIN=/nonexistent; MIHOMO_BIN=/nonexistent
      active=1; enabled=1; log="$tmp_dir/actions"; : >"$log"
      svc_exists() { [[ $1 == xray ]]; }   # only Xray is installed
      svc_is_active() { (( active )); }
      svc_is_enabled() { (( enabled )); }
      _coreperm_svc_state() { if [[ $1 != xray ]]; then echo inactive; elif (( mute )); then echo unknown; elif (( active )); then echo active; else echo inactive; fi; }
      _coreperm_svc_boot() { if [[ $1 != xray ]]; then echo disabled; elif (( mute )); then echo unknown; elif (( enabled )); then echo enabled; else echo disabled; fi; }
      svc_stop() { [[ $1 == xray ]] || return 0; echo stop >>"$log"; (( stop_works )) && active=0; return 0; }
      svc_disable() { [[ $1 == xray ]] || return 0; echo disable >>"$log"; enabled=0; }
      svc_restart() { echo restart >>"$log"; }
      docker() { return 0; }   # a Docker with no containers
      # a service manager with no relay engine loaded (realm, psm-gost: not found)
      systemctl() { [[ "${1:-}" == show && "$*" == *LoadState* ]] && echo LoadState=not-found; return 0; }
      psm_users_merge() { return 0; }
      # the writers live in lib/*/core.sh, which the guard sources: replaced right after
      source() { builtin source "$@"; _write_xray_service() { echo write >>"$log"; return "$writer_rc"; }; }
      rc=0; psm_guard_all --json >"$tmp_dir/guard.out" 2>&1 || rc=$?
      echo "$rc $(tr '\n' ' ' <"$log")" )
}
out=$(guard_case 1 1)
[[ "$out" == "10 write stop disable " ]] || cat "$tmp_dir/guard.out" >&2
[[ "$out" == "10 write stop disable " ]] || fail "a failing unit writer, core stopped and disabled: got '$out' (want 10)"
out=$(guard_case 1 0)
[[ "${out%% *}" == 2 ]] || fail "a failing unit writer and a core that won't stop must be unsafe (2): got '$out'"
out=$(guard_case 1 1 1)
[[ "${out%% *}" == 2 ]] || fail "a service manager that can't say the core stopped must be unsafe (2), not stopped: got '$out'"

# The real state readers: only a clear answer is "inactive" or "disabled".
state_of() {   # <init> <manager output> <manager rc> <processes, or "x": unreadable> → state/boot
    ( _PSM_INIT=$1; out=$2; mrc=$3; sim_procs=$4; PSM_INITD_DIR="${INITD:-$tmp_dir/initd}"
      systemctl() { [[ -n "$out" ]] && printf '%s\n' "$out"; return "$mrc"; }
      rc-service() { return "$mrc"; }
      rc-update() { [[ -n "$out" ]] && printf '%s\n' "$out"; return 0; }
      _coreperm_procs() { [[ $sim_procs == x ]] && return 1; echo "$sim_procs"; }
      echo "$(_coreperm_svc_state xray)/$(_coreperm_svc_boot xray)" )
}
check_state() { local got; got=$(state_of "${@:1:4}"); [[ "$got" == "$5" ]] || fail "$6: got $got, want $5"; }
check_state systemd $'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled' 0 0 inactive/disabled "systemd, stopped and disabled"
check_state systemd $'LoadState=loaded\nActiveState=active\nUnitFileState=enabled' 0 1 active/enabled "systemd, running"
check_state systemd '' 0 0 unknown/unknown "systemd answering nothing"
check_state systemd $'LoadState=loaded\nActiveState=\nUnitFileState=' 0 0 unknown/unknown "systemd, empty values for a loaded unit"
check_state systemd $'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled' 1 0 unknown/unknown "systemctl failing"
check_state systemd $'LoadState=not-found\nActiveState=inactive\nUnitFileState=' 0 0 inactive/disabled "no unit at all"
check_state systemd $'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled' 0 2 unknown/disabled "a core process outside its service"
check_state systemd $'LoadState=loaded\nActiveState=inactive\nUnitFileState=disabled' 0 x unknown/disabled "an unreadable process table"
check_state systemd $'LoadState=loaded\nActiveState=inactive\nUnitFileState=bad-setting' 0 0 inactive/unknown "an unknown unit file state"
mkdir -p "$tmp_dir/initd" && : >"$tmp_dir/initd/xray"   # OpenRC has the service
check_state openrc $'  xray | default boot' 3 0 inactive/enabled "OpenRC, stopped but in a runlevel"
check_state openrc $'  xray |' 3 0 inactive/disabled "OpenRC, in no runlevel"
check_state openrc $'  xray | boot' 0 1 active/enabled "OpenRC, in the boot runlevel only"
check_state openrc '' 1 0 unknown/unknown "OpenRC answering nothing"
check_state openrc $'  xray |' 32 0 unknown/disabled "OpenRC, crashed"
INITD="$tmp_dir/none" check_state openrc $'  other | default' 1 0 inactive/disabled "OpenRC with no such service"
INITD="$tmp_dir/none" check_state openrc $'  other | default' 1 1 unknown/disabled "OpenRC with no such service, but its process runs"

# Proxies outside PSM's checked services: another panel's own xray copy, a
# core started with another config, a second instance of PSM's command line,
# or PSM's core with configuration added through its environment
proc="$tmp_dir/proc"; mkdir -p "$proc/101" "$proc/202" "$proc/303" "$proc/404" "$proc/505" "$proc/606"
fake() { local pid="$1" comm="$2"; shift 2; printf '%s\n' "$comm" >"$proc/$pid/comm"; printf '%s\0' "$@" >"$proc/$pid/cmdline"; : >"$proc/$pid/environ"; }
psmx=(/usr/local/bin/xray run -config /usr/local/etc/xray/config.json)
fake 101 xray "${psmx[@]}"
fake 202 xray-linux-amd6 /usr/local/x-ui/bin/xray-linux-amd64 -c /usr/local/x-ui/bin/config.json
fake 303 xray /usr/local/bin/xray run -confdir /usr/local/etc/xray/
fake 404 nginx nginx -g daemon off
fake 505 xray "${psmx[@]}"
fake 606 sing-box /usr/local/bin/sing-box run -c /etc/sing-box/config.json
printf 'XRAY_LOCATION_CONFDIR=/etc/xray.d\0' >"$proc/606/environ"
strays=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray SINGBOX_BIN=/usr/local/bin/sing-box SINGBOX_CFG_DIR=/etc/sing-box \
          PSM_PROC_DIR="$proc" PSM_STRAY_WAIT=0
          _coreperm_main_pids() { case "$1" in xray) echo 101 ;; sing-box) echo 606 ;; esac; }
          _coreperm_strays )
got=$(cut -d: -f1 <<<"$strays" | sort | tr '\n' ' ')
[[ "$got" == "202 303 505 606 " ]] || fail "stray proxies: got '$got' ($strays)"
# a process that is gone by the next look (PSM's own stats query) is not one
strays=$( PSM_PROC_DIR="$proc" PSM_STRAY_WAIT=0
          : >"$tmp_dir/looks"
          _coreperm_strays_once() { echo . >>"$tmp_dir/looks"; [[ "$(wc -l <"$tmp_dir/looks")" -eq 1 ]] && echo "707: xray api statsquery"; return 0; }
          _coreperm_strays )
[[ -z "$strays" ]] || fail "a passing process counted: $strays"

# a loaded start command that is not PSM's (a drop-in) is refused, as it is
_PSM_INIT=systemd
launch=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray
          systemctl() { case "$*" in
              *ExecStart*) echo 'ExecStart={ path=/usr/local/bin/xray ; argv[]=/usr/local/bin/xray run -confdir /usr/local/etc/xray/ ; ignore_errors=no }' ;;
              *DropInPaths*) echo DropInPaths=/etc/systemd/system/xray.service.d/10-donot_touch_multi_conf.conf ;;
              *) echo ;; esac; }
          _coreperm_launch_problem xray )
[[ "$launch" == *"-confdir"*"10-donot_touch_multi_conf.conf"* ]] || fail "a drop-in start command was not refused: '$launch'"
launch=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray
          systemctl() { case "$*" in
              *ExecStart*) echo 'ExecStart={ path=/usr/local/bin/xray ; argv[]=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json ; ignore_errors=no }' ;;
              *"-p Environment "*) echo 'Environment=XRAY_LOCATION_CONFDIR=/etc/xray.d' ;;
              *) echo ;; esac; }
          _coreperm_launch_problem xray )
[[ "$launch" == *XRAY_LOCATION_CONFDIR* ]] || fail "an environment adding configuration was not refused: '$launch'"
launch=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray
          systemctl() { case "$*" in
              *ExecStart*) echo 'ExecStart={ path=/usr/local/bin/xray ; argv[]=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json ; ignore_errors=no }' ;;
              *) echo ;; esac; }
          _coreperm_launch_problem xray )
[[ -z "$launch" ]] || fail "PSM's own start command was refused: '$launch'"

# a service that starts a proxy at boot (3x-ui's x-ui) is refused; PSM's own are not
units="$tmp_dir/units3"; mkdir -p "$units/multi-user.target.wants"
printf '[Service]\nExecStart=/usr/local/x-ui/x-ui\n' >"$units/x-ui.service"
ln -s ../x-ui.service "$units/multi-user.target.wants/x-ui.service"
printf '[Service]\nExecStart=/usr/local/bin/xray run -config x\n' >"$units/xray.service"
ln -s ../xray.service "$units/multi-user.target.wants/xray.service"
boot=$( PSM_SYSTEMD_DIR="$units"; systemctl() { echo; }; _coreperm_boot_launchers )
[[ "$boot" == "x-ui.service (/usr/local/x-ui/x-ui)" ]] || fail "boot launchers: got '$boot'"

# OpenRC under supervise-daemon: the pidfile holds the supervisor, the core is its child
_PSM_INIT=openrc
alp="$tmp_dir/alpine"; mkdir -p "$alp/proc/101" "$alp/proc/102" "$alp/run"
echo 101 >"$alp/run/xray.pid"; echo supervise-daemon >"$alp/proc/101/comm"
printf 'Name:\txray\nPPid:\t101\n' >"$alp/proc/102/status"; echo xray >"$alp/proc/102/comm"
printf '%s\0' "${psmx[@]}" >"$alp/proc/102/cmdline"; : >"$alp/proc/102/environ"
strays=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray PSM_PROC_DIR="$alp/proc" PSM_RUN_DIR="$alp/run" PSM_STRAY_WAIT=0 _coreperm_strays )
[[ -z "$strays" ]] || fail "Alpine: PSM's own supervised core counted as a stray: $strays"
_PSM_INIT=systemd

# systemd 219 has no `show --value`: properties are read from P=value
v=$( systemctl() { [[ "$*" == *--value* ]] && return 1; echo "MainPID=4242"; }; _coreperm_prop xray MainPID )
[[ "$v" == 4242 ]] || fail "systemd 219 property read: got '$v'"

# before PSM writes its unit: an upstream PSM unit (Xray from its directory,
# only config.json in it) is taken; a custom one is refused untouched
cfgd="$tmp_dir/xcfg"; mkdir -p "$cfgd"; echo '{}' >"$cfgd/config.json"
pre() { ( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR="$cfgd"; loaded="$1"
          systemctl() { case "$*" in *ExecStart*) echo "ExecStart={ path=/usr/local/bin/xray ; argv[]=$loaded ; ignore_errors=no }" ;; *) echo ;; esac; }
          _coreperm_launch_problem xray pre ); }
# roomkey joins fresh servers: only PSM's own launch passes (an upstream PSM directory launch is refused too)
[[ -n "$(pre "/usr/local/bin/xray run -confdir $cfgd")" ]] || fail "an upstream PSM directory launch was taken"
[[ -z "$(pre "/usr/local/bin/xray run -config $cfgd/config.json")" ]] || fail "PSM's own launch was refused"
echo '{}' >"$cfgd/05_inbounds.json"
[[ -n "$(pre "/usr/local/bin/xray run -confdir $cfgd")" ]] || fail "a multi-file config directory was taken"
[[ -n "$(pre "/usr/local/bin/xray run -c /etc/other.json")" ]] || fail "a custom base unit was taken"

# joining: inbounds no PSM node owns are refused (companion tags of a node are its own)
mkdir -p "$tmp_dir/jcfg"
uc=$( CFG_DIR="$tmp_dir/jcfg"; XRAY_CFG_DIR="$tmp_dir/jx"; mkdir -p "$XRAY_CFG_DIR"
      echo '{"inbounds":[{"tag":"api","listen":"127.0.0.1","protocol":"dokodemo-door"},{"tag":"mine"},{"tag":"mine-ss"},{"tag":"socks-open","protocol":"socks"},{"port":1}]}' >"$XRAY_CFG_DIR/config.json"
      _psm_core_cfg() { echo "$XRAY_CFG_DIR/config.json"; }
      source "$PSM_ROOT/lib/node_cli.sh"
      _node_cli_collect() { echo '[{"tag":"mine"}]'; }
      _coreperm_unmanaged xray )
[[ "$uc" == "(untagged), socks-open" ]] || fail "unmanaged inbounds: got '$uc'"

# proxy containers Docker would bring back
ct=$( docker() { case "$1" in
          ps) printf 'marzban-marzban-1|gozargah/marzban:latest|exited\nweb|nginx:alpine|running\nold-xray|teddysun/xray|exited\n' ;;
          inspect) case "${@: -1}" in marzban-marzban-1) echo always ;; *) echo no ;; esac ;;
        esac; }
      _coreperm_proxy_containers )
[[ "$ct" == "container marzban-marzban-1 (gozargah/marzban:latest, exited, restart always)" ]] || fail "proxy containers: got '$ct'"

# OpenRC: the init script's command is what is checked
_PSM_INIT=openrc; ird="$tmp_dir/initd-launch"; mkdir -p "$ird"
printf '#!/sbin/openrc-run\ncommand="/usr/local/bin/xray"\ncommand_args="run -c /etc/other.json"\n' >"$ird/xray"
r=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray PSM_INITD_DIR="$ird" _coreperm_launch_problem xray pre )
[[ "$r" == *"/etc/other.json"* ]] || fail "OpenRC: a custom init script was taken: '$r'"
printf '#!/sbin/openrc-run\n# Managed by PSM\ncommand="/usr/local/bin/xray"\ncommand_args="run -config /usr/local/etc/xray/config.json"\n' >"$ird/xray"
r=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray PSM_INITD_DIR="$ird" _coreperm_launch_problem xray post )
[[ -z "$r" ]] || fail "OpenRC: PSM's own init script was refused: '$r'"
_PSM_INIT=systemd

# OpenRC: /etc/conf.d/<core> replacing what the script runs is refused
_PSM_INIT=openrc; cfd="$tmp_dir/confd"; mkdir -p "$cfd"; echo 'command_args="run -c /etc/x.json"' >"$cfd/xray"
r=$( XRAY_BIN=/usr/local/bin/xray XRAY_CFG_DIR=/usr/local/etc/xray PSM_INITD_DIR="$ird" PSM_CONFD_DIR="$cfd" _coreperm_launch_problem xray post )
[[ "$r" == *"conf.d"* || "$r" == *"$cfd/xray"* ]] || fail "OpenRC conf.d override was taken: '$r'"
_PSM_INIT=systemd

# systemd 219 prints EnvironmentFiles as EnvironmentFile=: a required one that is missing is still refused
r=$( MIHOMO_BIN=/usr/local/bin/mihomo MIHOMO_CFG_DIR=/etc/mihomo
     systemctl() { case "$*" in
         *ExecStart*) echo 'ExecStart={ path=/usr/local/bin/mihomo ; argv[]=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml ; ignore_errors=no }' ;;
         *"-p EnvironmentFiles "*) echo "EnvironmentFile=$tmp_dir/absent/required.env (ignore_errors=no)" ;;
         *) echo ;; esac; }
     _coreperm_launch_problem mihomo post )
[[ -n "$r" ]] || fail "systemd 219: a missing required environment file was taken"

# nginx already installed at join: refused, whatever its sites say (PSM sets
# nginx up itself; one already here has routes of unknown origin)
ngr="$tmp_dir/ngroot"; mkdir -p "$ngr/etc/nginx" "$ngr/usr/sbin"
[[ -z "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" ]] || fail "an empty tree counted as nginx"
mkdir -p "$ngr/etc/nginx/conf.d" "$ngr/etc/nginx/stream.d"   # empty directories: fine
[[ -z "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" ]] || fail "empty nginx directories counted as nginx"
# a site left behind with no binary, service or nginx.conf (what PSM's own
# nginx.conf would load), and a link to one
printf 'server { listen 127.0.0.1:9; return 204; }\n' >"$ngr/etc/nginx/conf.d/old.conf"
[[ "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == "/etc/nginx/conf.d/old.conf" ]] || fail "a leftover site was not seen"
rm "$ngr/etc/nginx/conf.d/old.conf"; ln -s /tmp/x "$ngr/etc/nginx/stream.d/r.conf"
[[ "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == *"stream.d/r.conf" ]] || fail "a leftover link was not seen"
rm "$ngr/etc/nginx/stream.d/r.conf"
# PSM's own certificates (issued before its first nginx) are fine; a link there is not
mkdir -p "$ngr/etc/nginx/ssl/n1.myroom.asia"; : >"$ngr/etc/nginx/ssl/n1.myroom.asia/fullchain.pem"
[[ -z "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" ]] || fail "PSM's certificates counted as nginx"
ln -s /tmp "$ngr/etc/nginx/ssl/n1.myroom.asia/x.conf"
[[ "$(PSM_FS_ROOT="$ngr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == *"ssl/n1.myroom.asia/x.conf" ]] || fail "a link in the certificate store was not seen"
rm "$ngr/etc/nginx/ssl/n1.myroom.asia/x.conf"
# a plain file where the certificate store goes is not one
sf="$tmp_dir/sslfile"; mkdir -p "$sf/etc/nginx"; : >"$sf/etc/nginx/ssl"
[[ "$(PSM_FS_ROOT="$sf" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == "/etc/nginx/ssl (not a directory)" ]] || fail "a file at /etc/nginx/ssl passed"
# a linked /etc/nginx (its tree elsewhere) cannot be shown empty
lr="$tmp_dir/linkroot"; mkdir -p "$lr/etc" "$tmp_dir/elsewhere/conf.d"; : >"$tmp_dir/elsewhere/conf.d/a.conf"
ln -s "$tmp_dir/elsewhere" "$lr/etc/nginx"
[[ "$(PSM_FS_ROOT="$lr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == "/etc/nginx (a link)" ]] || fail "a linked /etc/nginx passed"
: >"$tmp_dir/elsewhere/conf.d/a.conf"; rm "$tmp_dir/elsewhere/conf.d/a.conf"
[[ "$(PSM_FS_ROOT="$lr" PSM_SYSTEMD_DIR=/none PSM_INITD_DIR=/none _coreperm_nginx_present)" == "/etc/nginx (a link)" ]] || fail "a linked, empty /etc/nginx passed"
: >"$ngr/etc/nginx/nginx.conf"
[[ "$(PSM_FS_ROOT="$ngr" _coreperm_nginx_present)" == *"/etc/nginx"* ]] || fail "an nginx config tree was not seen"
printf '#!/bin/sh\n' >"$ngr/usr/sbin/nginx"; chmod +x "$ngr/usr/sbin/nginx"
[[ "$(PSM_FS_ROOT="$ngr" _coreperm_nginx_present)" == binary* ]] || fail "an nginx binary was not seen"

# … and PSM's first nginx install refuses the same leftovers before installing
ngi=$( source "$PSM_ROOT/lib/nginx.sh" >/dev/null 2>&1
       is_installed() { return 1; }; detect_os() { echo INSTALLING; }; pkg_install() { echo INSTALLING; }
       ngl="$tmp_dir/ngleft"; mkdir -p "$ngl/etc/nginx/conf.d"; printf 'server {}\n' >"$ngl/etc/nginx/conf.d/old.conf"
       rc=0; PSM_FS_ROOT="$ngl" nginx_install </dev/null 2>&1 || rc=$?; echo "rc=$rc" )
[[ "$ngi" == *"conf.d/old.conf"* && "$ngi" == *"rc=1"* && "$ngi" != *INSTALLING* ]] || fail "nginx install over leftovers: $ngi"
# … but goes ahead over PSM's own certificates (issued first, as for Vision)
ngc="$tmp_dir/ngcert"; mkdir -p "$ngc/etc/nginx/ssl/n1"; : >"$ngc/etc/nginx/ssl/n1/key.pem"
ngi=$( source "$PSM_ROOT/lib/nginx.sh" >/dev/null 2>&1
       is_installed() { return 1; }; detect_os() { echo INSTALLING; exit 0; }
       PSM_FS_ROOT="$ngc" nginx_install </dev/null 2>&1 )
[[ "$ngi" == *INSTALLING* ]] || fail "nginx install refused PSM's own certificates: $ngi"

# public listeners at join: SSH and system daemons are fine, anything else is named
pl=$( PSM_PROC_DIR="$tmp_dir/emptyproc"; mkdir -p "$PSM_PROC_DIR"   # names as displayed (no PID readable)
      ss() { printf '%s\n' \
        'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' \
        'udp UNCONN 0 0 0.0.0.0:68 0.0.0.0:* users:(("dhclient",pid=2,fd=6))' \
        'tcp LISTEN 0 128 127.0.0.1:53 0.0.0.0:* users:(("dnsmasq",pid=3,fd=4))' \
        'tcp LISTEN 0 128 [::]:443 [::]:* users:(("haproxy",pid=4,fd=5))'; }
      _coreperm_public_listeners )
[[ "$pl" == "haproxy on [::]:443/tcp" ]] || fail "public listeners: '$pl'"
# owners come from their PIDs: socket-activated SSH (systemd, ssh.socket) is fine,
# PSM's standalone ss-rust is not expected on a fresh server, a truncated BusyBox
# program column does not matter
lp="$tmp_dir/lproc"; mkdir -p "$lp/1" "$lp/50" "$lp/60"
echo systemd >"$lp/1/comm"; echo ss-rust >"$lp/50/comm"; echo dropbear >"$lp/60/comm"
pl=$( PSM_PROC_DIR="$lp"; _PSM_INIT=systemd
      ss() { printf '%s\n' 'tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=60))' \
                            'tcp LISTEN 0 128 0.0.0.0:8388 0.0.0.0:* users:(("ss-rust",pid=50,fd=7))'; }
      systemctl() { [[ "$1" == list-sockets ]] && echo '0.0.0.0:22 ssh.socket ssh@0.service'; return 0; }
      _coreperm_public_listeners )
[[ "$pl" == "ss-rust on 0.0.0.0:8388/tcp" ]] || fail "owners by PID: '$pl'"
pl=$( PSM_PROC_DIR="$lp"
      ss() { return 1; }
      netstat() { printf '%s\n' 'Proto Recv-Q Send-Q Local Address Foreign Address State PID/Program name' \
                                 'tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN 60/dropbear -R -F -p' ; }
      _coreperm_public_listeners )
[[ -z "$pl" ]] || fail "BusyBox netstat with a long argv: '$pl'"
pl=$( ss() { return 1; }; netstat() { return 1; }; _coreperm_public_listeners )
[[ "$pl" == *"cannot be read"* ]] || fail "no socket list: '$pl'"

# an optional environment file that is absent (PSM's psm.env for mihomo) is fine; a required one is not
envp() { ( MIHOMO_BIN=/usr/local/bin/mihomo MIHOMO_CFG_DIR=/etc/mihomo; ef="$1"
           systemctl() { case "$*" in
               *ExecStart*) echo 'ExecStart={ path=/usr/local/bin/mihomo ; argv[]=/usr/local/bin/mihomo -d /etc/mihomo -f /etc/mihomo/config.yaml ; ignore_errors=no }' ;;
               *"-p EnvironmentFiles "*) echo "EnvironmentFiles=$ef" ;;
               *) echo ;; esac; }
           _coreperm_launch_problem mihomo post ); }
[[ -z "$(envp "$tmp_dir/absent/psm.env (ignore_errors=yes)")" ]] || fail "an absent optional environment file was refused"
[[ -n "$(envp "$tmp_dir/absent/psm.env (ignore_errors=no)")" ]] || fail "an absent required environment file was taken"

# a hook whose failure is ignored ("-") is no hook
printf '[Service]\nExecStartPre=-/bin/bash /opt/psm/lib/coreperm.sh xray\n' >"$tmp_dir/ign.service"
if _coreperm_has_hook "$tmp_dir/ign.service" xray; then fail "an ignorable hook counted"; fi

# inventory: WARP's WireGuard endpoint (it dials out) is an exit, not a listener; a mihomo
# tunnel is never PSM's; "api" counts only as Xray's loopback stats endpoint
inv() { ( core="$1"; f="$tmp_dir/inv.json"; printf '%s\n' "$2" >"$f"
          _psm_core_cfg() { echo "$f"; }; _node_cli_collect() { echo '[{"tag":"mine"}]'; }
          _coreperm_unmanaged "$core" ); }
[[ -z "$(inv sing-box '{"inbounds":[{"tag":"mine"}],"endpoints":[{"type":"wireguard","tag":"out-warp"}]}')" ]] || fail "WARP endpoint counted as unmanaged"
[[ "$(inv sing-box '{"endpoints":[{"type":"wireguard","tag":"wg-open","listen_port":51820}]}')" == wg-open ]] || fail "a listening WireGuard endpoint was missed"
[[ "$(inv mihomo '{"listeners":[{"name":"mine"}],"tunnels":["tcp,0.0.0.0:53,8.8.8.8:53"]}')" == "(tunnel tcp,0.0.0.0:53,8.8.8.8:53)" ]] || fail "a mihomo tunnel was missed"
[[ "$(inv sing-box '{"inbounds":[{"tag":"api","type":"mixed"}]}')" == api ]] || fail "an api tag on sing-box counted as PSM's"

# a Docker whose list cannot be read is no empty list
ct=$( docker() { return 1; }; _coreperm_proxy_containers )
[[ "$ct" == "docker: its container list cannot be read"* ]] || fail "unreadable docker list: '$ct'"

# joining is read-only until the whole server passes: a refusal leaves everything as it was
jr=$( set -euo pipefail
      _PSM_INIT=systemd; PSM_SYSTEMD_DIR="$tmp_dir/junits"; mkdir -p "$PSM_SYSTEMD_DIR"
      CFG_DIR="$tmp_dir/jconfig"; mkdir -p "$CFG_DIR/realm"; echo '[{"tag":"r","listen_port":30001}]' >"$CFG_DIR/realm/rules.json"
      PSM_PROC_DIR="$tmp_dir/noproc"; export PSM_FS_ROOT="$tmp_dir/jfs"; PSM_GUARD_JOIN=1
      XRAY_BIN=/nonexistent; SINGBOX_BIN=/nonexistent; MIHOMO_BIN=/nonexistent
      svc_exists() { return 1; }; docker() { return 0; }; systemctl() { echo; return 0; }
      svc_stop() { echo touched >>"$tmp_dir/jlog"; }; svc_restart() { echo touched >>"$tmp_dir/jlog"; }
      rc=0; psm_guard_all --json >"$tmp_dir/join.out" 2>/dev/null || rc=$?
      echo "$rc $(jq length "$CFG_DIR/realm/rules.json" 2>/dev/null) $( [[ -s "$tmp_dir/jlog" ]] && echo touched || echo 0 )" )
[[ "$jr" == "2 1 0" ]] || fail "join with a relay rule: got '$jr' ($(cat "$tmp_dir/join.out"))"
jq -e '.cores[] | select(.core == "relays") | .reason | test("psm relay off")' "$tmp_dir/join.out" >/dev/null || fail "join: the relay was not named"

echo "ok: guard hook detection, outcomes, state reads, stray proxies, launch commands, boot launchers, containers and joins"
