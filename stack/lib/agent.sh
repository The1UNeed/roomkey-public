#!/usr/bin/env bash
# agent.sh — psm agent: connect this server to a PSM panel (jinqians/psm-panel)
#
#   psm agent join --panel URL --token TOKEN   download psm-agent, join, run it as a service
#   psm agent status [--json]                  installed, joined, running
#   psm agent upgrade                          update PSM, then psm-agent itself
#   psm agent remove --yes                     stop it and forget the panel
#
# psm-agent (agent/ in this repository) opens no port: it connects out to the
# panel over HTTPS, takes tasks and runs them as psm commands. The binary comes
# from this repository's GitHub release agent-v$PSM_AGENT_VERSION and is checked
# against that release's SHA256SUMS. The panel's install command
# (bootstrap.sh --panel URL --join TOKEN) ends with `psm agent join`.

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PSM_AGENT_VERSION="0.15.0"
PSM_AGENT_BIN="/usr/local/bin/psm-agent"
PSM_AGENT_CFG="/etc/psm/agent.json"
PSM_AGENT_SERVICE="psm-agent"
PSM_AGENT_UNIT="/etc/systemd/system/psm-agent.service"
# The release of the repository PSM itself was cloned from: this psm-agent
# comes with this PSM. A clone whose origin is not a GitHub repository has no
# release to download from: nothing is guessed (set PSM_AGENT_BASE_URL). Tests
# point this at a local copy of the release.
_agent_release_base() {
    local origin
    origin=$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." remote get-url origin 2>/dev/null || true)
    if [[ "$origin" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
        printf 'https://github.com/%s/%s/releases/download/agent-v%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}" "$PSM_AGENT_VERSION"
    fi
}
PSM_AGENT_BASE_URL="${PSM_AGENT_BASE_URL:-$(_agent_release_base)}"
# (installed from the panel: psm-agent comes from the panel's bundle too)

_agent_err() { printf 'psm agent: %s\n' "$*" >&2; }

_agent_usage() {
    cat <<'EOF'
Usage:
  psm agent join --panel URL --token TOKEN
  psm agent status [--json]
  psm agent upgrade
  psm agent remove --yes
EOF
}

_agent_asset() {
    case "$(get_arch)" in
        amd64) echo psm-agent-linux-amd64 ;;
        arm64) echo psm-agent-linux-arm64 ;;
        arm32) echo psm-agent-linux-armv7 ;;
        *) return 1 ;;
    esac
}

# Downloads the binary for this machine; installs it only if its sha256 matches.
_agent_download() {
    local asset tmp want got
    asset=$(_agent_asset) || { _agent_err "unsupported architecture: $(uname -m)"; return 1; }
    tmp=$(mktemp -d)
    if psm_from_panel && [[ -z "${PSM_AGENT_BASE_URL_FORCED:-}" ]]; then
        if ! psm_panel_get "$asset" "$tmp/$asset" || ! psm_panel_get SHA256SUMS "$tmp/SHA256SUMS"; then
            rm -rf "$tmp"
            _agent_err "download from the panel failed: $asset"
            return 1
        fi
    else
        [[ -n "$PSM_AGENT_BASE_URL" ]] || { rm -rf "$tmp"; _agent_err "PSM was not cloned from a GitHub repository, so there is no release to download psm-agent from; set PSM_AGENT_BASE_URL"; return 1; }
        if ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/$asset" "$PSM_AGENT_BASE_URL/$asset" \
            || ! curl "${PSM_DL[@]}" -fsSL -o "$tmp/SHA256SUMS" "$PSM_AGENT_BASE_URL/SHA256SUMS"; then
            rm -rf "$tmp"
            _agent_err "download failed: $PSM_AGENT_BASE_URL/$asset"
            return 1
        fi
    fi
    want=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
    got=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
    if [[ -z "$want" || "$want" != "$got" ]]; then
        rm -rf "$tmp"
        _agent_err "checksum mismatch for $asset: not installed"
        return 1
    fi
    svc_stop "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    install -m 755 "$tmp/$asset" "$PSM_AGENT_BIN"
    rm -rf "$tmp"
}

# psm guard: the cores this server already runs come under roomkey's start
# check (an upstream install's cores started before it existed). Only a core
# verified stopped (10) lets the join/upgrade go on, with a warning; anything
# else — a core still running or startable unchecked, or a guard that did not
# finish — stops it.
_agent_guard() {   # [join]: joining also needs every proxy listener to be one of PSM's nodes
    local rc=0
    PSM_GUARD_JOIN="${1:+1}" bash "$(dirname "${BASH_SOURCE[0]}")/../manager.sh" guard >&2 || rc=$?
    case "$rc" in
        0) return 0 ;;
        10) _agent_err "psm guard: a core failed roomkey's start check and was stopped (see above); fix its nodes in the panel"; return 0 ;;
        *) _agent_err "psm guard: a core could not be shown to be under roomkey's start check (see above); stop it by hand, then run this again"; return 1 ;;
    esac
}

_agent_write_service() {
    if _uses_systemd; then
        cat > "$PSM_AGENT_UNIT" <<EOF
[Unit]
Description=PSM agent (connects this server to its PSM panel; opens no port)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${PSM_AGENT_BIN} run -config ${PSM_AGENT_CFG}
Restart=always
RestartSec=5
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    else
        psm_write_openrc_service "$PSM_AGENT_SERVICE" "PSM agent" "$PSM_AGENT_BIN" "run -config $PSM_AGENT_CFG"
    fi
}

_agent_join() {
    # the token may come in the environment (bootstrap passes it that way): a
    # command line is there for every local user to read in ps
    local panel="" token="${PSM_AGENT_TOKEN:-}" allow_http="${PSM_AGENT_ALLOW_HTTP:-}" have i
    while (( $# )); do
        case "$1" in
            --panel) panel="${2:-}"; shift 2 ;;
            --token|--join) token="${2:-}"; shift 2 ;;
            --allow-http) allow_http=1; shift ;;
            *) _agent_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ -n "$panel" && -n "$token" ]] || { _agent_usage >&2; return 2; }
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    _psm_detect_init
    [[ "$_PSM_INIT" != none ]] || { _agent_err 'psm-agent runs as a service: systemd or OpenRC is needed'; return 1; }

    # the cores this server already runs come under roomkey's start check,
    # and its relays come down, before anything else (an upstream install's
    # cores started before it existed): a server that can't be made safe does
    # not join, its token stays unused, and nothing of psm-agent is replaced
    _agent_guard join || return 1
    have=$("$PSM_AGENT_BIN" version 2>/dev/null || true)
    if [[ "$have" != "$PSM_AGENT_VERSION" ]]; then
        log_step "psm-agent ${PSM_AGENT_VERSION}"
        # (installed from the panel: the join token authenticates this download)
        PSM_PANEL_URL="$panel" PSM_AGENT_TOKEN="$token" _agent_download || return 1
    fi
    local -a args=(join -panel "$panel" -config "$PSM_AGENT_CFG")
    [[ -z "$allow_http" ]] || args+=(-allow-http)
    if ! PSM_AGENT_TOKEN="$token" "$PSM_AGENT_BIN" "${args[@]}"; then
        _agent_err 'the panel did not accept the join token (used already, older than 24 h, or mistyped?): make a new install command in the panel'
        return 1
    fi
    _agent_write_service || return 1
    svc_enable "$PSM_AGENT_SERVICE" || true
    svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    for i in $(seq 1 10); do
        svc_is_active "$PSM_AGENT_SERVICE" && break
        sleep 1
    done
    if ! svc_is_active "$PSM_AGENT_SERVICE"; then
        _agent_err 'psm-agent did not start'
        svc_log_tail "$PSM_AGENT_SERVICE" 15 >&2
        return 1
    fi
    log_ok "Connected to ${panel}: psm-agent is running (it opens no port) and the panel shows this server online."
}

# Updates PSM, then psm-agent itself. The panel's 升级 agent button makes
# psm-agent run this detached (restarting the service kills its own cgroup, so
# an upgrade started inside it would not survive its first step).
#
# PSM is updated first because the release to install — PSM_AGENT_VERSION — is
# named in this very file: a shell that sourced the old copy would faithfully
# reinstall the old agent. Hence the re-exec after the pull, so that the
# download below reads the new value.
_agent_upgrade() {
    local pull=1 have
    while (( $# )); do
        case "$1" in
            --yes) shift ;;              # accepted for symmetry: nothing is destroyed
            --no-pull) pull=0; shift ;;  # set by the re-exec below
            *) _agent_err "unknown option: $1"; return 2 ;;
        esac
    done
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    [[ -f "$PSM_AGENT_CFG" ]] || { _agent_err 'this server has not joined a panel: nothing to upgrade'; return 1; }
    _psm_detect_init
    [[ "$_PSM_INIT" != none ]] || { _agent_err 'psm-agent runs as a service: systemd or OpenRC is needed'; return 1; }

    if (( pull )); then
        # shellcheck source=/dev/null
        source "$PSM_ROOT/update.sh"
        psm_update_scripts || _agent_err 'PSM could not be updated; keeping the version already checked out'
        exec bash "$PSM_ROOT/manager.sh" agent upgrade --no-pull
    fi

    # every upgrade, whether or not psm-agent itself changes
    _agent_guard || return 1
    have=$("$PSM_AGENT_BIN" version 2>/dev/null || true)
    if [[ "$have" == "$PSM_AGENT_VERSION" ]]; then
        log_ok "psm-agent is already ${PSM_AGENT_VERSION}."
        svc_is_active "$PSM_AGENT_SERVICE" || svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
        return 0
    fi
    log_step "psm-agent ${have:-not installed} → ${PSM_AGENT_VERSION}"
    _agent_download || return 1       # stops the service, checks sha256, installs
    _agent_write_service || return 1  # the unit itself may have changed between versions
    svc_enable "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    svc_restart "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
        svc_is_active "$PSM_AGENT_SERVICE" && break
        sleep 1
    done
    if ! svc_is_active "$PSM_AGENT_SERVICE"; then
        _agent_err 'psm-agent did not start after the upgrade'
        svc_log_tail "$PSM_AGENT_SERVICE" 15 >&2
        return 1
    fi
    log_ok "psm-agent ${PSM_AGENT_VERSION} is running; the panel shows the new version at the next sync."
}

_agent_status_json() {
    local installed=false joined=false active=false version="" panel=""
    if [[ -x "$PSM_AGENT_BIN" ]]; then installed=true; version=$("$PSM_AGENT_BIN" version 2>/dev/null || true); fi
    if [[ -f "$PSM_AGENT_CFG" ]]; then joined=true; panel=$(jq -r '.panel // ""' "$PSM_AGENT_CFG" 2>/dev/null || true); fi
    svc_is_active "$PSM_AGENT_SERVICE" 2>/dev/null && active=true
    jq -nc --argjson i "$installed" --argjson j "$joined" --argjson a "$active" --arg v "$version" --arg p "$panel" \
        '{installed: $i, version: $v, joined: $j, panel: $p, active: $a}'
}

_agent_remove() {
    [[ "${1:-}" == --yes ]] || { _agent_err 'remove needs --yes'; return 2; }
    [[ $EUID -eq 0 ]] || { _agent_err 'run as root'; return 1; }
    svc_stop "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    svc_disable "$PSM_AGENT_SERVICE" >/dev/null 2>&1 || true
    if _uses_systemd; then
        rm -f "$PSM_AGENT_UNIT"
        systemctl daemon-reload || true
    else
        psm_remove_openrc_service "$PSM_AGENT_SERVICE"
    fi
    # its state beside the config goes too: a later enrollment starts clean
    local d; d=$(dirname "$PSM_AGENT_CFG")
    rm -f "$PSM_AGENT_BIN" "$PSM_AGENT_CFG" "$d/agent-tasks.json" "$d/agent-events.json" "$d/agent-codes.json"
    log_ok 'psm-agent removed; the nodes on this server are unchanged.'
}

psm_agent_cli() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        join) _agent_join "$@" ;;
        status)
            if [[ "${1:-}" == --json ]]; then _agent_status_json
            else _agent_status_json | jq -r 'to_entries[] | "\(.key): \(.value)"'; fi ;;
        upgrade|update) _agent_upgrade "$@" ;;
        remove|uninstall) _agent_remove "$@" ;;
        help|--help|-h) _agent_usage ;;
        *) _agent_usage >&2; return 2 ;;
    esac
}
