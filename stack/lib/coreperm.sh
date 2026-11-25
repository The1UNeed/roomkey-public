#!/usr/bin/env bash
# coreperm.sh — Xray, sing-box and mihomo run as the unprivileged user psm-core
#
# The cores need two capabilities (binding ports below 1024, and SO_MARK for
# the WARP / VPNGate exits), which systemd and OpenRC grant them; everything
# else root used to cover is file access. This keeps it working:
#   - the core's own state (mihomo's home, sing-box's cache.db directory,
#     Xray's log directory) belongs to psm-core;
#   - its config files are readable by the psm-core group;
#   - every certificate / key its config references is readable too, including
#     after acme.sh renews it (renewals rewrite the key as root 0600).
# It runs as root before every core start (systemd ExecStartPre=+, OpenRC
# start_pre) and right after PSM writes a config, so a reboot after a renewal
# or a freshly written config never locks the core out.
#
#   bash lib/coreperm.sh <xray|sing-box|mihomo>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PSM_CORE_USER="psm-core"

# Directories under which PSM may grant psm-core traversal to reach a
# certificate (psm_cert_dirs). A key elsewhere (say, under /root, or PSM's
# own config with the agent token) is reported, not opened up.
_coreperm_cert_roots() { psm_cert_dirs; }

# systemd older than 231 (Amazon Linux 2 ships 219) knows neither
# AmbientCapabilities (229) nor ExecStartPre=+ (231): an unprivileged core
# could not bind its port there, so the cores stay root. PSM_SYSTEMD_VERSION
# overrides the detected version (tests).
psm_core_nonroot_supported() {
    _uses_systemd || return 0
    local v="${PSM_SYSTEMD_VERSION:-}"
    [[ -n "$v" ]] || v=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')
    [[ "$v" =~ ^[0-9]+$ ]] || return 0
    (( v >= 231 ))
}

# The [Service] lines that decide who the core runs as.
psm_core_unit_lines() {   # <xray|sing-box|mihomo>
    if psm_core_nonroot_supported; then
        cat <<EOF
User=${PSM_CORE_USER}
Group=${PSM_CORE_USER}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
# '+' runs this as root: it keeps what psm-core must read readable (lib/coreperm.sh)
ExecStartPre=+/bin/bash ${LIB_DIR}/coreperm.sh $1
EOF
    else
        cat <<EOF
# systemd older than 231: too old to start the core unprivileged (lib/coreperm.sh).
# Root keeps all its capabilities: files a newer PSM gave to psm-core stay readable.
User=root
NoNewPrivileges=true
# the check every start passes (lib/coreperm.sh): no camouflage fallback off this server
ExecStartPre=/bin/bash ${LIB_DIR}/coreperm.sh $1
EOF
    fi
}

psm_core_user_ensure() {
    id -u "$PSM_CORE_USER" &>/dev/null && return 0
    if command -v useradd &>/dev/null; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
            --user-group "$PSM_CORE_USER" 2>/dev/null
    else   # busybox (Alpine)
        addgroup -S "$PSM_CORE_USER" 2>/dev/null
        adduser -S -D -H -h /nonexistent -s /sbin/nologin -G "$PSM_CORE_USER" "$PSM_CORE_USER" 2>/dev/null
    fi
    id -u "$PSM_CORE_USER" &>/dev/null
}

# Make <file> readable by psm-core: its group, and every parent directory it
# cannot already traverse, provided that directory is under a cert root.
_coreperm_grant_file() {
    local f="$1" d root ok
    [[ -e "$f" ]] || return 0
    # the file itself first: only one whose real path is in a certificate
    # directory is touched at all (a config naming /etc/shadow or the agent
    # token changes nothing)
    if ! psm_cert_file_allowed "$f"; then
        log_warn "$(t common.coreperm.cannot_reach "$f" "$(dirname "$f")")"
        return 0
    fi
    f=$(readlink -f -- "$f")
    chgrp "$PSM_CORE_USER" "$f" 2>/dev/null && chmod g+r "$f" 2>/dev/null
    d=$(dirname "$f")
    while [[ "$d" != "/" && -n "$d" ]]; do
        if [[ "$(stat -c '%A' "$d" 2>/dev/null)" != *x ]]; then   # others cannot traverse
            ok=0
            while IFS= read -r root; do
                [[ -n "$root" && ( "$d" == "$root" || "$d" == "$root"/* ) ]] && { ok=1; break; }
            done < <(_coreperm_cert_roots)
            if (( ok )); then
                chgrp "$PSM_CORE_USER" "$d" 2>/dev/null || true; chmod g+x "$d" 2>/dev/null || true
            else
                log_warn "$(t common.coreperm.cannot_reach "$f" "$d")"
                return 0
            fi
        fi
        d=$(dirname "$d")
    done
}

# Every certificate / key path a core config references (all three formats).
_coreperm_cert_paths() {
    jq -r '[.. | objects | to_entries[]
             | select(.key | test("^(certificateFile|keyFile|certificate_path|key_path|certificate|private-key)$"))
             | .value | strings | select(startswith("/"))] | unique[]' "$1" 2>/dev/null
}

psm_core_perms() {
    local core="$1" cfg_dir cfg state_dirs=() d
    psm_core_user_ensure || { log_warn "$(t common.coreperm.no_user)"; return 1; }
    case "$core" in
        xray)
            cfg_dir="${XRAY_CFG_DIR:-/usr/local/etc/xray}"; cfg="$cfg_dir/config.json"
            state_dirs=(/var/log/xray) ;;
        sing-box)
            cfg_dir="${SINGBOX_CFG_DIR:-/etc/sing-box}"; cfg="$cfg_dir/config.json"
            state_dirs=("$cfg_dir") ;;      # cache.db lives next to config.json
        mihomo)
            cfg_dir="${MIHOMO_CFG_DIR:-/etc/mihomo}"; cfg="$cfg_dir/config.yaml"
            state_dirs=("$cfg_dir") ;;      # home: cache.db, geodata, rule providers
        *) return 1 ;;
    esac
    [[ -d "$cfg_dir" ]] || return 0
    # Best effort throughout (`|| true`): callers run under errexit, and a file
    # PSM cannot fix is for the core to report, not a reason to abort a change.
    mkdir -p "${state_dirs[@]}" 2>/dev/null || true
    # Config tree: group psm-core, readable; directories traversable.
    chgrp -R "$PSM_CORE_USER" "$cfg_dir" 2>/dev/null || true
    find "$cfg_dir" -type d -exec chmod g+rx {} + 2>/dev/null || true
    find "$cfg_dir" -type f -exec chmod g+r {} + 2>/dev/null || true
    # State the core writes itself.
    for d in "${state_dirs[@]}"; do
        chown "$PSM_CORE_USER:$PSM_CORE_USER" "$d" 2>/dev/null || true; chmod 750 "$d" 2>/dev/null || true
        find "$d" -maxdepth 1 -type f \( -name '*.db' -o -name '*.log' -o -name '*.dat' -o -name '*.mmdb' \) \
            -exec chown "$PSM_CORE_USER:$PSM_CORE_USER" {} + 2>/dev/null || true
        # mihomo downloads rule / proxy providers into subdirectories of its home
        find "$d" -mindepth 1 -maxdepth 1 -type d -exec chown -R "$PSM_CORE_USER:$PSM_CORE_USER" {} + 2>/dev/null || true
    done
    # Read by the init system as root only.
    [[ -f "$cfg_dir/psm.env" ]] && { chown root:root "$cfg_dir/psm.env"; chmod 600 "$cfg_dir/psm.env"; } || true
    # Certificates and keys the config points at.
    local f
    [[ -f "$cfg" ]] && while IFS= read -r f; do _coreperm_grant_file "$f"; done < <(_coreperm_cert_paths "$cfg")
    return 0
}

# Does this systemd unit / OpenRC script run the core as psm-core? (A plain
# grep would also match the comment PSM puts in the unit.)
_coreperm_unit_nonroot() {
    grep -qE "^(User=|command_user=\"?)${PSM_CORE_USER}" "$1" 2>/dev/null
}

# Called before every restart PSM does: fix permissions for what was just
# written, and move a unit that still runs the core as root to psm-core once.
psm_core_nonroot_ensure() {
    local core="$1" def
    # too old a systemd: the core stays root, and its files stay root's too
    psm_core_nonroot_supported || return 0
    psm_core_perms "$core" || return 0
    if _uses_systemd; then def="/etc/systemd/system/${core}.service"; else def="/etc/init.d/${core}"; fi
    [[ -f "$def" ]] || return 0
    _coreperm_unit_nonroot "$def" && return 0
    case "$core" in
        xray)     declare -F _write_xray_service >/dev/null && _write_xray_service ;;
        sing-box) declare -F _sb_write_service  >/dev/null && _sb_write_service ;;
        mihomo)   declare -F _mh_write_service  >/dev/null && _mh_write_service ;;
    esac
    svc_daemon_reload 2>/dev/null || true
    log_info "$(t common.coreperm.migrated "$core")"
}

# Entry point for ExecStartPre / start_pre: bash lib/coreperm.sh <core>
# Every start of a core passes here — PSM's restarts, an install, a restore,
# a geodata update, a reboot, a rollback to an older config — so this is where
# roomkey refuses a config whose camouflage fallback leads off this server
# (lib/common.sh psm_reality_guard): the core then does not start, rather
# than starting as an open relay.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # the standalone Hysteria2 server: its masquerade, before every start
    if [[ "${1:-}" == hysteria ]]; then psm_hy2_standalone_ok >&2 || exit 1; exit 0; fi
    # The whole final step, not just the fallback check: the current accounts
    # (a restored or rolled-back config must not bring back a revoked user),
    # the abuse rules, and no fallback off this server. Any of them failing
    # keeps the core down.
    psm_users_merge "${1:-}" >&2 || exit 1
    psm_core_perms "${1:-}"   # never blocks: the core reports what it cannot read
    exit 0
fi

# Whether a core's service definition runs the start check: an executable
# directive, not a mention (upstream's systemd 219 unit names coreperm.sh in
# a comment and has no ExecStartPre at all).
_coreperm_has_hook() {   # <definition file> <core>
    local def="$1" core="$2"
    [[ -f "$def" ]] || return 1
    if _uses_systemd; then
        # (not "-": a check whose failure is ignored checks nothing)
        grep -Eq "^[[:space:]]*ExecStartPre=[+!@:]*/bin/bash[[:space:]]+[^[:space:]]*/coreperm\.sh[[:space:]]+${core}([[:space:]]|\$)" "$def"
    else
        # OpenRC: a start_pre that runs it (comments ignored)
        sed -e 's/#.*$//' "$def" | grep -Eq "(^|[[:space:];])(/bin/)?bash[[:space:]]+[^[:space:]]*/coreperm\.sh[[:space:]]+\"?${core}"
    fi
}

# psm guard [--json]: brings every installed core under the start check — a
# server that ran upstream PSM, whose cores started before this check
# existed, or whose old unit (systemd < 231) has no pre-start hook. Each core:
#   - its unit gets the hook (rewritten, reloaded, and read back);
#   - a running core is restarted, so what runs is the checked config (the
#     restart passes the hook: accounts, abuse rules, no fallback off this
#     server) — a config changed only on disk would not be what it serves;
#   - a core that fails the check is stopped, and one whose unit still has no
#     hook is stopped and disabled, so a reboot cannot start it unchecked.
# Exit 0: every core checked; 10: a core failed and was verified stopped (and
# its unit hooked or disabled): safe, but down; anything else (2, or a crash)
# means a core could not be shown safe.
#
# The service manager's loaded definition counts, not just the file: systemd
# must have reloaded it (systemctl show).
_coreperm_loaded_hook() {   # <core>
    _uses_systemd || return 0   # OpenRC reads the script at each start
    # this PSM's own check for this core, not any script of that name
    # (and a failure of it stops the start: ignore_errors=no)
    systemctl show -p ExecStartPre "$1" 2>/dev/null | grep -F "$LIB_DIR/coreperm.sh $1" | grep -q 'ignore_errors=no'
}

# A core's service state, read explicitly: active | inactive | unknown. Only a
# clear answer counts: "inactive" needs the service manager to say so in a
# form it uses for a stopped service, and no process of that core may be
# running outside it. Anything else (no answer, an empty or new value, a
# process the manager does not know about) is unknown, never stopped.
_coreperm_svc_state() {   # <core>
    local v load act rc procs
    if _uses_systemd; then
        v=$(systemctl show -p LoadState -p ActiveState "$1" 2>/dev/null) || { echo unknown; return; }
        load=$(sed -n 's/^LoadState=//p' <<<"$v"); act=$(sed -n 's/^ActiveState=//p' <<<"$v")
        case "$load" in loaded|not-found|masked) ;; *) echo unknown; return ;; esac
        case "$act" in
            active|reloading|activating|deactivating|refreshing) echo active; return ;;
            inactive|failed) ;;
            *) echo unknown; return ;;
        esac
    elif [[ -e "${PSM_INITD_DIR:-/etc/init.d}/$1" ]]; then
        rc=0; rc-service "$1" status >/dev/null 2>&1 || rc=$?
        case "$rc" in 0) echo active; return ;; 3) ;; *) echo unknown; return ;; esac
    fi   # OpenRC with no such service: nothing it could run, so only the processes count
    # the manager says stopped: so must the process table
    procs=$(_coreperm_procs "$1") || { echo unknown; return; }
    if [[ "$procs" == 0 ]]; then echo inactive; else echo unknown; fi
}
# How many processes of a core run (by name: xray, sing-box, mihomo); fails
# when that cannot be read.
_coreperm_procs() {   # <core>
    local n=0 f rc out
    if [[ -r /proc/1/comm ]]; then
        for f in /proc/[0-9]*/comm; do
            [[ "$(cat "$f" 2>/dev/null)" == "$1" ]] && n=$((n + 1))
        done
        echo "$n"; return 0
    fi
    command -v pgrep >/dev/null 2>&1 || return 1
    rc=0; out=$(pgrep -x -- "$1" 2>/dev/null) || rc=$?
    case "$rc" in 0) grep -c . <<<"$out" ;; 1) echo 0 ;; *) return 1 ;; esac
}
# Whether it starts at boot: enabled | disabled | unknown. "disabled" only
# from values that mean it (a unit file disabled or masked, a unit systemd
# does not have at all, an OpenRC service in no runlevel); an empty or new
# value is unknown.
_coreperm_svc_boot() {   # <core>
    local v load ufs
    if _uses_systemd; then
        v=$(systemctl show -p LoadState -p UnitFileState "$1" 2>/dev/null) || { echo unknown; return; }
        load=$(sed -n 's/^LoadState=//p' <<<"$v"); ufs=$(sed -n 's/^UnitFileState=//p' <<<"$v")
        case "$ufs" in
            disabled|masked|masked-runtime) echo disabled ;;
            enabled|enabled-runtime|static|indirect|generated|linked|linked-runtime|alias|transient) echo enabled ;;
            "") if [[ "$load" == not-found ]]; then echo disabled; else echo unknown; fi ;;
            *) echo unknown ;;
        esac
    else
        # every runlevel (boot and sysinit too), not just default
        v=$(rc-update show -v 2>/dev/null) && [[ -n "$v" ]] || { echo unknown; return; }
        # "  xray | default boot" in a runlevel; "  xray |" in none
        if grep -Eq "^[[:space:]]*$1[[:space:]]*\|[[:space:]]*[^[:space:]]" <<<"$v"; then echo enabled
        elif grep -Eq "^[[:space:]]*$1[[:space:]]*\|" <<<"$v"; then echo disabled
        elif [[ ! -e "${PSM_INITD_DIR:-/etc/init.d}/$1" ]]; then echo disabled   # no service to start
        else echo unknown; fi
    fi
}

# The command line each core runs with under PSM's own service: the config the
# start check validates, and nothing else.
_coreperm_expected_cmd() {   # <core>
    case "$1" in
        xray)     printf '%s run -config %s' "$XRAY_BIN" "$XRAY_CFG_DIR/config.json" ;;
        sing-box) printf '%s run -c %s' "$SINGBOX_BIN" "$SINGBOX_CFG_DIR/config.json" ;;
        mihomo)   printf '%s -d %s -f %s' "$MIHOMO_BIN" "$MIHOMO_CFG_DIR" "$MIHOMO_CFG_DIR/config.yaml" ;;
    esac
}

# One property of a loaded unit, as `systemctl show -p P --value` gives it
# (systemd 219, which PSM writes units for, has no --value). Fails when the
# service manager does not answer.
_coreperm_prop() {   # <unit> <property>
    local raw
    raw=$(systemctl show -p "$2" "$1" 2>/dev/null) || return 1
    sed -n "s/^$2=//p" <<<"$raw"
}

# The processes a core's service supervises: systemd's MainPID; on OpenRC the
# pidfile's process, or — under supervise-daemon, whose pidfile holds the
# supervisor — its children.
_coreperm_main_pids() {   # <core>
    local v proc="${PSM_PROC_DIR:-/proc}" d
    if _uses_systemd; then
        v=$(_coreperm_prop "$1" MainPID) || v=""
        [[ "$v" =~ ^[1-9][0-9]*$ ]] && echo "$v"
        return 0
    fi
    v=$(cat "${PSM_RUN_DIR:-/run}/$1.pid" 2>/dev/null) || return 0
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 0
    echo "$v"
    if [[ "$(cat "$proc/$v/comm" 2>/dev/null)" == supervise-daemo* ]]; then
        for d in "$proc"/[0-9]*; do
            [[ "$(sed -n 's/^PPid:[[:space:]]*//p' "$d/status" 2>/dev/null)" == "$v" ]] && echo "${d##*/}"
        done
    fi
    return 0
}

# Environment variables that make a core read more than the checked file
# (Xray appends every file of XRAY_LOCATION_CONFDIR to its -config).
_PSM_CORE_ENV_RE='^(XRAY_LOCATION_CONFDIR|XRAY_LOCATION_CONFIG|V2RAY_LOCATION_CONFDIR|V2RAY_LOCATION_CONFIG)='

# Proxies running outside PSM's checked services: any Xray, V2Ray, sing-box,
# mihomo or Clash process (by name, so a panel's own copy such as 3x-ui's
# xray-linux-amd64 counts) that is not its core's supervised process running
# exactly what PSM's service runs, with nothing in its environment that adds
# configuration (an environment that cannot be read counts as such). Read
# three times a second apart: only what stays counts (PSM's own stats query
# or a probe runs a core for a moment). One "pid: command" per line.
_coreperm_strays() {
    local proc="${PSM_PROC_DIR:-/proc}" try seen="" now=""
    if [[ -z "${PSM_PROC_DIR:-}" && ! -d "$proc/1" ]]; then
        [[ "$(uname -s 2>/dev/null)" == Linux ]] && echo "0: the process table (/proc) cannot be read"
        return 0
    fi
    for try in 1 2 3; do
        now=$(_coreperm_strays_once "$proc") || { echo "0: the process scan failed"; return 0; }
        if [[ $try == 1 ]]; then seen="$now"
        else seen=$(comm -12 <(sort <<<"$seen") <(sort <<<"$now")) || seen=""; fi
        [[ -n "$seen" ]] || return 0
        [[ $try == 3 ]] || sleep "${PSM_STRAY_WAIT:-1}"
    done
    printf '%s\n' "$seen"
}
_coreperm_strays_once() {   # <proc dir>
    local proc="$1" d comm cmd core mine pid env
    declare -A mains=()
    for core in xray sing-box mihomo; do
        while IFS= read -r pid; do [[ -n "$pid" ]] && mains[$pid]=$core; done < <(_coreperm_main_pids "$core")
    done
    for d in "$proc"/[0-9]*; do
        comm=$(cat "$d/comm" 2>/dev/null) || continue
        case "$comm" in xray*|v2ray*|sing-box*|mihomo*|clash*|gost*|psm-gost*|realm*) ;; *) continue ;; esac
        pid="${d##*/}"
        if ! cmd=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null); then
            [[ -e "$d" ]] && printf '%s: (command line unreadable)\n' "$pid"
            continue
        fi
        cmd="${cmd% }"
        [[ -n "$cmd" ]] || continue   # gone, or a kernel thread
        # PSM's command line for the very core whose service supervises this process
        mine="${mains[$pid]:-}"
        if [[ -n "$mine" && "$cmd" == "$(_coreperm_expected_cmd "$mine")" ]]; then
            env=$(tr '\0' '\n' <"$d/environ" 2>/dev/null) || env="UNREADABLE="
            if [[ "$env" == "UNREADABLE=" ]] || grep -Eq "$_PSM_CORE_ENV_RE" <<<"$env"; then
                printf '%s: %s (its environment adds configuration, or cannot be read)\n' "$pid" "$cmd"
            fi
            continue
        fi
        printf '%s: %s\n' "$pid" "$cmd"
    done
    return 0
}

# What a core's service starts, as the service manager has it loaded. After
# PSM's unit is in place ("post"): exactly PSM's command line, with no
# environment adding configuration. Before PSM touches anything ("pre"): PSM's
# command, or one an upstream PSM unit used (Xray from its config directory
# while only config.json is in it, mihomo from its directory). Anything else —
# a custom ExecStart in the unit or a drop-in, the official Xray installer's
# multi-file mode — is refused as it is: the inbounds it serves would be
# dropped without a word.
_coreperm_launch_problem() {   # <core> <pre|post> → a reason, or nothing (roomkey joins fresh servers: only PSM's own launch passes)
    local core="$1" mode="${2:-post}" raw exec env files f want ok=0 legacy=0 line path opt
    want=$(_coreperm_expected_cmd "$core")
    if _uses_systemd; then
        raw=$(_coreperm_prop "$core" ExecStart) || { echo "its loaded start command cannot be read"; return 0; }
        if [[ -z "$raw" ]]; then
            # nothing loaded: fine before PSM writes its unit, not after
            [[ "$mode" == post ]] && echo "its loaded start command cannot be read"
            return 0
        fi
        # "{ path=… ; argv[]=/usr/local/bin/xray run -config … ; ignore_errors=no ; … }", once per ExecStart=
        exec=$(sed -n 's/.*argv\[\]=\([^;]*\) ;.*/\1/p' <<<"$raw" | sed 's/ *$//')
    else
        # OpenRC: what the init script runs (command + command_args)
        f="${PSM_INITD_DIR:-/etc/init.d}/$core"
        [[ -e "$f" ]] || { [[ "$mode" == post ]] && echo "its init script is missing"; return 0; }
        [[ -r "$f" ]] || { echo "its init script $f cannot be read"; return 0; }
        exec="$(sed -n 's/^[[:space:]]*command=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$f" | tail -1) $(sed -n 's/^[[:space:]]*command_args=["'\'']\{0,1\}\([^"'\'']*\)["'\'']\{0,1\}[[:space:]]*$/\1/p' "$f" | tail -1)"
        exec="${exec% }"
        # /etc/conf.d/<core> can replace or extend what the script runs
        if grep -Eqs '^[[:space:]]*(command|command_args|command_args_append|command_user|supervisor)=' "${PSM_CONFD_DIR:-/etc/conf.d}/$core"; then
            echo "${PSM_CONFD_DIR:-/etc/conf.d}/$core changes what its service runs: remove that, then run this again"; return 0
        fi
    fi
    [[ "$exec" == "$want" ]] && ok=1
    if (( ! ok )); then
        files=""; _uses_systemd && { files=$(_coreperm_prop "$core" DropInPaths) || files=""; }
        echo "its service starts '$exec', not PSM's '$want'${files:+ (drop-ins: $files)}: move what it serves into PSM's nodes, or remove the override, then run this again"
        return 0
    fi
    if _uses_systemd; then
        env=$(_coreperm_prop "$core" Environment | tr ' ' '\n') || env=""
        # EnvironmentFiles= (EnvironmentFile= on systemd 219): "PATH (ignore_errors=yes|no)", one per line
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            path="${line%% (ignore_errors=*}"; opt=no
            [[ "$line" == *"(ignore_errors=yes)"* ]] && opt=yes
            if [[ -r "$path" ]]; then env+=$'\n'$(cat "$path")
            elif [[ "$opt" == yes && ! -e "$path" ]]; then :   # optional and absent: PSM's own psm.env
            else echo "its environment file $path cannot be read"; return 0; fi
        done < <(systemctl show -p EnvironmentFiles "$core" 2>/dev/null | sed -n 's/^EnvironmentFiles\{0,1\}=//p')   # systemd 219 prints EnvironmentFile=
        if grep -Eq "$_PSM_CORE_ENV_RE" <<<"$env"; then
            echo "its service environment adds configuration ($(grep -Eo "$_PSM_CORE_ENV_RE" <<<"$env" | tr -d '=' | sort -u | tr '\n' ' ')): remove it, then run this again"
            return 0
        fi
    fi
    return 0
}

# Inbounds in a core's config that no PSM node owns (by tag, or a companion
# tag such as TAG-…; Xray's loopback stats endpoint), WireGuard endpoints that
# listen (WARP's, which dial out, are an exit), and mihomo tunnels (PSM makes
# none): roomkey joins a server only when every proxy listener on it is one of
# PSM's nodes; anything else is named, never adopted.
_coreperm_unmanaged() {   # <core> → their tags, comma-separated
    local core="$1" cfg known
    cfg=$(_psm_core_cfg "$core"); [[ -f "$cfg" ]] || return 0
    known=$( { declare -f _node_cli_collect >/dev/null || source "$LIB_DIR/node_cli.sh" >/dev/null 2>&1; } \
             && _node_cli_collect "$core" "" 2>/dev/null | jq -c '[.[].tag]' ) \
        || { echo "(PSM's node stores cannot be read)"; return 0; }
    [[ -n "$known" ]] || known='[]'
    jq -r --arg c "$core" --argjson k "$known" '
        def owned($t): any($k[]; . as $s | $t == $s or ($t | startswith($s + "-")) or ($t | startswith($s + "_")));
        def stats: $c == "xray" and .tag == "api" and (.listen // "") == "127.0.0.1" and .protocol == "dokodemo-door";
        (if $c == "mihomo" then [(.listeners[]? | .name // ""), (.tunnels[]? | "(tunnel \(if type == "string" then . else (.address // "?") end))"),
             (. as $g | ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"][] | select(($g[.] // 0) != 0) | "(global \(.))"),
             # servers mihomo starts from top-level settings (PSM writes none)
             (. as $g | ["ss-config", "vmess-config"][] | select((($g[.] // "") | tostring | length) > 0) | "(global \(.))"),
             (if (."tuic-server".enable // false) == true then "(global tuic-server)" else empty end)]
         elif $c == "sing-box" then [(.inbounds[]?, (.endpoints[]? | select(has("listen_port")))) | .tag // ""]
         else [.inbounds[]? | select(stats | not) | .tag // ""] end)
        | map(if . == "" then "(untagged)" else . end | select(startswith("(tunnel") or startswith("(global") or (owned(.) | not))) | unique | join(", ")' "$cfg" 2>/dev/null \
        || echo "($cfg cannot be read)"
}

# Services started at boot that run a proxy outside PSM's checked cores
# (3x-ui's x-ui, an official xray@ instance, another panel): stopping the
# process is not enough while its launcher would start it again.
_PSM_OWN_UNITS=" xray sing-box mihomo psm-agent hysteria-server snell ss-rust nginx realm psm-gost "
_PSM_PROXY_RE='^(xray|v2ray|v2fly|sing-box|mihomo|clash|x-ui|3x-ui|hiddify|marzban|gost)'
_coreperm_proxy_bin() {
    [[ "${1##*/}" =~ $_PSM_PROXY_RE ]] && return 0
    # joining: a fresh server has no standalone server either (Snell instances, ss-rust, Hysteria2)
    [[ -n "${PSM_GUARD_JOIN:-}" && "${1##*/}" =~ ^(snell-server|ss-rust|ssserver|hysteria) ]]
}
_coreperm_boot_launchers() {
    local name exec unit line
    if _uses_systemd; then
        for unit in "${PSM_SYSTEMD_DIR:-/etc/systemd/system}"/*.wants/*.service; do
            [[ -e "$unit" || -L "$unit" ]] || continue
            name="${unit##*/}"; name="${name%.service}"
            [[ "$_PSM_OWN_UNITS" == *" $name "* ]] && continue
            exec=$(_coreperm_prop "$name.service" ExecStart | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | head -1) || exec=""
            [[ -n "$exec" ]] || exec=$(sed -n 's/^[[:space:]]*ExecStart=[-+!@:]*\([^ ]*\).*/\1/p' "$unit" 2>/dev/null | tail -1) || exec=""
            if _coreperm_proxy_bin "$exec" || [[ "$name" =~ $_PSM_PROXY_RE ]]; then printf '%s.service (%s)\n' "$name" "$exec"; fi
        done | sort -u
    else
        while IFS= read -r line; do
            name=$(sed 's/|.*//; s/[[:space:]]//g' <<<"$line")
            [[ -n "$name" && "$line" =~ \|[[:space:]]*[^[:space:]] && "$_PSM_OWN_UNITS" != *" $name "* ]] || continue
            exec=$(sed -n 's/^[[:space:]]*command=["'\'']\{0,1\}\([^"'\'' ]*\).*/\1/p' "${PSM_INITD_DIR:-/etc/init.d}/$name" 2>/dev/null | head -1) || exec=""
            if _coreperm_proxy_bin "$exec" || [[ "$name" =~ $_PSM_PROXY_RE ]]; then printf '%s (%s)\n' "$name" "$exec"; fi
        done < <(rc-update show -v 2>/dev/null)
    fi
    return 0
}

# Proxy containers Docker would start (running now, or a restart policy that
# brings them back with the daemon): Marzban, 3x-ui, a bare xray image.
_coreperm_proxy_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    local line name image state policy list
    # a list that cannot be read is no empty list: its containers may come back with the daemon
    list=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.State}}' 2>/dev/null) \
        || { echo "docker: its container list cannot be read (start docker so its containers can be checked, or remove it)"; return 0; }
    while IFS='|' read -r name image state; do
        [[ -n "$name" ]] || continue
        [[ "${name,,}" =~ $_PSM_PROXY_RE || "${image##*/}" =~ $_PSM_PROXY_RE || "${image,,}" =~ (^|/)(teddysun/xray|gozargah/marzban|ghcr.io/mhsanaei/3x-ui) ]] || continue
        policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null) || policy=unknown
        if [[ "$state" == running || "$policy" =~ ^(always|unless-stopped|on-failure|unknown)$ ]]; then
            printf 'container %s (%s, %s, restart %s)\n' "$name" "$image" "$state" "$policy"
        fi
    done <<<"$list"
    return 0
}

# Relay engines or rules on the server (roomkey runs none): at join they are
# named and the server left as it is; upgrades take PSM's own off (psm relay off).
_coreperm_relays_present() {
    local store="$CFG_DIR/realm/rules.json" e f found=""
    [[ -e "$store" ]] && ! jq -e 'type == "array" and length == 0' "$store" >/dev/null 2>&1 && found+=" rules in $store;"
    for e in realm psm-gost gost; do
        _uses_systemd && systemctl show -p LoadState "$e" 2>/dev/null | grep -qx 'LoadState=loaded' && found+=" $e service;"
        [[ -e "${PSM_INITD_DIR:-/etc/init.d}/$e" ]] && found+=" $e init script;"
    done
    for f in /usr/local/bin/realm /usr/local/bin/psm-gost /usr/local/bin/gost /etc/realm/config.toml /etc/psm-gost/config.json; do
        [[ -e "${PSM_FS_ROOT:-}$f" ]] && found+=" $f;"
    done
    printf '%s' "${found# }"
}

# (Forwards off this server in PSM's own nginx: psm_nginx_forwards,
# lib/nginx_forwards.sh, checked at every reload, start and psm guard.)
# nginx already on the machine: its binary, its service or its config tree.
_coreperm_nginx_present() {
    local root="${PSM_FS_ROOT:-}" found=""
    [[ -x "$root/usr/sbin/nginx" || -x "$root/usr/bin/nginx" || -x "$root/usr/local/sbin/nginx" ]] && found+="${found:+, }binary"
    { [[ -z "$root" ]] && command -v nginx >/dev/null 2>&1; } && [[ "$found" != *binary* ]] && found+="${found:+, }binary"
    # any file or link left under /etc/nginx (a site, a stream route, an
    # include; a linked /etc/nginx): PSM's own nginx.conf loads conf.d and
    # stream.d as they are. Empty directories and PSM's certificates are fine.
    local left; left=$(psm_nginx_leftovers) || found+="${found:+, }${left}"
    [[ -e "$root${PSM_SYSTEMD_DIR:-/etc/systemd/system}/nginx.service" || -e "$root/lib/systemd/system/nginx.service" \
       || -e "$root/usr/lib/systemd/system/nginx.service" || -e "$root${PSM_INITD_DIR:-/etc/init.d}/nginx" ]] && found+="${found:+, }service"
    [[ -n "$found" ]] && printf '%s\n' "$found"
    return 0
}

# Public listening sockets whose owners are not all ordinary system daemons
# (SSH — systemd's ssh.socket included —, DHCP, NTP, a DNS stub) or PSM's own
# cores and nginx (whose configs the other checks read): on a fresh server
# that is all there is. Each owner is read from its PID (/proc/PID/comm), not
# a display column. "name on addr/proto" lines.
_PSM_JOIN_OK_PROCS=" sshd dropbear dhclient dhcpcd udhcpc systemd-network systemd-networkd chronyd ntpd systemd-timesyn systemd-resolve systemd-resolved "
_coreperm_public_listeners() {
    local raw line proto addr pids
    if raw=$(ss -Hltunp 2>/dev/null) || raw=$(ss -ltunp 2>/dev/null | tail -n +2); then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            proto=$(awk '{print $1}' <<<"$line"); addr=$(awk '{print $5}' <<<"$line")
            # every owner, as "pid:name" (the name only stands in if its PID cannot be read)
            pids=$(grep -o '("[^"]*",pid=[0-9]*' <<<"$line" | sed 's/^("\([^"]*\)",pid=\([0-9]*\)$/\2:\1/' | tr '\n' ' ')
            _coreperm_listener_line "$proto" "$addr" "$pids" ""
        done <<<"$raw"
    elif raw=$(netstat -tulnp 2>/dev/null); then
        while IFS= read -r line; do
            [[ "$line" =~ ^(tcp|udp) ]] || continue
            proto=$(awk '{print $1}' <<<"$line"); addr=$(awk '{print $4}' <<<"$line")
            # BusyBox truncates the program column: the PID before the slash is what counts
            pids=$(grep -oE '[[:space:]][0-9]+/' <<<"$line" | tr -dc '0-9 \n' | head -1)
            _coreperm_listener_line "$proto" "$addr" "$pids" ""
        done <<<"$raw"
    else
        echo "(the listening sockets cannot be read: neither ss nor netstat answered)"
    fi
    return 0
}
_coreperm_listener_line() {   # <proto> <local address> <owner pids> <display name>
    local proto="$1" addr="$2" pids="$3" shown="${4:-?}" pid name bad="" port
    case "$addr" in 127.*|\[::1\]:*|::1:*|*%lo:*|localhost:*) return 0 ;; esac
    port="${addr##*:}"
    [[ -n "${pids// /}" ]] || { printf '%s on %s/%s\n' "$shown (no owner shown)" "$addr" "${proto%6}"; return 0; }
    local entry shownname
    for entry in $pids; do
        pid="${entry%%:*}"; shownname="${entry#*:}"; [[ "$shownname" == "$entry" ]] && shownname=""
        name=$(cat "${PSM_PROC_DIR:-/proc}/$pid/comm" 2>/dev/null) || name="${shownname:-unresolved pid $pid}"
        if [[ "$name" == systemd && "$pid" == 1 ]]; then
            # socket activation: fine only for SSH's own stream socket unit
            [[ "${proto%6}" == tcp ]] && _coreperm_ssh_socket "$port" && continue
            bad+="${bad:+,}systemd socket"
            continue
        fi
        [[ "$_PSM_JOIN_OK_PROCS" == *" $name "* ]] || bad+="${bad:+,}$name"
    done
    [[ -z "$bad" ]] || printf '%s on %s/%s\n' "$bad" "$addr" "${proto%6}"
    return 0
}
_coreperm_ssh_socket() {   # <port>: systemd listens there for ssh.socket / sshd.socket
    _uses_systemd || return 1
    systemctl list-sockets --all --no-legend 2>/dev/null \
        | awk -v p="$1" '$1 ~ (":" p "$") && ($2 == "ssh.socket" || $2 == "sshd.socket") && ($3 ~ /^sshd?(@.*)?\.service$/) { f = 1 } END { exit !f }'
}

# The read-only check a join runs before anything on the server changes: every
# core's launch and listeners, the camouflage and open-listener rules on the
# configs as they are, other proxies running, at boot or in containers, relay
# engines, and the standalone Hysteria2 masquerade. "<what>\t<reason>" lines.
_coreperm_join_preflight() {
    local core bin def r v
    for core in xray sing-box mihomo; do
        case "$core" in xray) bin="$XRAY_BIN" ;; sing-box) bin="$SINGBOX_BIN" ;; mihomo) bin="$MIHOMO_BIN" ;; esac
        if _uses_systemd; then def="${PSM_SYSTEMD_DIR:-/etc/systemd/system}/${core}.service"; else def="${PSM_INITD_DIR:-/etc/init.d}/${core}"; fi
        { [[ -x "$bin" ]] || [[ -f "$def" ]] || svc_exists "$core" 2>/dev/null || [[ -f "$(_psm_core_cfg "$core")" ]] \
          || [[ "$(_coreperm_procs "$core" 2>/dev/null)" =~ ^[1-9] ]]; } || continue
        r=$(_coreperm_launch_problem "$core" pre) || r="its start command could not be checked"
        [[ -n "$r" && "$r" != LEGACY ]] && printf '%s\t%s\n' "$core" "$r"
        r=$(_coreperm_unmanaged "$core") || r="(its config could not be checked)"
        [[ -n "$r" ]] && printf '%s\t%s\n' "$core" "its config has inbounds PSM did not make ($r): roomkey joins a server only when PSM makes every proxy on it; remove them (or start from a fresh server), then join again"
        r=$(psm_open_proxy_violations "$core") || r="(its config could not be checked)"
        [[ -n "$r" ]] && printf '%s\t%s\n' "$core" "a listener anyone can use without an account: $(tr '\n' ';' <<<"$r")"
        r=$(psm_fallback_violations "$core") || r="(its config could not be checked)"
        [[ -n "$r" ]] && printf '%s\t%s\n' "$core" "a camouflage fallback off this server: $(tr '\n' ';' <<<"$r")"
    done
    # a fresh server has no PSM nodes yet (the panel makes them after join)
    r=$( { declare -f _node_cli_collect >/dev/null || source "$LIB_DIR/node_cli.sh" >/dev/null 2>&1; } \
         && _node_cli_collect "" "" 2>/dev/null | jq -r 'map("\(.core)/\(.protocol)/\(.tag)") | join(", ")' ) || r="(PSM's node stores cannot be read)"
    [[ -n "$r" ]] && printf 'nodes\t%s\n' "PSM already has nodes here ($r): roomkey joins fresh servers; start from a fresh one (or remove them), then join again"
    r=$(_coreperm_strays) || r="0: the process scan did not finish"
    [[ -n "$r" ]] && printf 'other proxies\t%s\n' "a proxy or relay runs outside PSM's checked services (stop it): $(tr '\n' ';' <<<"$r")"
    r=$( { _coreperm_boot_launchers; _coreperm_proxy_containers; } ) || r="the boot services could not be checked"
    [[ -n "$r" ]] && printf 'boot launchers\t%s\n' "a service or container starts a proxy outside PSM's checked cores (disable or remove it): $(tr '\n' ';' <<<"$r")"
    r=$(_coreperm_relays_present) || r="relay engines could not be checked"
    [[ -n "$r" ]] && printf 'relays\t%s\n' "a relay is set up here ($r): roomkey runs none; remove it (psm relay off), then join again"
    r=$(_coreperm_public_listeners) || r="(the listening sockets could not be checked)"
    [[ -n "$r" ]] && printf 'listeners\t%s\n' "something PSM did not make listens publicly ($(tr '\n' ';' <<<"$r")): roomkey joins fresh servers; stop or remove it, then join again"
    # a standalone server installed before (fresh servers have none): its
    # launch and config are not what PSM would have made
    local sa
    # what PSM's own standalone inventory sees (a Docker Snell, an instance unit)
    for sa in snell ss2022; do
        if ( source "$LIB_DIR/standalone_cli.sh" >/dev/null 2>&1 && _sa_show_json "$sa" 2>/dev/null ) | jq -e '.installed == true or .active == true or .configured == true' >/dev/null 2>&1; then
            printf '%s\t%s\n' "$sa" "a standalone $sa server is already set up here: roomkey joins fresh servers; remove it, then join again"
        fi
    done
    [[ -e "${PSM_FS_ROOT:-}/etc/hysteria/config.yaml" ]] && printf 'hysteria\t%s\n' "a standalone Hysteria2 config is already here (/etc/hysteria/config.yaml): roomkey joins fresh servers; remove it, then join again"
    for sa in hysteria-server snell ss-rust; do
        if [[ -e "${PSM_FS_ROOT:-}/etc/systemd/system/$sa.service" || -e "${PSM_FS_ROOT:-}${PSM_INITD_DIR:-/etc/init.d}/$sa" ]] \
           || { _uses_systemd && systemctl show -p LoadState "$sa" 2>/dev/null | grep -qx 'LoadState=loaded'; }; then
            printf '%s\t%s\n' "$sa" "a standalone $sa service is already installed: roomkey joins fresh servers; remove it, then join again"
        fi
    done
    # nginx: PSM installs and configures it itself with the first node that
    # needs it (the camouflage site, the shared 443); one already here has
    # sites and routes whose origin PSM cannot know, which PSM's first start
    # of nginx would bring up as they are
    r=$(_coreperm_nginx_present) || r="nginx could not be checked"
    [[ -n "$r" ]] && printf 'nginx\t%s\n' "nginx is already installed here ($r): roomkey joins fresh servers and sets nginx up itself; remove it (with its configuration), then join again"
    v="${PSM_FS_ROOT:-}/etc/hysteria/config.yaml"
    if ! psm_hy2_standalone_ok "$v" >/dev/null 2>&1; then
        printf 'hysteria\t%s\n' "the standalone Hysteria2 masquerade proxies a site, or its config cannot be read ($v): remove it, then join again"
    fi
    return 0
}

psm_guard_all() {
    local json=0 out='[]' core bin def hook ok state reason launch
    [[ "${1:-}" == --json ]] && json=1
    # Joining: the whole server is checked before anything on it changes; a
    # server with anything PSM did not make is refused as it is.
    if [[ -n "${PSM_GUARD_JOIN:-}" ]]; then
        local pre what why
        pre=$(_coreperm_join_preflight) || pre=$'join\tthe join check did not finish'
        if [[ -n "$pre" ]]; then
            while IFS=$'\t' read -r what why; do
                [[ -n "$what" ]] || continue
                out=$(jq -c --arg c "$what" --arg r "$why" '. + [{core: $c, hook: false, ok: false, state: "unsafe", stopped: false, reason: $r}]' <<<"$out")
            done <<<"$pre"
            if (( json )); then jq -c '{cores: .}' <<<"$out"
            else jq -r '.[] | "\(.core)\tUNSAFE: \(.reason)"' <<<"$out"; fi
            return 2
        fi
    fi
    for core in xray sing-box mihomo; do
        case "$core" in
            xray) bin="$XRAY_BIN" ;; sing-box) bin="$SINGBOX_BIN" ;; mihomo) bin="$MIHOMO_BIN" ;;
        esac
        if _uses_systemd; then def="${PSM_SYSTEMD_DIR:-/etc/systemd/system}/${core}.service"; else def="${PSM_INITD_DIR:-/etc/init.d}/${core}"; fi
        # a core is covered if it has a service (anywhere the manager loads
        # it from) or runs, whether or not its binary is where PSM expects it
        if ! { [[ -x "$bin" ]] || [[ -f "$def" ]] || svc_exists "$core" 2>/dev/null || [[ "$(_coreperm_svc_state "$core")" == active ]] \
                 || [[ "$(_coreperm_procs "$core" 2>/dev/null)" =~ ^[1-9] ]]; }; then
            continue
        fi
        hook=true; ok=true; state=checked; reason=""
        # Before anything is written: a launch PSM does not know, or (joining)
        # inbounds no PSM node owns, are refused with the server as it is
        launch=$(_coreperm_launch_problem "$core" pre) || launch="its start command could not be checked"
        # an upstream PSM launch: migrated to PSM's own unit, hook or not
        local legacy=0; [[ "$launch" == LEGACY ]] && { legacy=1; launch=""; }
        if [[ -z "$launch" && -n "${PSM_GUARD_JOIN:-}" ]]; then
            launch=$(_coreperm_unmanaged "$core") || launch="(its config could not be checked)"
            [[ -z "$launch" ]] || launch="its config has inbounds PSM did not make ($launch): roomkey joins a server only when PSM makes every proxy on it; remove them (or start from a fresh server), then join again"
        fi
        if [[ -n "$launch" ]]; then
            out=$(jq -c --arg c "$core" --arg r "$launch" \
                '. + [{core: $c, hook: false, ok: false, state: "unsafe", stopped: false, reason: $r}]' <<<"$out")
            continue
        fi
        if (( legacy )) || ! { _coreperm_has_hook "$def" "$core" && _coreperm_loaded_hook "$core"; }; then
            # in a subshell: a writer that fails (or exits) is a missing hook, never the end of the guard
            if ! ( case "$core" in
                       xray)     source "$LIB_DIR/xray/core.sh";    _write_xray_service ;;
                       sing-box) source "$LIB_DIR/singbox/core.sh"; _sb_write_service ;;
                       mihomo)   source "$LIB_DIR/mihomo/core.sh";  _mh_write_service ;;
                   esac ) >/dev/null 2>&1; then
                hook=false
            elif _uses_systemd && ! systemctl daemon-reload >/dev/null 2>&1; then
                hook=false
            fi
            [[ "$hook" == true ]] && _coreperm_has_hook "$def" "$core" && _coreperm_loaded_hook "$core" || hook=false
        fi
        # (after PSM's unit is in place) a start command or environment that
        # is not PSM's, from a drop-in: refused as it is, the core untouched
        launch=""
        [[ "$hook" == true ]] && { launch=$(_coreperm_launch_problem "$core" post) || launch="its start command could not be checked"; }
        if [[ -n "$launch" ]]; then
            out=$(jq -c --arg c "$core" --arg r "$launch" \
                '. + [{core: $c, hook: true, ok: false, state: "unsafe", stopped: false, reason: $r}]' <<<"$out")
            continue
        fi
        if [[ "$hook" != true ]]; then
            # nothing would check its next start: down, and not started at boot —
            # both read back from the service manager, or it is unsafe
            ok=false; reason="its service has no start check and could not be given one"
            svc_stop "$core" >/dev/null 2>&1 || true
            svc_disable "$core" >/dev/null 2>&1 || true
            if [[ "$(_coreperm_svc_state "$core")" == inactive && "$(_coreperm_svc_boot "$core")" == disabled ]]; then state=stopped
            else state=unsafe; reason="$reason, and it could not be shown stopped and disabled"; fi
        elif ! reason=$(psm_users_merge "$core" 2>&1 >/dev/null); then
            ok=false
            svc_stop "$core" >/dev/null 2>&1 || true
            if [[ "$(_coreperm_svc_state "$core")" == inactive ]]; then state=stopped
            else state=unsafe; reason="could not be shown stopped: ${reason##*$'\n'}"; fi
        else
            case "$(_coreperm_svc_state "$core")" in
                inactive) ;;
                active)
                    # running: restarted through the hook, so the checked config is what serves
                    if ! svc_restart "$core" >/dev/null 2>&1 || [[ "$(_coreperm_svc_state "$core")" != active ]]; then
                        ok=false; reason="did not start again with the checked config"
                        svc_stop "$core" >/dev/null 2>&1 || true
                        if [[ "$(_coreperm_svc_state "$core")" == inactive ]]; then state=stopped; else state=unsafe; fi
                    fi ;;
                *) ok=false; state=unsafe; reason="the service manager did not say whether it runs, or a process of it runs outside its service" ;;
            esac
        fi
    out=$(jq -c --arg c "$core" --argjson h "$hook" --argjson o "$ok" --arg st "$state" --arg r "${reason##*$'\n'}" \
            '. + [{core: $c, hook: $h, ok: $o, state: $st, stopped: ($st == "stopped"), reason: (if $o then null else $r end)}]' <<<"$out")
    done
    # roomkey runs no relays: every rule removed, realm and gost verified off
    # (lib/relay_cli.sh psm_relays_off) — a forward an older PSM or panel set
    # up must not outlive a join or an upgrade
    local rel rrc=0
    rel=$( source "$LIB_DIR/relay_cli.sh" && psm_relays_off --json 2>/dev/null ) || rrc=$?
    jq -e 'type == "object"' <<<"$rel" >/dev/null 2>&1 || rel='{"removed":[],"failed":["the relay check did not finish"]}'
    out=$(jq -c --argjson r "$rel" --argjson rc "$rrc" \
        '. + [{core: "relays", hook: true, ok: ($rc == 0 and ($r.failed | length) == 0), removed: $r.removed,
               state: (if $rc == 0 and ($r.failed | length) == 0 then "checked" else "unsafe" end),
               stopped: false, reason: (if $rc == 0 and ($r.failed | length) == 0 then null else ($r.failed | join("; ")) end)}]' <<<"$out")
    # nginx: no forward off this server (roomkey's sites and SNI routes go to
    # 127.0.0.1 only); one found stops nginx, which then must be shown stopped
    if [[ -d "${PSM_FS_ROOT:-}/etc/nginx" ]]; then
        local fwd nst="checked" nok=true nrs=""
        fwd=$(psm_nginx_forwards)
        if [[ -n "$fwd" ]]; then
            nok=false; nrs="a forward leaves this server ($(tr '\n' ';' <<<"$fwd")): nginx stopped; remove it, then start nginx"
            svc_stop nginx >/dev/null 2>&1 || true
            if [[ "$(_coreperm_svc_state nginx)" == inactive ]]; then nst=stopped; else nst=unsafe; nrs="${nrs%: nginx stopped*}: and nginx could not be stopped"; fi
        else
            psm_nginx_start_hook >/dev/null 2>&1 || true
        fi
        out=$(jq -c --argjson o "$nok" --arg st "$nst" --arg r "$nrs" \
            '. + [{core: "nginx", hook: true, ok: $o, state: $st, stopped: ($st == "stopped"), reason: (if $o then null else $r end)}]' <<<"$out")
    fi
    # every proxy process now running is one of PSM's checked cores, started
    # with the config the check reads; anything else must be stopped by hand
    local strays boot
    strays=$(_coreperm_strays) || strays="0: the process scan did not finish"
    if [[ -n "$strays" ]]; then
        out=$(jq -c --arg r "a proxy runs outside PSM's checked services (stop it; nothing checks its fallback): $(tr '\n' ';' <<<"$strays")" \
            '. + [{core: "other proxies", hook: false, ok: false, state: "unsafe", stopped: false, reason: $r}]' <<<"$out")
    fi
    boot=$( { _coreperm_boot_launchers; _coreperm_proxy_containers; } ) || boot="the boot services could not be checked"
    if [[ -n "$boot" ]]; then
        out=$(jq -c --arg r "a service or container starts a proxy outside PSM's checked cores (disable or remove it): $(tr '\n' ';' <<<"$boot")" \
            '. + [{core: "boot launchers", hook: false, ok: false, state: "unsafe", stopped: false, reason: $r}]' <<<"$out")
    fi
    if (( json )); then jq -c '{cores: .}' <<<"$out"
    else jq -r '.[] | "\(.core)\thook=\(.hook)\tok=\(.ok)\(if (.removed // []) != [] then "\tremoved: " + (.removed | join(", ")) else "" end)\(if .state == "stopped" then "\tSTOPPED: " + .reason elif .state == "unsafe" then "\tUNSAFE: " + .reason else "" end)"' <<<"$out"; fi
    jq -e 'any(.[]; .state == "unsafe")' <<<"$out" >/dev/null && return 2
    jq -e 'all(.[]; .ok)' <<<"$out" >/dev/null || return 10
    return 0
}
