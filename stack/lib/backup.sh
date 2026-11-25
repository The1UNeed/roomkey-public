#!/usr/bin/env bash
# backup.sh — backup and restore for PSM-managed configs

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BAK_ROOT="$BAK_DIR"
MAX_BACKUPS=10

# Backups hold every key and password PSM keeps: the directory is root's alone
# (a quick backup is a plain directory in it, so this covers its files too),
# and an archive is written 600.
_backup_root() { mkdir -p "$BAK_ROOT" && chmod 700 "$BAK_ROOT"; }

# ── Quick backup (called before modifications) ────────────────────────────────
do_quick_backup() {
    local desc="${1:-manual}"
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_${desc//[^A-Za-z0-9._-]/_}"
    local bak="$BAK_ROOT/$name" src dst failed=""
    _backup_root && mkdir -p "$bak" || return 1

    # Nginx, Xray, Hysteria2, PSM's own state, the certificates. A copy that
    # fails (a full disk) is said, not swallowed: an incomplete backup that
    # looks complete is worse than none.
    while IFS='|' read -r src dst; do
        [[ -d "$src" ]] || continue
        cp -a "$src" "$bak/$dst" 2>/dev/null || failed+="${failed:+, }$dst"
    done <<EOF
/etc/nginx|nginx
$XRAY_CFG_DIR|xray
/etc/hysteria|hysteria
$CFG_DIR|psm_config
$NGINX_SSL_DIR|ssl
EOF
    [[ -z "$failed" ]] || log_warn "$(t backup.copy_failed "$failed" "$bak")"

    _rotate_backups
    log_ok "$(t backup.quick_saved "$bak")"
    echo "$bak"
}

# ── Full backup ───────────────────────────────────────────────────────────────
do_full_backup() {
    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local name="${ts}_full"
    local bak="$BAK_ROOT/$name"
    _backup_root && mkdir -p "$bak" || return 1

    log_step "$(t backup.full_creating "$bak")"

    # All PSM components
    [[ -d /etc/nginx      ]] && cp -a /etc/nginx      "$bak/nginx"
    [[ -d "$XRAY_CFG_DIR" ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray"
    [[ -d /etc/hysteria   ]] && cp -a /etc/hysteria   "$bak/hysteria"
    [[ -d "$CFG_DIR"      ]] && cp -a "$CFG_DIR"      "$bak/psm_config"
    [[ -d "$NGINX_SSL_DIR" ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl"

    # Docker compose files (includes any bind-mount data dirs under them)
    [[ -d /opt/psm/compose ]] && cp -a /opt/psm/compose "$bak/docker_compose"

    # Docker named volumes (Portainer/Vaultwarden/etc. — live outside /opt/psm/compose)
    source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
        && declare -f docker_backup_volumes &>/dev/null \
        && docker_backup_volumes "$bak"

    # Compress
    local archive="$BAK_ROOT/${name}.tar.gz"
    ( umask 077; tar -czf "$archive" -C "$BAK_ROOT" "$name" ) && rm -rf "$bak"
    chmod 600 "$archive" 2>/dev/null || true
    _rotate_backups
    log_ok "$(t backup.full_done "$archive")"
    echo "$archive"
}

# ── Selective backup ──────────────────────────────────────────────────────────
do_selective_backup() {
    echo -e "\n  $(t backup.select_prompt)"
    echo    "  1. $(t backup.item.nginx)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_compose)"
    echo    "  7. $(t backup.item.docker_volumes)"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" choices

    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local bak="$BAK_ROOT/${ts}_selective"
    _backup_root && mkdir -p "$bak" || return 1

    for c in $choices; do
        case "$c" in
            1) [[ -d /etc/nginx        ]] && cp -a /etc/nginx      "$bak/nginx" ;;
            2) [[ -d "$XRAY_CFG_DIR"   ]] && cp -a "$XRAY_CFG_DIR" "$bak/xray" ;;
            3) [[ -d /etc/hysteria     ]] && cp -a /etc/hysteria   "$bak/hysteria" ;;
            4) [[ -d "$CFG_DIR"        ]] && cp -a "$CFG_DIR"      "$bak/psm_config" ;;
            5) [[ -d "$NGINX_SSL_DIR"  ]] && cp -a "$NGINX_SSL_DIR" "$bak/ssl" ;;
            6) [[ -d /opt/psm/compose  ]] && cp -a /opt/psm/compose "$bak/docker_compose" ;;
            7) source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                   && declare -f docker_backup_volumes &>/dev/null \
                   && docker_backup_volumes "$bak" ;;
        esac
    done

    local archive="$BAK_ROOT/${ts}_selective.tar.gz"
    ( umask 077; tar -czf "$archive" -C "$BAK_ROOT" "${ts}_selective" ) && rm -rf "$bak"
    chmod 600 "$archive" 2>/dev/null || true
    _rotate_backups
    log_ok "$(t backup.select_done "$archive")"
}

# ── List backups ──────────────────────────────────────────────────────────────
list_backups() {
    echo -e "\n${BOLD}$(t backup.available)${NC}"
    local i=1
    find "$BAK_ROOT" -mindepth 1 -maxdepth 1 \( -name "*.tar.gz" -o -type d \) \
        | sort -r | while read -r f; do
            local size; size=$(du -sh "$f" 2>/dev/null | cut -f1)
            printf "  %2d. %-50s %s\n" "$i" "$(basename "$f")" "$size"
            ((i++))
          done
}

# ── Restore ───────────────────────────────────────────────────────────────────
# From a full / selective archive or a quick backup (a directory). Nothing is
# stopped or replaced until the backup has been opened; the current state is
# saved first as a quick backup, and each component is copied next to the live
# one before it takes its place, so a copy that fails (a full disk) leaves the
# live component as it was.
do_restore() {
    list_backups
    local archive; ask archive "$(t backup.ask_archive)"
    archive=$(basename -- "$archive")   # a name in the list, never a path out of it
    local full_path="$BAK_ROOT/$archive"
    [[ -n "$archive" && ( -f "$full_path" || -d "$full_path" ) ]] || { log_error "$(t backup.not_found "$full_path")"; return 1; }

    ask_yn "$(t backup.ask_restore "$archive")" N || return 0

    local tmp_dir bak_dir
    tmp_dir=$(mktemp -d) || return 1
    if [[ -d "$full_path" ]]; then
        # a copy: the backup taken before restoring rotates old quick backups,
        # and this one may be the oldest
        cp -a "$full_path" "$tmp_dir/" 2>/dev/null || { rm -rf "$tmp_dir"; log_error "$(t backup.extract_failed "$full_path")"; return 1; }
        bak_dir="$tmp_dir/$archive"
    else
        if ! tar -xzf "$full_path" -C "$tmp_dir" 2>/dev/null; then
            rm -rf "$tmp_dir"
            log_error "$(t backup.extract_failed "$full_path")"; return 1
        fi
        # a backup is one directory; anything else (a migration export: a
        # manifest, checksums, config/ and files/ side by side) is refused
        # before anything stops or is copied
        if [[ "$(find "$tmp_dir" -mindepth 1 -maxdepth 1 | wc -l)" -ne 1 ]]; then
            rm -rf "$tmp_dir"; log_error "psm restore: $archive is not a PSM backup (a migration export?); nothing was restored"; return 1
        fi
        bak_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)
        [[ -n "$bak_dir" ]] || { rm -rf "$tmp_dir"; log_error "$(t backup.extract_failed "$full_path")"; return 1; }
    fi
    if ! _restore_layout_ok "$bak_dir"; then
        rm -rf "$tmp_dir"; log_error "psm restore: $archive is not a PSM backup (a migration export?); nothing was restored"; return 1
    fi

    # roomkey never restores nginx: an old site or stream route could forward
    # anywhere, and PSM's own nginx (the shared 443, the camouflage site) is
    # what this server already has
    echo -e "\n  $(t backup.restore_prompt)"
    echo    "  2. $(t backup.item.xray)"
    echo    "  3. $(t backup.item.hysteria)"
    echo    "  4. $(t backup.item.psm)"
    echo    "  5. $(t backup.item.ssl)"
    echo    "  6. $(t backup.item.docker_restore)"
    echo    "  7. $(t backup.item.all)"
    read -rp "$(echo -e "${CYAN}$(t backup.select_default7)${NC}")" rc; rc="${rc:-7}"
    # one validated list for the copies below: 7 is everything restorable
    local -a picks=(); local c
    for c in $rc; do
        case "$c" in
            7) picks=(2 3 4 5 6); break ;;
            1) log_warn "psm restore: nginx is never restored (roomkey keeps the server's own)" ;;
            [2-6]) [[ " ${picks[*]} " == *" $c "* ]] || picks+=("$c") ;;
            *) log_warn "psm restore: '$c' is not a choice, left out" ;;
        esac
    done
    (( ${#picks[@]} )) || { rm -rf "$tmp_dir"; log_error "psm restore: nothing chosen"; return 1; }
    rc="${picks[*]}"

    # what is live now, in case this backup turns out to be the wrong one
    local pre; pre=$(do_quick_backup pre-restore 2>/dev/null | tail -1) && log_info "$(t backup.pre_restore "$pre")"

    _stop_services || { rm -rf "$tmp_dir"; return 1; }

    # Under the user lock (psm-agent's imports and the minute timer wait), and
    # in a subshell so the lock goes with it: the restore, then the user store
    # put right (_restore_users_store).
    local sub=0
    (
    source "$LIB_DIR/users.sh"
    # no lock, no restore: a revocation written meanwhile would be overwritten
    _users_lock || exit 1
    _restore_keep_begin || exit 5
    # each component: restored (said), not in this backup (skipped), or failed
    # (the restore as a whole then fails, after the stores are put right)
    local failed=0 r
    for c in $rc; do
        r=0
        case "$c" in
            2) _restore_dir "$bak_dir/xray" "$XRAY_CFG_DIR" || r=$?; (( r )) || log_ok "$(t backup.restored.xray)" ;;
            3) _restore_dir "$bak_dir/hysteria" /etc/hysteria || r=$?; (( r )) || log_ok "$(t backup.restored.hysteria)" ;;
            4) _restore_dir "$bak_dir/psm_config" "$CFG_DIR" || r=$?; (( r )) || log_ok "$(t backup.restored.psm)" ;;
            5) _restore_certs "$bak_dir/ssl" "$NGINX_SSL_DIR" || r=$?; (( r )) || log_ok "$(t backup.restored.ssl)" ;;
            6)
                _restore_dir "$bak_dir/docker_compose" /opt/psm/compose || r=$?; (( r )) || log_ok "$(t backup.restored.docker)"
                (( r == 2 )) && r=0
                if [[ -d "$bak_dir/docker_volumes" ]]; then
                    source "$LIB_DIR/docker/backup.sh" 2>/dev/null \
                        && declare -f docker_restore_volumes &>/dev/null \
                        && docker_restore_volumes "$bak_dir" || r=1
                fi
                ;;
        esac
        (( r == 0 || r == 2 )) || failed=1
    done
    # both put right, and either failing is said (a later success must not hide it)
    _restore_keep_end || exit 4
    (( failed )) && exit 6
    exit 0
    ) || sub=$?
    rm -rf "$tmp_dir"
    case "$sub" in
        0) ;;
        4)  # restored, but the user store or the relay rules could not be put
            # right: the cores stay down until that is fixed (a start would
            # serve the archive's accounts)
            log_error "psm restore: the user store or the relay rules could not be put right after the restore; nginx, xray and hysteria were not started again, and no core starts until a restore finishes. Fix the cause (disk full?) and restore again"
            return 1 ;;
        5)  _start_services
            log_error "psm restore: what is here now could not be kept aside first (disk full?): nothing was restored"
            return 1 ;;
        6)  # a component did not take (it is as it was, see above); the rest did
            _start_services || true
            log_error "psm restore: a part of the backup could not be restored (see above); the rest was"
            return 1 ;;
        *)  _start_services
            log_error "psm user: the user lock is held (an import running?): nothing was restored, try again"
            return 1 ;;
    esac

    if ! _start_services; then
        log_error "psm restore: restored, but a service that ran before did not start again (see above)"
        return 1
    fi
    log_ok "$(t backup.restore_done)"
}

# A PSM backup: a directory of its components (xray, hysteria, psm_config, ssl,
# docker_compose, docker_volumes), with none of a migration export's files.
_restore_layout_ok() {   # <dir>
    local d="$1" n
    [[ -e "$d/manifest.json" || -e "$d/SHA256SUMS" || -d "$d/files" || -d "$d/config" ]] && return 1
    for n in xray hysteria psm_config ssl docker_compose docker_volumes; do [[ -d "$d/$n" ]] && return 0; done
    return 1
}

# Certificates: the backup's are added to what is here, never in place of it.
# A certificate issued since the backup (and used by a site now) stays, and a
# file here that is newer than the backup's copy is kept. If nginx then fails
# its config test, the certificates that were here go back.
_restore_certs() {   # <from> <live dir>
    local from="$1" live="$2" next="$2.psm-restore" prev="$2.psm-prev" f rel
    [[ -d "$from" ]] || return 2   # not in this backup
    rm -rf "$next" "$prev"
    if [[ -d "$live" ]]; then cp -a "$live" "$next" 2>/dev/null || { rm -rf "$next"; log_error "$(t backup.restore_item_failed "$live")"; return 1; }
    else mkdir -p "$next" || return 1; fi
    while IFS= read -r -d '' f; do
        rel="${f#"$from"/}"
        [[ -e "$next/$rel" && ! "$f" -nt "$next/$rel" ]] && continue
        mkdir -p "$(dirname "$next/$rel")" && cp -a "$f" "$next/$rel" \
            || { rm -rf "$next"; log_error "$(t backup.restore_item_failed "$live")"; return 1; }
    done < <(find "$from" -type f -print0)
    [[ -d "$live" ]] && { mv "$live" "$prev" || { rm -rf "$next"; return 1; }; }
    mv "$next" "$live" || { [[ -d "$prev" ]] && mv "$prev" "$live"; return 1; }
    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        rm -rf "$live"; [[ -d "$prev" ]] && mv "$prev" "$live"
        log_error "psm restore: nginx's config test failed with the restored certificates; the ones that were here are back"
        return 1
    fi
    rm -rf "$prev"
}

# What was here before a restore (or a migration import) is kept beside the
# config directory until both stores are put right: one that stops half way
# leaves a marker that keeps the cores from starting (psm_users_merge) and
# user imports out (_users_cmd_import), and the next try takes the stores from
# here, not from the half-restored disk. Run under the user lock.
RESTORE_KEEP="$(dirname "$CFG_DIR")/.psm-restore"
_restore_keep_begin() {   # sets RESTORE_CUR_USERS, RESTORE_CUR_RELAYS
    RESTORE_CUR_USERS=""; RESTORE_CUR_RELAYS=""
    if [[ -e "$RESTORE_KEEP/incomplete" ]]; then
        RESTORE_CUR_USERS=$(cat "$RESTORE_KEEP/users.json" 2>/dev/null) || return 1
        RESTORE_CUR_RELAYS=$(cat "$RESTORE_KEEP/relays.json" 2>/dev/null) || return 1
        return 0
    fi
    [[ -f "$USERS_FILE" ]] && RESTORE_CUR_USERS=$(cat "$USERS_FILE" 2>/dev/null)
    [[ -f "$RELAY_STORE_FILE" ]] && RESTORE_CUR_RELAYS=$(cat "$RELAY_STORE_FILE" 2>/dev/null)
    ( umask 077; mkdir -p "$RESTORE_KEEP" && printf '%s' "$RESTORE_CUR_USERS" >"$RESTORE_KEEP/users.json" \
        && printf '%s' "$RESTORE_CUR_RELAYS" >"$RESTORE_KEEP/relays.json" && : >"$RESTORE_KEEP/incomplete" )
}
_restore_keep_end() {
    _restore_users_store "$RESTORE_CUR_USERS" || return 1
    _restore_relay_store "$RESTORE_CUR_RELAYS" || return 1
    rm -rf "$RESTORE_KEEP"
}

# The user store after a restore. The panel's users are the panel's, not the
# archive's: a user revoked since the backup was taken must not come back.
#   - A store was here before: it is kept as it was (accounts, revision,
#     counters), whatever the archive held.
#   - None was (a rebuilt server): the archive's panel users are dropped, with
#     its revision, so the panel sends its current list at the next sync.
# Either way the cores are told to take the accounts again (applied_fp): a
# restored core config is not what they last took, and every start merges.
_restore_users_store() {   # <the store before the restore, or "">
    command -v jq >/dev/null 2>&1 || return 0
    local next u
    if [[ -n "$1" ]]; then
        next=$(jq -c 'del(.applied_fp)' <<<"$1" 2>/dev/null)
    elif [[ -f "$USERS_FILE" ]]; then
        next=$(jq -c '.users = [(.users // [])[] | select(.managed != true)] | del(.applied_fp, .revision, .revision_fp)' "$USERS_FILE" 2>/dev/null)
    else
        return 0
    fi
    [[ -n "$next" ]] || { log_warn "psm user: the user store could not be read after the restore"; return 1; }
    mkdir -p "$(dirname "$USERS_FILE")"
    u=$(mktemp "$USERS_FILE.XXXXXX") || return 1
    if printf '%s\n' "$next" >"$u" && chmod 600 "$u" && mv -f "$u" "$USERS_FILE"; then return 0; fi
    rm -f "$u"; return 1
}

# The relay rules after a restore. roomkey runs no relays: the panel withdraws
# every rule, and an archive's rules are ones it already withdrew. `doctor --fix`
# starts an engine for each rule in this store, so the archive's must not land
# here: the rules that were here stay as they were, and with none here the store
# is left empty.
RELAY_STORE_FILE="$CFG_DIR/realm/rules.json"
_restore_relay_store() {   # <the store before the restore, or "">
    local next="${1:-[]}" u
    [[ -n "$1" || -e "$RELAY_STORE_FILE" ]] || return 0
    mkdir -p "$(dirname "$RELAY_STORE_FILE")"
    u=$(mktemp "$RELAY_STORE_FILE.XXXXXX") || return 1
    if printf '%s\n' "$next" >"$u" && chmod 600 "$u" && mv -f "$u" "$RELAY_STORE_FILE"; then return 0; fi
    rm -f "$u"; log_warn "psm relay: the relay rules could not be put back after the restore"; return 1
}

# One component: copied beside the live one, then swapped in. Nothing to
# restore (not in this backup) changes nothing and returns 2.
_restore_dir() {   # <from> <live path>
    local from="$1" live="$2" next="$2.psm-restore"
    [[ -d "$from" ]] || return 2
    rm -rf "$next"
    if ! cp -a "$from" "$next" 2>/dev/null; then
        rm -rf "$next"
        log_error "$(t backup.restore_item_failed "$live")"
        return 1
    fi
    rm -rf "$live" && mv "$next" "$live" || { log_error "$(t backup.restore_item_failed "$live")"; return 1; }
}

# The services a restore stops, and afterwards starts again: those that ran
# before it, and only those (a stopped nginx stays stopped, whatever its boot
# setting). A start that fails is a failed restore. The list is kept on disk
# until they are all running again, so a restore tried again after one that
# stopped half way still starts what ran before the first try; nothing starts
# while a restore is unfinished, a reboot included: those enabled at boot are
# taken off boot meanwhile ("name" or "name:boot" per line) and put back on
# when they start again.
_RESTORE_STOPPED=""; _RESTORE_BOOT=""
RESTORE_SERVICES_FILE="$(dirname "$CFG_DIR")/.psm-restore-services"
_stop_services() {
    local svc line t
    _RESTORE_STOPPED=""; _RESTORE_BOOT=""
    if [[ -e "$RESTORE_SERVICES_FILE" || -L "$RESTORE_SERVICES_FILE" ]]; then
        if [[ -L "$RESTORE_SERVICES_FILE" || ! -f "$RESTORE_SERVICES_FILE" ]]; then
            log_error "psm restore: $RESTORE_SERVICES_FILE is not a plain file: nothing was stopped or restored"
            return 1
        fi
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            _RESTORE_STOPPED+=" ${line%%:*}"
            [[ "$line" == *:boot ]] && _RESTORE_BOOT+=" ${line%%:*}"
        done <"$RESTORE_SERVICES_FILE"
    fi
    for svc in nginx xray hysteria-server; do
        if svc_is_active "$svc" && [[ " $_RESTORE_STOPPED " != *" $svc "* ]]; then
            _RESTORE_STOPPED+=" $svc"
            svc_is_enabled "$svc" 2>/dev/null && _RESTORE_BOOT+=" $svc"
        fi
    done
    # written (whole, then renamed onto the exact name) before anything stops:
    # a restore cut short leaves it for the next. Not written, nothing stops.
    if ! t=$(mktemp "$RESTORE_SERVICES_FILE.XXXXXX" 2>/dev/null) \
        || ! for svc in $_RESTORE_STOPPED; do
                if [[ " $_RESTORE_BOOT " == *" $svc "* ]]; then echo "$svc:boot"; else echo "$svc"; fi
             done >"$t" 2>/dev/null \
        || ! mv -f "$t" "$RESTORE_SERVICES_FILE" 2>/dev/null || [[ ! -f "$RESTORE_SERVICES_FILE" ]]; then
        rm -f "${t:-}" 2>/dev/null
        log_error "psm restore: could not note which services run ($RESTORE_SERVICES_FILE; disk full?): nothing was stopped or restored"
        return 1
    fi
    # each one off boot (if it was on) and stopped, checked: a service the
    # service manager will not take off boot or stop fails the restore before
    # anything is copied, and those already changed are put back
    local bad=""
    for svc in $_RESTORE_STOPPED; do
        if [[ " $_RESTORE_BOOT " == *" $svc "* ]] && svc_is_enabled "$svc" 2>/dev/null; then
            svc_disable "$svc" >/dev/null 2>&1; svc_is_enabled "$svc" 2>/dev/null && { bad="$svc (still enabled at boot)"; break; }
        fi
        if svc_is_active "$svc"; then
            svc_stop "$svc" >/dev/null 2>&1; svc_is_active "$svc" && { bad="$svc (still running)"; break; }
        fi
    done
    if [[ -n "$bad" ]]; then
        _start_services >/dev/null 2>&1 || true
        log_error "psm restore: the service manager did not stop $bad: nothing was restored"
        return 1
    fi
    return 0
}

_start_services() {
    local svc rc=0
    # a restore that stopped half way is not finished: nothing it stopped runs
    # again until one finishes (the cores refuse to start meanwhile too)
    if [[ -e "$RESTORE_KEEP/incomplete" ]]; then
        log_warn "psm restore: an earlier restore did not finish; ${_RESTORE_STOPPED:-nothing} stay stopped until a restore finishes"
        return 1
    fi
    for svc in $_RESTORE_STOPPED; do
        [[ " $_RESTORE_BOOT " == *" $svc "* ]] && { svc_enable "$svc" >/dev/null 2>&1 || { log_warn "psm restore: $svc could not be enabled at boot again"; rc=1; }; }
        svc_start "$svc" || { log_warn "psm restore: $svc did not start again"; rc=1; }
    done
    (( rc )) || rm -f "$RESTORE_SERVICES_FILE"
    return "$rc"
}

# ── Rotate old backups ────────────────────────────────────────────────────────
# The newest MAX_BACKUPS archives, and the newest MAX_BACKUPS quick backups
# (directories named <date>_<time>_…, which a quick backup is): a quick backup
# is uncompressed, and they used to pile up until the disk was full.
_rotate_backups() {
    local rotated=0 kind count
    for kind in archive quick; do
        if [[ "$kind" == archive ]]; then
            count=$(find "$BAK_ROOT" -maxdepth 1 -type f -name "*.tar.gz" | wc -l)
        else
            count=$(find "$BAK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*_[0-9]*_*' | wc -l)
        fi
        (( count > MAX_BACKUPS )) || continue
        if [[ "$kind" == archive ]]; then
            find "$BAK_ROOT" -maxdepth 1 -type f -name "*.tar.gz"
        else
            find "$BAK_ROOT" -maxdepth 1 -mindepth 1 -type d -name '[0-9]*_[0-9]*_*'
        fi | sort | head -n "$((count - MAX_BACKUPS))" | while IFS= read -r old; do
            rm -rf -- "$old"
        done
        rotated=1
    done
    (( rotated )) && log_info "$(t backup.rotated "$MAX_BACKUPS")"
    return 0
}

# ── Schedule auto-backup ──────────────────────────────────────────────────────
auto_backup_enable() {
    local hour; ask hour "$(t backup.ask_hour)" "3"
    # one number, or the cron line takes whatever was typed
    [[ "$hour" =~ ^[0-9]{1,2}$ ]] && (( 10#$hour <= 23 )) || { log_error "$(t backup.bad_hour)"; return 1; }
    hour=$((10#$hour))
    ensure_cron || true   # RHEL 系最小安装没有 cronie，/etc/cron.d 会被无声忽略
    cat > /etc/cron.d/psm-backup <<EOF
0 ${hour} * * * root $PSM_ROOT/manager.sh --backup-full >> $LOG_DIR/backup.log 2>&1
EOF
    log_ok "$(t backup.auto_enabled "$hour")"
}

auto_backup_disable() {
    rm -f /etc/cron.d/psm-backup
    log_ok "$(t backup.auto_disabled)"
}

# ── Dependency check ─────────────────────────────────────────────────────────
_backup_check_deps() {
    ensure_pkg_deps tar
}

# ── Menu ──────────────────────────────────────────────────────────────────────
backup_menu() {
    _backup_check_deps
    while true; do
        show_menu "$(t backup.menu.title)" \
            "$(t backup.menu.full)" \
            "$(t backup.menu.selective)" \
            "$(t backup.menu.restore)" \
            "$(t backup.menu.list)" \
            "$(t backup.menu.auto_enable)" \
            "$(t backup.menu.auto_disable)" \
            "$(t migrate.menu.export)"

        case "$MENU_CHOICE" in
            1) do_full_backup ;;
            2) do_selective_backup ;;
            3) do_restore ;;
            4) list_backups ;;
            5) auto_backup_enable ;;
            6) auto_backup_disable ;;
            7) source "$LIB_DIR/migrate.sh"
               # the bundle holds every key of this server: encrypted unless asked not to
               if ask_yn "$(t migrate.ask_encrypt)" Y; then psm_migrate_export || true; else psm_migrate_export --no-encrypt || true; fi ;;
            0) return ;;
        esac
        press_enter
    done
}
