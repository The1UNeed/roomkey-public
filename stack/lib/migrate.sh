#!/usr/bin/env bash
# migrate.sh — a bundle of this server (export only)
#
#   psm migrate export [--output FILE] [--no-encrypt]
#
# A bundle is a tar.gz: manifest.json (source host, core versions, scheduled
# jobs), SHA256SUMS, config/ (PSM's own state) and files/ (every other path
# PSM owns, mirrored from /). It is an archive to keep, not something to
# rebuild a server from: roomkey moves a server through the panel (add the new
# server, recreate its nodes there), so "psm migrate import" and "psm migrate
# push" are off. A bundle would bring nodes, users and an nginx the panel never
# checked.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MIG_FORMAT=1
MIG_CORES=(xray sing-box mihomo)
# Caches the cores rebuild by themselves (geodata alone is tens of MB), and logs.
MIG_EXCLUDES=('*.db' '*.dat' '*.mmdb' '*.metadb' '*.prev' '*.log'
    # a server's own enrollment and agent state, and an unfinished restore, stay on it
    'etc/psm/agent.json' 'etc/psm/agent-*.json' '.psm-restore' '.psm-users.lock'
    # roomkey runs no relays: no rule travels
    'realm/rules.json')

_mig_usage() { printf '%s\n' "$(t migrate.usage)" >&2; }

# Absolute paths carried under files/ (absent ones are skipped). PSM's own
# state goes to config/ instead: PSM may live elsewhere on the new host.
_mig_paths() {
    local f
    printf '%s\n' "$XRAY_CFG_DIR" "$SINGBOX_CFG_DIR" "$MIHOMO_CFG_DIR" \
        /etc/hysteria /etc/ss-rust /etc/snell /etc/psm \
        "$NGINX_SSL_DIR" "$NGINX_STREAM_DIR" /var/www/psm-camouflage "$ACME_HOME"
    # PSM's own Nginx sites; not the distro's files, nor acme.sh's temporary ones
    for f in "$NGINX_HTTP_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        case "${f##*/}" in default.conf|stream.conf|_acme_*) continue ;; esac
        printf '%s\n' "$f"
    done
}

_mig_core_version() {   # xray|sing-box|mihomo → vX.Y.Z; nothing when not installed
    local bin v=""
    case "$1" in
        xray)     bin="$XRAY_BIN" ;;
        sing-box) bin="$SINGBOX_BIN" ;;
        mihomo)   bin="$MIHOMO_BIN" ;;
        *) return 0 ;;
    esac
    [[ -x "$bin" ]] || return 0
    if [[ "$1" == mihomo ]]; then v=$("$bin" -v 2>/dev/null | head -1 || true)
    else v=$("$bin" version 2>/dev/null | head -1 || true); fi
    v=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' <<<"$v" | head -1 || true)
    [[ -n "$v" ]] && printf 'v%s' "$v"
    return 0
}

_mig_node_count() {   # <PSM config dir> → nodes in the three cores' stores
    local f n=0 k
    for f in "$1"/xray/*.json "$1"/singbox/*.json "$1"/mihomo/*.json; do
        [[ -f "$f" ]] || continue
        k=$(jq '[.[]? | objects | select(.tag != null and .port != null)] | length' "$f" 2>/dev/null || true)
        [[ "$k" =~ ^[0-9]+$ ]] && n=$((n + k))
    done
    printf '%s' "$n"
}

_mig_jobs_json() {
    local traffic=false ruleset=false rwd=false hr=false tgbot=false hour=""
    ( source "$LIB_DIR/traffic.sh"; _trf_timer_active ) >/dev/null 2>&1 && traffic=true
    ( source "$LIB_DIR/ruleset/apply.sh"; rs_timer_active ) >/dev/null 2>&1 && ruleset=true
    ( source "$LIB_DIR/xray/reality_watchdog.sh"; _rwd_timer_active ) >/dev/null 2>&1 && rwd=true
    ( source "$LIB_DIR/tgbot/health_report.sh"; _hr_timer_active ) >/dev/null 2>&1 && hr=true
    svc_is_active psm-tgbot >/dev/null 2>&1 && tgbot=true
    [[ -f /etc/cron.d/psm-backup ]] && hour=$(awk '!/^#/ && NF { print $2; exit }' /etc/cron.d/psm-backup)
    jq -nc --argjson t "$traffic" --argjson r "$ruleset" --argjson w "$rwd" --argjson h "$hr" \
        --argjson b "$tgbot" --arg hour "$hour" \
        '{traffic:$t, ruleset:$r, reality_watchdog:$w, health_report:$h, tgbot:$b,
          backup_hour:(if $hour == "" then null else $hour end)}'
}

_mig_manifest() {
    local cores='{}' c v nginx=false
    for c in "${MIG_CORES[@]}"; do
        v=$(_mig_core_version "$c")
        [[ -n "$v" ]] && cores=$(jq -c --arg c "$c" --arg v "$v" '. + {($c): $v}' <<<"$cores")
    done
    if command -v nginx >/dev/null 2>&1 && [[ -d "$NGINX_STREAM_DIR" || -d /var/www/psm-camouflage ]]; then
        nginx=true
    fi
    jq -n --argjson format "$MIG_FORMAT" \
        --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg rev "$(git -C "$PSM_ROOT" rev-parse --short HEAD 2>/dev/null || true)" \
        --arg host "$(hostname 2>/dev/null || true)" \
        --arg ip4 "$(get_ipv4 2>/dev/null || true)" \
        --arg os "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")" \
        --arg init "$(_uses_systemd && echo systemd || echo openrc)" \
        --arg arch "$(uname -m)" --arg cfg "$CFG_DIR" \
        --argjson cores "$cores" --argjson nginx "$nginx" \
        --argjson jobs "$(_mig_jobs_json)" --argjson nodes "$(_mig_node_count "$CFG_DIR")" \
        '{format:$format, created:$created, psm_rev:$rev,
          source:{hostname:$host, ipv4:$ip4, os:$os, init:$init, arch:$arch, cfg_dir:$cfg},
          cores:$cores, nginx:$nginx, jobs:$jobs, nodes:$nodes}'
}

# <work dir> → config/, files/, manifest.json, SHA256SUMS
_mig_collect() {
    local work="$1" p ex=() rel=()
    mkdir -p "$work/config" "$work/files"
    for p in "${MIG_EXCLUDES[@]}"; do ex+=("--exclude=$p"); done
    tar -C "$CFG_DIR" "${ex[@]}" -cf - . | tar -C "$work/config" -xf - || return 1
    while IFS= read -r p; do
        [[ -e "$p" ]] && rel+=("${p#/}")
    done < <(_mig_paths)
    if (( ${#rel[@]} )); then
        tar -C / "${ex[@]}" -cf - "${rel[@]}" | tar -C "$work/files" -xf - || return 1
    fi
    _mig_manifest > "$work/manifest.json" || return 1
    ( cd "$work" && find config files -type f -exec sha256sum {} + ) > "$work/SHA256SUMS" || return 1
}

_mig_passphrase() {   # new|existing → prints the passphrase
    if [[ -n "${PSM_MIGRATE_PASS:-}" ]]; then printf '%s' "$PSM_MIGRATE_PASS"; return 0; fi
    [[ -t 0 ]] || { log_error "$(t migrate.need_pass)"; return 1; }
    local a b=""
    read -rsp "$(t migrate.ask_pass) " a; echo >&2
    if [[ "$1" == new ]]; then
        read -rsp "$(t migrate.ask_pass2) " b; echo >&2
        [[ -n "$a" && "$a" == "$b" ]] || { log_error "$(t migrate.pass_mismatch)"; return 1; }
    fi
    printf '%s' "$a"
}

# <out> <encrypt 0|1> [passphrase]: writes the bundle, 0600
_mig_export_to() {
    local out="$1" encrypt="$2" pass="${3:-}" work nodes
    [[ -d "$CFG_DIR" ]] || { log_error "$(t migrate.nothing)"; return 1; }
    ensure_pkg_deps tar jq openssl >/dev/null 2>&1 || true
    work=$(mktemp -d)
    log_step "$(t migrate.exporting)"
    if ! _mig_collect "$work" \
        || ! ( cd "$work" && tar -czf bundle.tgz manifest.json SHA256SUMS config files ); then
        rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1
    fi
    nodes=$(jq -r '.nodes' "$work/manifest.json")
    mkdir -p "$(dirname "$out")"
    if (( encrypt )); then
        openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
            -pass fd:3 -in "$work/bundle.tgz" -out "$out" 3< <(printf '%s' "$pass") \
            || { rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1; }
    else
        mv "$work/bundle.tgz" "$out" || { rm -rf "$work"; log_error "$(t migrate.pack_failed)"; return 1; }
    fi
    chmod 600 "$out"
    rm -rf "$work"
    log_ok "$(t migrate.exported "$out" "$(du -h "$out" | cut -f1)" "$nodes")"
}

# Encrypted unless asked not to be: a bundle is every private key and password
# of the server, and it gets copied around. --encrypt, the default now, is
# still taken from scripts written when it was not.
psm_migrate_export() {
    local out="" encrypt=1 pass=""
    while (( $# )); do
        case "$1" in
            --output|-o) [[ -n "${2:-}" ]] || { _mig_usage; return 2; }; out="$2"; shift 2; continue ;;
            --encrypt) encrypt=1 ;;
            --no-encrypt) encrypt=0 ;;
            *) _mig_usage; return 2 ;;
        esac
        shift
    done
    require_root
    [[ -n "$out" ]] || out="/root/psm-migrate-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).tgz"
    if (( encrypt )); then pass=$(_mig_passphrase new) || return 1; fi
    _mig_export_to "$out" "$encrypt" "$pass" || return 1
    log_warn "$(t migrate.secret_warn)"
    log_info "$(t migrate.next_steps "$out")"
    printf '%s\n' "$out"
}

MIG_OFF="roomkey moves servers through the panel: add the new server there and recreate its nodes"

psm_migrate_import() { log_error "$MIG_OFF (psm migrate import is off)"; return 2; }
psm_migrate_push()   { log_error "$MIG_OFF (psm migrate push is off)"; return 2; }

# the menu entry refuses at once, without asking for a file first
migrate_menu_import() { psm_migrate_import; }

psm_migrate_cli() {
    local cmd="${1:-}"
    (( $# )) && shift
    case "$cmd" in
        export) psm_migrate_export "$@" ;;
        import) psm_migrate_import ;;
        push)   psm_migrate_push ;;
        -h|--help|help) printf '%s\n' "$(t migrate.usage)" ;;
        *) _mig_usage; return 2 ;;
    esac
}
