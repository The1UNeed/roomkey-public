#!/usr/bin/env bash
# common.sh — shared utilities, constants, and helpers

# ── 加载守卫 ──────────────────────────────────────────────────────────────────
# 本文件会被大量模块重复 source（每个模块头部各 source 一次，manager.sh 也先
# source）。若无守卫，每次重复 source 都会把 CFG_DIR / PSM_STATE 等路径变量重置
# 回默认值——上层（测试或自定义流程）一旦先覆盖过这些路径，随后任意模块再 source
# 本文件就会把覆盖悄悄冲掉。首次加载后置位，后续 source 直接返回，保证变量与函数
# 只初始化一次。（return 仅在被 source 时执行；首次加载因守卫未置位不会触发。）
[[ -n "${_PSM_COMMON_LOADED:-}" ]] && return 0
_PSM_COMMON_LOADED=1

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Paths ─────────────────────────────────────────────────────────────────────
PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$PSM_ROOT/lib"
TPL_DIR="$PSM_ROOT/templates"
CFG_DIR="$PSM_ROOT/config"
BAK_DIR="$PSM_ROOT/backup"
LOG_DIR="$PSM_ROOT/logs"

NGINX_STREAM_DIR="/etc/nginx/stream.d"
NGINX_HTTP_DIR="/etc/nginx/conf.d"
NGINX_SSL_DIR="/etc/nginx/ssl"
XRAY_CFG_DIR="/usr/local/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
SINGBOX_CFG_DIR="/etc/sing-box"
SINGBOX_BIN="/usr/local/bin/sing-box"
MIHOMO_CFG_DIR="/etc/mihomo"
MIHOMO_BIN="/usr/local/bin/mihomo"
HYSTERIA_CFG="/etc/hysteria/config.yaml"
HYSTERIA_BIN="/usr/local/bin/hysteria"
ACME_HOME="/root/.acme.sh"

PSM_STATE="$CFG_DIR/psm.state"   # key=value runtime state

# /usr/local/bin first: PSM's cores live there, and so does the jq it installs
# where the distro's is too old (ensure_modern_jq). cron and some systemd
# units run PSM with a PATH that lacks it or puts it last.
PATH="/usr/local/bin:${PATH}"

# ── Logging ───────────────────────────────────────────────────────────────────
# 全部写 stderr（不只是 log_error）。日志是给人看的诊断信息，不是函数的返回值：
# 本仓库有大量「stdout 返回一个值、中途 log_step 报进度」的函数，例如三个核心的
# 版本解析 `tag=$(_xray_resolve_tag ...)`。日志一旦落在 stdout，就会被命令替换
# 连同返回值一起吃进变量，拼出
#   https://github.com/.../download/[步骤] 正在获取最新版本...\nv26.3.27/Xray-linux-64.zip
# 这种 URL，安装直接失败。改到 stderr 后这一整类 bug 从根上不可能再发生；交互体验
# 不变（终端照样显示），`--json` 之类的机器可读输出反而更干净。
log_info()    { echo -e "${GREEN}[$(t log.info)]${NC}  $*" >&2; }
log_warn()    { echo -e "${YELLOW}[$(t log.warn)]${NC}  $*" >&2; }
log_error()   { echo -e "${RED}[$(t log.error)]${NC}  $*" >&2; }
log_step()    { echo -e "${CYAN}[$(t log.step)]${NC}  $*" >&2; }
log_ok()      { echo -e "${GREEN}[$(t log.ok)]${NC}  $*" >&2; }

die() { log_error "$*"; exit 1; }

# ── Privilege ─────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "$(t common.err.need_root)"
}

# ── OS detection ──────────────────────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID}"
    elif [[ -f /etc/debian_version ]]; then
        OS_ID="debian"
    elif [[ -f /etc/redhat-release ]]; then
        OS_ID="centos"
    else
        die "$(t common.err.unsupported_os)"
    fi

    case "$OS_ID" in
        alpine)
            PKG_MGR="apk" ;;
        ubuntu|debian|raspbian)
            PKG_MGR="apt-get" ;;
        centos|rhel|fedora|rocky|almalinux|ol|amzn)
            PKG_MGR="yum" ;;
        *)
            # fallback: check ID_LIKE (e.g. "rhel centos fedora")
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) PKG_MGR="apt-get" ;;
                *rhel*|*centos*|*fedora*) PKG_MGR="yum" ;;
                *alpine*) PKG_MGR="apk" ;;
            *) die "$(t common.err.unsupported_distro "$OS_ID")" ;;
            esac
            ;;
    esac
}

# On the RHEL family prefer dnf when present (RHEL8+/Rocky/Alma/OL8+/AL2023/
# Fedora); fall back to yum for anything older. PKG_MGR stays "yum" as the
# family marker — existing `[[ "$PKG_MGR" == "yum" ]]` checks keep working.
_rhel_pkg_cmd() { command -v dnf &>/dev/null && echo dnf || echo yum; }

pkg_install() {
    detect_os
    case "$PKG_MGR" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
        yum)     "$(_rhel_pkg_cmd)" install -y "$@" ;;
        apk)     apk add --no-cache "$@" ;;
    esac
}

pkg_update() {
    detect_os
    case "$PKG_MGR" in
        apt-get) apt-get update -qq ;;
        yum)     "$(_rhel_pkg_cmd)" makecache -q 2>/dev/null || "$(_rhel_pkg_cmd)" makecache ;;
        # `apk add --no-cache` refreshes its own index, so no separate cache
        # update (and no stale index left in an Alpine image) is needed.
        apk)     : ;;
    esac
}

# ── EPEL (RHEL family only) ───────────────────────────────────────────────────
# Several packages PSM needs (qrencode, fail2ban, wireguard-tools, …) live in
# EPEL on the RHEL family, and HOW to enable EPEL differs per distro:
#   CentOS/Rocky/Alma : dnf install epel-release            (in base repos)
#   Oracle Linux      : dnf install oracle-epel-release-elN (Oracle's mirror)
#   RHEL proper       : the epel-release RPM from Fedora    (needs the URL)
#   Amazon Linux 2023 : EPEL is NOT supported at all → warn and fail
#   Fedora / Debian 系 : not applicable → succeed as a no-op
# Returns 0 when EPEL is (already) enabled or not needed, 1 otherwise.
ensure_epel() {
    detect_os
    [[ "$PKG_MGR" == "yum" ]] || return 0          # Debian family: no EPEL concept
    case "$OS_ID" in fedora) return 0 ;; esac       # Fedora: everything is in base

    # Fast path: already enabled? Match EPEL anywhere in the enabled repo list —
    # the repo id differs by distro (`epel` on CentOS/Rocky/Alma, `ol9_…_EPEL`
    # on Oracle), so an anchored/exact match would miss Oracle's.
    rpm -q epel-release &>/dev/null && return 0
    "$(_rhel_pkg_cmd)" repolist enabled 2>/dev/null | grep -qi 'epel' && return 0

    local pkg_cmd rhel_ver
    pkg_cmd=$(_rhel_pkg_cmd)
    rhel_ver=$(rpm -E %rhel 2>/dev/null)
    [[ "$rhel_ver" =~ ^[0-9]+$ ]] || rhel_ver="${OS_VERSION:-}"; rhel_ver="${rhel_ver%%.*}"
    [[ "$rhel_ver" =~ ^[0-9]+$ ]] || { log_warn "$(t common.epel.amzn_unsupported)"; return 1; }

    log_step "$(t common.epel.enabling)"
    case "$OS_ID" in
        amzn)
            if command -v amazon-linux-extras &>/dev/null; then
                amazon-linux-extras install -y epel 2>/dev/null && return 0   # AL2
            fi
            log_warn "$(t common.epel.amzn_unsupported)"
            return 1
            ;;
        ol)
            "$pkg_cmd" install -y "oracle-epel-release-el${rhel_ver}" 2>/dev/null && return 0
            # Older OL or naming miss — fall through to the Fedora RPM
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
        rhel)
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
        *)  # centos / rocky / almalinux / stream
            "$pkg_cmd" install -y epel-release 2>/dev/null && return 0
            "$pkg_cmd" install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_ver}.noarch.rpm" \
                2>/dev/null && return 0
            ;;
    esac
    log_warn "$(t common.epel.failed)"
    return 1
}

# ── jq 1.7 or newer ──────────────────────────────────────────────────────────
# jq 1.6 (the EL8 / EL9 package) exits 0 for `jq -e` on empty input, where 1.7
# exits 4, and PSM branches on `jq -e` in many places whose input can be empty
# (an outbound that is not there, an empty store). On such a host PSM installs
# the official static jq, checked against the release's sha256sum.txt, into
# /usr/local/bin, which is first on PATH for everything PSM runs.
PSM_JQ_VERSION="1.8.1"

_jq_is_modern() {   # [jq binary]
    local v; v=$("${1:-jq}" --version 2>/dev/null) || return 1
    [[ "${v#jq-}" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    (( BASH_REMATCH[1] > 1 || BASH_REMATCH[2] >= 7 ))
}

ensure_modern_jq() {
    _jq_is_modern && return 0
    local arch dir="/usr/local/bin" base sums
    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; armv7l|armv7) arch=armhf ;;
        *) log_warn "$(t common.jq.old "$(jq --version 2>/dev/null)")"; return 0 ;;
    esac
    base="https://github.com/jqlang/jq/releases/download/jq-${PSM_JQ_VERSION}"
    mkdir -p "$dir"
    if curl "${PSM_DL[@]}" -fsSL -o "$dir/.jq.new" "$base/jq-linux-${arch}" \
        && sums=$(curl "${PSM_DL[@]}" -fsSL "$base/sha256sum.txt") \
        && [[ "$(sha256sum "$dir/.jq.new" | awk '{print $1}')" == \
              "$(awk -v f="jq-linux-${arch}" '$2 == f {print $1}' <<<"$sums")" ]] \
        && chmod 755 "$dir/.jq.new" && _jq_is_modern "$dir/.jq.new"; then
        mv -f "$dir/.jq.new" "$dir/jq"
        hash -r
        log_ok "$(t common.jq.upgraded "$("$dir/jq" --version)")"
    else
        rm -f "$dir/.jq.new"
        log_warn "$(t common.jq.old "$(jq --version 2>/dev/null)")"
    fi
    return 0
}

# ── Downloads ────────────────────────────────────────────────────────────────
# GitHub (and the other hosts PSM downloads from) now and then answers 500 or
# times out for a moment, and one such answer used to fail a whole install.
# Every download of a core, a tool, an installer or a data file passes these:
# curl retries timeouts and HTTP 408, 429, 500, 502, 503 and 504 five times,
# backing off 1, 2, 4, 8 and 16 s (about 30 s: GitHub has answered 504 for
# longer than 15 s in CI), and truncates a partly written -o file before it
# does. No --retry-delay: a fixed delay would turn the backoff off.
# bootstrap.sh spells the same flags out: it runs before this file exists.
PSM_DL=(--retry 5 --connect-timeout 15)

# ── PSM's own version ────────────────────────────────────────────────────────
# PSM has no release numbers: its version is the date and commit of the checkout.
psm_version() {
    local v
    v=$(git -C "${PSM_ROOT:-/opt/psm}" log -1 --format='%cs %h' 2>/dev/null || true)
    # installed from the panel's bundle: the commit it was built from
    [[ -n "$v" ]] || v=$(head -1 "${PSM_ROOT:-/opt/psm}/.psm-version" 2>/dev/null || true)
    printf '%s\n' "${v:-unknown}"
}

# ── Installed from the panel (roomkey's private install) ─────────────────────
# A server installed with the panel's command has no git checkout: PSM and
# psm-agent come from the panel's bundle, checked against its SHA256SUMS. The
# one-time join token authenticates the download during the install
# (PSM_PANEL_URL and PSM_AGENT_TOKEN), this server's agent token after.
psm_from_panel() { [[ "$(cat "${PSM_ROOT:-/opt/psm}/.psm-source" 2>/dev/null)" == panel ]]; }
psm_panel_get() {   # <bundle file> <destination>
    local f="$1" dest="$2" panel="" hdr="" h rc=0
    if [[ -n "${PSM_PANEL_URL:-}" && -n "${PSM_AGENT_TOKEN:-}" ]]; then
        panel="$PSM_PANEL_URL"; hdr="X-PSM-Join: $PSM_AGENT_TOKEN"
    elif [[ -r "${PSM_AGENT_CFG:-/etc/psm/agent.json}" ]]; then
        panel=$(jq -r '.panel // empty' "${PSM_AGENT_CFG:-/etc/psm/agent.json}" 2>/dev/null)
        hdr="Authorization: Bearer $(jq -r '.token // empty' "${PSM_AGENT_CFG:-/etc/psm/agent.json}" 2>/dev/null)"
    fi
    [[ "$panel" =~ ^https?:// ]] || return 1
    # the token in a file of this run's own, not on curl's command line (ps)
    h=$(mktemp) || return 1
    chmod 600 "$h" && printf '%s\n' "$hdr" >"$h" || { rm -f "$h"; return 1; }
    curl "${PSM_DL[@]}" -fsSL -H "@$h" -o "$dest" "${panel%/}/api/agent/bundle/$f" || rc=1
    rm -f "$h"
    return "$rc"
}
# PSM's scripts again from the panel, in place: the bundle carries no state
# (config/, backup/, logs/ stay as they are). Checked before anything is copied.
psm_panel_update() {
    local root="${PSM_ROOT:-/opt/psm}" tmp want got rc=0
    tmp=$(mktemp -d) || return 1
    if psm_panel_get SHA256SUMS "$tmp/SHA256SUMS" && psm_panel_get stack.tgz "$tmp/stack.tgz"; then
        want=$(awk '$2 == "stack.tgz" || $2 == "*stack.tgz" { print $1 }' "$tmp/SHA256SUMS")
        got=$(sha256sum "$tmp/stack.tgz" | awk '{ print $1 }')
        if [[ -n "$want" && "$want" == "$got" ]] && mkdir "$tmp/x" && tar -xzf "$tmp/stack.tgz" -C "$tmp/x" 2>/dev/null \
            && [[ -f "$tmp/x/manager.sh" ]]; then
            cp -a "$tmp/x/." "$root/" && printf 'panel\n' >"$root/.psm-source" || rc=1
            find "$root" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
        else
            rc=1
        fi
    else
        rc=1
    fi
    rm -rf "$tmp"
    return "$rc"
}

# ── Latest release of a GitHub project ───────────────────────────────────────
# The /releases/latest redirect comes first: api.github.com allows 60 requests
# an hour per IP without a token, which a few installs behind one address use
# up, and every core install then fell back to an old pinned version (sing-box
# 1.13 cannot run Snell or gecko nodes). The redirect is not rate limited; it
# is followed to the end (apernet/hysteria now redirects to HyNetworks/hysteria)
# and URL-encoded tags such as app%2Fv2.6.1 are decoded. The API is the second
# try; callers keep their pinned fallback for when both fail.
gh_latest_tag() {   # <owner/repo>
    local url tag=""
    url=$(curl "${PSM_DL[@]}" -fsSIL --max-time 15 -o /dev/null -w '%{url_effective}' \
        "https://github.com/$1/releases/latest" 2>/dev/null || true)
    if [[ "$url" == */releases/tag/* ]]; then
        tag=${url##*/releases/tag/}; tag=${tag//%2F//}; tag=${tag//%2f//}
    fi
    [[ -n "$tag" ]] || tag=$(curl "${PSM_DL[@]}" -fsSL --max-time 15 "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
    printf '%s' "$tag"
}

# ── Slim checkout of PSM itself ──────────────────────────────────────────────
# A server needs the scripts, not the READMEs, screenshots, CI files and tests.
# Sparse checkout keeps those out of $PSM_ROOT; the partial-clone filter keeps
# later pulls from downloading their contents at all. An older full clone is
# converted in place. Idempotent. bootstrap.sh has a copy (_psm_slim) for the
# first clone, before this file exists: keep the two in step
# (tests/integration/slim.sh compares them).
psm_repo_slim() {   # [repo dir]
    local d="${1:-$PSM_ROOT}" want
    [[ -d "$d/.git" ]] || return 0
    want=$(printf '%s\n' '/*' '!/README*.md' '!/.github/' '!/tests/')
    if [[ "$(git -C "$d" config --get core.sparseCheckout || true)" != true \
          || "$(cat "$d/.git/info/sparse-checkout" 2>/dev/null)" != "$want" ]]; then
        mkdir -p "$d/.git/info"
        printf '%s\n' "$want" > "$d/.git/info/sparse-checkout"
        git -C "$d" config core.sparseCheckout true
        git -C "$d" read-tree -mu HEAD || return 1
    fi
    if [[ -z "$(git -C "$d" config --get remote.origin.promisor || true)" ]]; then
        git -C "$d" config remote.origin.promisor true
        git -C "$d" config remote.origin.partialclonefilter blob:none
        # git before 2.24 knows the promisor remote only from this extension,
        # and takes the filter for later fetches from core.partialCloneFilter
        git -C "$d" config core.repositoryformatversion 1
        git -C "$d" config extensions.partialClone origin
        git -C "$d" config core.partialCloneFilter blob:none
    fi
}

# ── Tables ───────────────────────────────────────────────────────────────────
# Aligns tab-separated rows into columns. Not `column -t`: a minimal Debian
# has no bsdextrautils, and lists piped through it came out empty there.
psm_table() {
    awk -F'\t' '{ for (i = 1; i <= NF; i++) { c[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) }
                   if (NF > nf) nf = NF }
                 END { for (r = 1; r <= NR; r++) { line = ""
                           for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s", c[r, i]) (i < nf ? "  " : "")
                           print line } }'
}

# ── Cron daemon (for /etc/cron.d drop-ins) ────────────────────────────────────
# Debian minimal / RHEL-family minimal installs may have no cron daemon at all
# (RHEL ships it as "cronie"), in which case /etc/cron.d/psm-* files are never
# executed. Install + enable the distro's daemon before relying on them.
ensure_cron() {
    detect_os
    if [[ "$PKG_MGR" == "apk" ]]; then
        # Alpine's default busybox crond never reads /etc/cron.d. cronie does,
        # and it also runs /etc/crontabs/root (acme.sh's renewal entry), so it
        # replaces busybox crond outright instead of running next to it.
        svc_is_active cronie && return 0
        log_step "$(t common.cron.installing)"
        pkg_install cronie &>/dev/null || true
        svc_stop crond &>/dev/null || true
        svc_disable crond || true
        if _svc_enable_now cronie; then
            log_ok "$(t common.cron.enabled cronie)"
            return 0
        fi
        log_warn "$(t common.cron.failed)"
        return 1
    fi
    if command -v crontab &>/dev/null \
        && { svc_is_active cron 2>/dev/null || svc_is_active crond 2>/dev/null \
             || svc_is_active cronie 2>/dev/null; }; then
        return 0
    fi
    detect_os
    log_step "$(t common.cron.installing)"
    case "$PKG_MGR" in
        apt-get) pkg_install cron   2>/dev/null || true ;;
        yum)     pkg_install cronie 2>/dev/null || true ;;
    esac
    local svc
    for svc in cron crond cronie; do
        if _svc_enable_now "$svc"; then
            log_ok "$(t common.cron.enabled "$svc")"
            return 0
        fi
    done
    command -v crontab &>/dev/null && return 0
    log_warn "$(t common.cron.failed)"
    return 1
}

# ── Architecture ─────────────────────────────────────────────────────────────
get_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "arm32" ;;
        *)       die "$(t common.err.unsupported_arch "$(uname -m)")" ;;
    esac
}

# musl libc (Alpine). Release binaries linked against glibc cannot exec there
# ("required file not found"), so downloaders pick a -musl/static build.
is_musl() { compgen -G '/lib/ld-musl-*.so.1' >/dev/null; }

# ── Network ───────────────────────────────────────────────────────────────────
get_ipv4() {
    # the last resort is the source address of the default route: iproute2
    # prints "1.0.0.0 via GW dev IF src ADDR uid 0", so the field after "src"
    curl -s4 --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null \
        || ip -4 route get 1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

get_ipv6() {
    curl -s6 --max-time 5 https://api6.ipify.org 2>/dev/null
}

has_ipv6() { [[ -n "$(get_ipv6)" ]]; }

# ── Service helpers ───────────────────────────────────────────────────────────
# Two init systems are supported: systemd (Debian/Ubuntu/RHEL family) and
# OpenRC (Alpine). /run/systemd/system is systemd's own "booted with systemd"
# marker (what sd_booted() checks). The answer is cached: these helpers run in
# loops, and it cannot change while PSM is running.
_psm_detect_init() {
    [[ -n "${_PSM_INIT:-}" ]] && return 0
    if [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null; then
        _PSM_INIT=systemd
    elif command -v openrc-run &>/dev/null && command -v rc-service &>/dev/null; then
        _PSM_INIT=openrc
    else
        _PSM_INIT=none
    fi
}
_uses_systemd() { _psm_detect_init; [[ "$_PSM_INIT" == "systemd" ]]; }
_uses_openrc()  { _psm_detect_init; [[ "$_PSM_INIT" == "openrc" ]]; }

_svc_enable_now() {
    local svc="$1"
    if _uses_systemd; then
        systemctl enable --now "$svc" &>/dev/null
    elif _uses_openrc; then
        [[ -x "/etc/init.d/${svc}" ]] || return 1
        rc-update add "$svc" default &>/dev/null || true
        rc-service "$svc" start &>/dev/null
    else
        return 1
    fi
}
# Neither systemd nor OpenRC (a container started without an init): said
# once, plainly, instead of "rc-service: command not found" from every call.
_svc_no_init() {
    _uses_openrc && return 1
    [[ -n "${_PSM_NO_INIT_SAID:-}" ]] || { log_error "$(t common.err.need_init "$1")"; _PSM_NO_INIT_SAID=1; }
    return 0
}
svc_enable() {
    if _uses_systemd; then systemctl enable "$1" --quiet 2>/dev/null
    elif _svc_no_init "$1"; then return 1
    else rc-update add "$1" default &>/dev/null; fi
}
svc_disable() {
    if _uses_systemd; then systemctl disable "$1" --quiet 2>/dev/null
    elif _svc_no_init "$1"; then return 1
    else rc-update del "$1" default &>/dev/null; fi
}
svc_start()   { if _uses_systemd; then systemctl start "$1"; elif _svc_no_init "$1"; then return 1; else rc-service "$1" start; fi; }
svc_stop()    { if _uses_systemd; then systemctl stop  "$1"; elif _svc_no_init "$1"; then return 1; else rc-service "$1" stop;  fi; }
# reset-failed first: every node change restarts the core, and systemd's default
# start limit (5 starts / 10 s) otherwise locks the unit into "start-limit-hit"
# after a handful of quick changes (measured with `psm node add` in a loop) —
# every later change then fails although the config is valid.
svc_restart() {
    if _uses_systemd; then systemctl reset-failed "$1" 2>/dev/null; systemctl restart "$1"
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" restart; fi
}
svc_reload() {
    if _uses_systemd; then systemctl reload "$1" 2>/dev/null || systemctl restart "$1"
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" reload 2>/dev/null || rc-service "$1" restart; fi
}
svc_status() {
    if _uses_systemd; then systemctl status "$1" --no-pager -l
    elif _svc_no_init "$1"; then return 1
    else rc-service "$1" status; fi
}
svc_is_active() {
    if _uses_systemd; then systemctl is-active --quiet "$1"; return; fi
    rc-service "$1" status &>/dev/null || return 1
    # supervise-daemon keeps reporting "started" for as long as it is retrying a
    # child that dies on start (measured: >20s of "started" with no child). Its
    # pidfile holds the supervisor, not the service, so require a live child.
    # Distro daemons (nginx, cron …) are not supervised and pass straight through.
    local sup; sup=$(cat "/run/$1.pid" 2>/dev/null) || return 0
    [[ "$(cat "/proc/${sup}/comm" 2>/dev/null)" == supervise-daemo* ]] || return 0
    pgrep -P "$sup" >/dev/null 2>&1
}
# Enabled = starts at boot (systemd: is-enabled; OpenRC: in the default runlevel).
svc_is_enabled() {
    if _uses_systemd; then systemctl is-enabled --quiet "$1" 2>/dev/null
    else [[ -e "/etc/runlevels/default/$1" ]]; fi
}
# Exists = the init system knows the service (a unit is loaded / an init script is present).
svc_exists() {
    # (P=value: systemd 219 has no --value)
    if _uses_systemd; then systemctl show "$1" --property=LoadState 2>/dev/null | grep -qx 'LoadState=loaded'
    else [[ -x "/etc/init.d/$1" ]]; fi
}
svc_daemon_reload() {
    if _uses_systemd; then systemctl daemon-reload || true; fi
    return 0
}

# OpenRC has no journal: services written by psm_write_openrc_service send
# stdout+stderr here instead, and svc_logs / svc_log_tail read it back.
_svc_log_file() { printf '/var/log/psm/%s.log' "$1"; }

# Write an OpenRC service for a PSM-managed daemon (the OpenRC counterpart of
# the systemd units the modules write). command_args is one string because
# openrc-run word-splits it itself.
psm_write_openrc_service() {
    # [env_file]：可选，存在时整份导出给守护进程（systemd 的 EnvironmentFile=- 同义）
    # [run_as] [pre_cmd]：以非 root 用户运行（附 bind/net_admin 两项能力）；pre_cmd
    # 在 start_pre 里以 root 执行（lib/coreperm.sh 修权限）。supervise-daemon 在降权
    # 之后才打开 output_log，所以日志文件要先建好、归该用户所有。
    local name="$1" description="$2" command="$3" command_args="$4" env_file="${5:-}" env_line=""
    local run_as="${6:-}" pre_cmd="${7:-}" user_lines="command_user=\"root\"" log_line=""
    _uses_openrc || { log_error "$(t common.err.need_init "$name")"; return 1; }
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { log_error "psm_write_openrc_service: bad name: $name"; return 1; }
    local v
    for v in "$description" "$command" "$command_args" "$env_file" "$run_as"; do
        [[ "$v" != *[\"\`\$\\]* && "$v" != *$'\n'* ]] \
            || { log_error "psm_write_openrc_service: a value would break the script's quoting: $v"; return 1; }
    done
    [[ -n "$env_file" ]] && env_line="[ -f \"${env_file}\" ] && { set -a; . \"${env_file}\"; set +a; }"
    if [[ -n "$run_as" ]]; then
        user_lines="command_user=\"${run_as}:${run_as}\""$'\n'"capabilities=\"^cap_net_bind_service,^cap_net_admin\""
        log_line="checkpath -f -o ${run_as}:${run_as} -m 0640 $(_svc_log_file "$name")"
    fi
    cat > "/etc/init.d/${name}" <<EOF
#!/sbin/openrc-run
# Managed by PSM
description="${description}"
command="${command}"
command_args="${command_args}"
${user_lines}
pidfile="/run/${name}.pid"
supervisor="supervise-daemon"
supervise_daemon_args="--respawn-delay 5"
output_log="$(_svc_log_file "$name")"
error_log="$(_svc_log_file "$name")"
rc_ulimit="-n 1048576"
# Append, never replace: openrc-run puts its own helpers (checkpath, einfo, …) on PATH.
export PATH="\${PATH}:/usr/local/sbin:/usr/local/bin"
${env_line}

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 /var/log/psm
    ${log_line}
    ${pre_cmd}
}
EOF
    chmod 755 "/etc/init.d/${name}"
}

psm_remove_openrc_service() {
    local name="$1"
    _uses_openrc || return 0
    svc_stop "$name" &>/dev/null || true
    svc_disable "$name" &>/dev/null || true
    rm -f "/etc/init.d/${name}" "$(_svc_log_file "$name")"
}

svc_logs() {
    local name="$1" file
    if _uses_systemd; then
        journalctl -u "$name" -f --no-pager
        return
    fi
    file=$(_svc_log_file "$name")
    if [[ -f "$file" ]]; then
        tail -n 50 -F "$file"
    else
        log_warn "$(t common.svc.no_log "$name" "$file")"
        return 1
    fi
}

# Last <n> log lines of a service, non-following (for error reports).
svc_log_tail() {
    local name="$1" n="${2:-15}"
    if _uses_systemd; then
        journalctl -u "$name" -n "$n" --no-pager 2>/dev/null || true
    else
        tail -n "$n" "$(_svc_log_file "$name")" 2>/dev/null || true
    fi
}

# ── Periodic jobs without systemd timers ─────────────────────────────────────
# The modules keep their systemd timers as-is; on OpenRC the same manager.sh
# entry point runs from an /etc/cron.d drop-in instead (see ensure_cron).
psm_cron_set() {
    local name="$1" spec="$2" args="$3"
    # the file name is ours to pick and the job is one line: nothing that could
    # leave /etc/cron.d or start a second line
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { log_error "psm_cron_set: bad name: $name"; return 1; }
    [[ "$spec$args" != *$'\n'* && "$spec$args" != *$'\r'* ]] || { log_error "psm_cron_set: a job is one line"; return 1; }
    ensure_cron || true
    mkdir -p /etc/cron.d
    cat > "/etc/cron.d/${name}" <<EOF
# Managed by PSM
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${spec} root ${PSM_ROOT}/manager.sh ${args} >/dev/null 2>&1
EOF
    chmod 644 "/etc/cron.d/${name}"
}
psm_cron_remove() { rm -f "/etc/cron.d/$1"; }
psm_cron_active() { [[ -f "/etc/cron.d/$1" ]]; }

# ── Firewall persistence ─────────────────────────────────────────────────────
# Save the live iptables rules so they survive a reboot:
#   Alpine      : `rc-service iptables save` → /etc/iptables/rules-save, which the
#                 iptables service loads at boot (so that service is enabled too)
#   RHEL family : /etc/sysconfig/iptables (the dir always exists there)
#   Debian      : /etc/iptables/rules.v4 (what iptables-persistent restores)
psm_iptables_persist() {
    if _uses_openrc && [[ -x /etc/init.d/iptables ]]; then
        local s
        for s in iptables ip6tables; do
            [[ -x "/etc/init.d/$s" ]] || continue
            rc-service "$s" save &>/dev/null || true
            svc_enable "$s" || true
        done
        return 0
    fi
    [[ -d /etc/sysconfig ]] || mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save  > /etc/sysconfig/iptables 2>/dev/null \
        || iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6  2>/dev/null || true
}

# ── Prompts ───────────────────────────────────────────────────────────────────
ask() {
    # ask <var_name> <prompt> [default]
    local var="$1" prompt="$2" default="${3:-}"
    local hint="" _ask_val=""
    [[ -n "$default" ]] && hint=" [${default}]"
    read -rp "$(echo -e "${CYAN}${prompt}${hint}: ${NC}")" _ask_val || true
    [[ -z "$_ask_val" && -n "$default" ]] && _ask_val="$default"
    printf -v "$var" '%s' "$_ask_val"
}

# ask_hy2_obfs_pass <var_name> <prompt>
# Hysteria2 混淆密码：默认随机 16 位；Xray 的 salamander 要求 ≥4 字节，
# 太短会让整个 Xray 起不来，三个核心统一按这个下限重问。
ask_hy2_obfs_pass() {
    local _hy2_var="$1" _hy2_prompt="$2" _hy2_pw
    while :; do
        ask _hy2_pw "$_hy2_prompt" "$(rand_str 16)"
        (( ${#_hy2_pw} >= 4 )) && break
        log_warn "$(t common.hy2.obfs_too_short)"
    done
    printf -v "$_hy2_var" '%s' "$_hy2_pw"
}

# ask_hy2_bbr_profile <var_name>: how hard a Hysteria2 server's BBR sends —
# empty (the core's default, standard), conservative or aggressive. New in all
# three cores this year (sing-box 1.14, mihomo 1.19.24, Xray v26.4.13).
ask_hy2_bbr_profile() {
    local _bbr_var="$1" _bbr_c
    echo -e "  $(t common.hy2.bbr_title)"
    echo -e "    $(t common.hy2.bbr1)"
    echo -e "    $(t common.hy2.bbr2)"
    echo -e "    $(t common.hy2.bbr3)"
    read -rp "$(echo -e "${CYAN}$(t common.hy2.ask_bbr)${NC}")" _bbr_c
    case "$_bbr_c" in
        2) printf -v "$_bbr_var" '%s' conservative ;;
        3) printf -v "$_bbr_var" '%s' aggressive ;;
        *) printf -v "$_bbr_var" '%s' '' ;;
    esac
}

# ask_hy2_pmtud <var_name>: switch off QUIC path MTU discovery (3x-ui's "Disable
# Path MTU Discovery", #7). The server stops probing for larger packets and keeps
# to small ones, which helps on paths that drop large packets. "true" or empty.
# sing-box 1.14+, Xray (every release with Hysteria2), the official server;
# mihomo has no such option.
ask_hy2_pmtud() {
    local _pm_var="$1"
    echo -e "  $(t common.hy2.pmtud_title)"
    if ask_yn "$(t common.hy2.ask_pmtud)" N; then
        printf -v "$_pm_var" '%s' true
    else
        printf -v "$_pm_var" '%s' ''
    fi
}

ask_yn() {
    # ask_yn <prompt> [Y|N]  → returns 0=yes 1=no
    local prompt="$1" default="${2:-Y}" _ask_ans=""
    local hint; [[ "$default" == "Y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$(echo -e "${CYAN}${prompt} ${hint}: ${NC}")" _ask_ans || true
    [[ -z "$_ask_ans" ]] && _ask_ans="$default"
    case "$_ask_ans" in
        [Yy]) return 0 ;;
        *)    return 1 ;;
    esac
}

press_enter() { read -rp "$(echo -e "${YELLOW}$(t common.press_enter)${NC}")"; }

# ── Menu builder ──────────────────────────────────────────────────────────────
show_menu() {
    # show_menu <title> <opt1> <opt2> ...
    local title="$1"; shift
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  $title${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    local i=1
    for opt in "$@"; do
        printf "  ${CYAN}%2d.${NC} %s\n" "$i" "$opt"
        ((i++))
    done
    echo -e "  ${CYAN} 0.${NC} $(t common.back_exit)"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}"
    read -rp "$(echo -e "${CYAN}$(t common.select)${NC}")" MENU_CHOICE
}

# ── Template rendering ────────────────────────────────────────────────────────
render_tpl() {
    # render_tpl <template_file> <output_file> <VAR=val> ...
    local tpl="$1" out="$2"; shift 2
    [[ -f "$tpl" ]] || die "$(t common.err.tpl_missing "$tpl")"
    local content; content="$(cat "$tpl")"
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        content="${content//\{\{${k}\}\}/${v}}"
    done
    echo "$content" > "$out"
}

# ── State store ───────────────────────────────────────────────────────────────
state_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "$PSM_STATE")"
    # psm.state holds credentials (passwords, etc.); keep it and its dir root-only
    # instead of relying on the default umask (which leaves them world-readable).
    chmod 700 "$CFG_DIR" 2>/dev/null || true
    local tmp
    tmp=$(umask 077; mktemp "$PSM_STATE.XXXXXX") || return 1
    { awk -v k="$key=" 'index($0, k) != 1' "$PSM_STATE" 2>/dev/null || true
      printf '%s=%s\n' "$key" "$val"; } > "$tmp" && mv -f "$tmp" "$PSM_STATE" || { rm -f "$tmp"; return 1; }
    chmod 600 "$PSM_STATE" 2>/dev/null || true
}

# 读一个「兜底出口」状态值，未设置时回落到默认。不能直接写
# `$(state_get k || echo d)`——state_get 内部有 `|| true`，未设置时是
# 「退出码 0 + 空串」，那样写会让调用方拿到空字符串而不是默认值。
_er_route_final() {
    local v; v=$(state_get "$1")
    [[ -n "$v" ]] && printf '%s' "$v" || printf '%s' "$2"
}

state_get() {
    local key="$1"
    # the key as text, not as a pattern; nothing (and 0) when it is not set
    awk -v k="$key=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$PSM_STATE" 2>/dev/null || true
}

# ── Random helpers ────────────────────────────────────────────────────────────
rand_port() {
    # rand_port <min> <max>
    shuf -i "${1:-10000}-${2:-60000}" -n 1
}

# 把任意字符串编码成 URL 组件（RFC 3986）。分享链接把密码放在 userinfo 里，
# 用户自定义的密码可能含 @ : / ? # & 等字符，不编码会把 URI 截断或改变含义
# （trojan://p@ss@host 会被解析成主机是 "ss@host"）。
# 用 jq @uri：jq 本就是项目硬依赖，且 node_cli.sh 里的 _node_cli_urlencode
# 用的是同一实现，两处行为保持一致。
url_encode() { jq -nr --arg v "$1" '$v | @uri'; }

# ── A node's name in clients ──────────────────────────────────────────────────
# What a client shows for a node (the #name of its link, its Clash / sing-box
# name): its display name when it has one (psm node … --display-name), else
# the flag of the server's country and its tag, "🇭🇰 reality-1", or the tag
# alone when the country is not known. It was "PSM-<tag>" before 2026-11 (#10).
psm_node_label() {   # <tag> [node json]
    local dn=""
    [[ -n "${2:-}" ]] && dn=$(printf '%s' "$2" | jq -r '.display_name // ""' 2>/dev/null)
    [[ -n "$dn" ]] && { printf '%s' "$dn"; return 0; }
    local flag; flag=$(psm_country_flag "$(psm_server_country)")
    printf '%s' "${flag:+$flag }$1"
}
psm_link_label() { url_encode "$(psm_node_label "$@")"; }   # for a link's #fragment
psm_yaml_str() { jq -nc --arg v "$1" '$v'; }                # a YAML (JSON) string
# the same rule inside jq, on a node object: jq --arg flag "$(psm_server_flag)" "$PSM_LABEL_JQ …"
PSM_LABEL_JQ='def psm_label($flag): if (.display_name // "") != "" then .display_name
    else (if $flag == "" then "" else $flag + " " end) + .tag end;'
psm_server_flag() { psm_country_flag "$(psm_server_country)"; }

# <two-letter code> → its flag (two regional indicator symbols), written as
# UTF-8 bytes so that no locale is needed; nothing for anything else.
psm_country_flag() {
    local cc; cc=$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')
    [[ "$cc" =~ ^[A-Z]{2}$ && "$cc" != XX ]] || return 0
    local i o
    for i in 0 1; do
        printf -v o '%d' "'${cc:i:1}"
        # shellcheck disable=SC2059   # the escape is built, then printed
        printf "\\xf0\\x9f\\x87\\x$(printf '%x' $((0xa6 + o - 65)))"
    done
}

# The server's country as Cloudflare places its address (the panel names its
# nodes by the same), looked up once and kept in psm.state: a week, a day when
# the lookup found nothing. PSM_SERVER_COUNTRY overrides it ("" for none).
psm_server_country() {
    if [[ -n "${PSM_SERVER_COUNTRY+x}" ]]; then printf '%s' "$PSM_SERVER_COUNTRY"; return 0; fi
    local now at cc keep=86400
    now=$(date +%s); at=$(state_get server_country_at); cc=$(state_get server_country)
    [[ -n "$cc" ]] && keep=604800
    if [[ "$at" =~ ^[0-9]+$ ]] && (( now - at < keep )); then printf '%s' "$cc"; return 0; fi
    cc=$(curl -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^loc=\([A-Z][A-Z]\)$/\1/p')
    [[ "$cc" == XX ]] && cc=""
    { state_set server_country "$cc" && state_set server_country_at "$now"; } >/dev/null 2>&1 || true
    printf '%s' "$cc"
}

rand_str() {
    # rand_str <length>
    local len="${1:-16}"
    [[ "$len" =~ ^[0-9]+$ && "$len" -gt 0 ]] || len=16

    local out=""
    if command -v openssl &>/dev/null; then
        out=$(openssl rand -hex "$(((len + 1) / 2))" 2>/dev/null) || out=""
        out=${out:0:len}
    fi

    # head exits after len bytes, which gives tr a SIGPIPE under pipefail.
    # The output is still correct, so suppress that expected non-zero status.
    # LC_ALL=C 不能省：UTF-8 locale 下 tr 读 /dev/urandom 会以
    # "Illegal byte sequence" 报错退出，结果是空串或一两个字符。
    (( ${#out} >= len )) || out=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c "$len" || true)

    # 最后一道兜底：本函数产出的是密码 / PSK / 伪装路径，长度不足绝不能悄悄放行。
    # 这条路径刻意不碰 tr（上面那条正是栽在 tr 上的），只用 od + bash 内建替换。
    if (( ${#out} < len )); then
        local hex
        hex=$(LC_ALL=C od -An -tx1 -N "$len" /dev/urandom 2>/dev/null) || hex=""
        hex=${hex//[[:space:]]/}
        out=${hex:0:len}
    fi

    # 还是拿不到就报错返回非零，让调用方（多在 set -e 下）当场中止：
    # 宁可装到一半失败，也不能生成一个空密码 / 空 PSK 的节点。
    if (( ${#out} < len )); then
        log_error "$(t common.err.rand_failed)"
        return 1
    fi
    printf '%s' "$out"
}

rand_path() {
    local suffix; suffix=$(rand_str 8)
    [[ -n "$suffix" ]] || suffix="$(date +%s)"
    echo "/$suffix"
}

uuid_gen() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif command -v "$XRAY_BIN" &>/dev/null; then
        "$XRAY_BIN" uuid
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())"
    fi
}

# ── Config test & reload ──────────────────────────────────────────────────────
# Where a certificate or key a node uses may live: PSM's certificate store,
# the cores' own certificate directories and Hysteria2's. Not PSM's config
# directories (the agent token, user store and keys of the panel live there):
# a path set from the panel elsewhere is refused, and no file outside these
# is ever made readable to the cores (lib/coreperm.sh).
psm_cert_dirs() {
    printf '%s\n' "$NGINX_SSL_DIR" "$CFG_DIR/xray/certs" "${XRAY_CFG_DIR:-/usr/local/etc/xray}" \
        "${SINGBOX_CFG_DIR:-/etc/sing-box}" "${MIHOMO_CFG_DIR:-/etc/mihomo}" /etc/hysteria
}
# <file>: its real path (links resolved) is under one of psm_cert_dirs.
psm_cert_file_allowed() {
    local real d
    real=$(readlink -f -- "$1" 2>/dev/null) || return 1
    [[ -n "$real" ]] || return 1
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        d=$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")
        [[ "$real" == "$d"/* ]] && return 0
    done < <(psm_cert_dirs)
    return 1
}

# psm_nginx_forwards: lib/nginx_forwards.sh (its own file: nginx's start hook
# sources it alone)
source "$(dirname "${BASH_SOURCE[0]}")/nginx_forwards.sh"

# nginx's own start (boot, systemctl start/restart) refuses a forward off this
# server too: a systemd drop-in runs lib/nginx_forwards.sh first. (OpenRC: the
# distro's init script keeps its own start_pre; there PSM's reloads and psm
# guard are the check.) Returns 1 if the drop-in could not be written.
psm_nginx_start_hook() {
    _uses_systemd || return 0
    local d="${PSM_SYSTEMD_DIR:-/etc/systemd/system}/nginx.service.d" f want
    f="$d/psm-forwards.conf"
    want=$(printf '[Service]\n# PSM (roomkey): nginx does not start with a forward off this server\nExecStartPre=/bin/bash %s/nginx_forwards.sh\n' "$LIB_DIR")
    [[ -f "$f" && "$(cat "$f")" == "$want" ]] && return 0
    mkdir -p "$d" && printf '%s\n' "$want" >"$f" && systemctl daemon-reload >/dev/null 2>&1
}

nginx_test_reload() {
    # Alpine: a top-level stream {} from the distro in conf.d breaks PSM's
    # nginx.conf (see lib/nginx.sh). Only defined once lib/nginx.sh is loaded.
    declare -F _nginx_neutralize_toplevel_confd >/dev/null && _nginx_neutralize_toplevel_confd
    local test_out fwd
    fwd=$(psm_nginx_forwards)
    if [[ -n "$fwd" ]]; then
        log_error "nginx: a forward off this server is configured; roomkey runs none (it would make this server an open relay), so nginx was not reloaded. Remove it:"
        printf '  %s\n' "${fwd//$'\n'/$'\n'  }" >&2
        return 1
    fi
    if test_out=$(nginx -t 2>&1); then
        svc_reload nginx || svc_restart nginx || {
            log_error "$(t common.nginx.reload_fail)"
            return 1
        }
        log_ok "$(t common.nginx.reloaded)"
    else
        log_error "$(t common.nginx.test_fail)"
        echo "$test_out" >&2
        return 1
    fi
}

# The last step before a core's config is checked and the core restarted —
# every restart PSM does, whichever menu, rebuild, rollback or watchdog wrote
# the config — and it can refuse the config (the restart then keeps the last
# good one):
#  - accounts (lib/users.sh) go in;
#  - outbound abuse rules (BitTorrent, SMTP port 25) are present: one friend's
#    torrent client is the usual way a shared server gets a DMCA notice;
#  - every REALITY listener falls back to this server only (a loopback
#    target). A third-party fallback passes every connection without the key
#    on to that site — behind a CDN, an open relay into the whole CDN, which
#    is what gets servers suspended.
psm_users_merge() {
    local core="$1"
    # a restore that did not finish (lib/backup.sh): the store on disk may be
    # the archive's, with users revoked since; no core starts until it is redone
    if [[ -e "$(dirname "$CFG_DIR")/.psm-restore/incomplete" ]]; then
        log_error "a restore did not finish: run it again before the cores start (psm restore)"
        return 1
    fi
    if [[ -f "$LIB_DIR/users.sh" ]]; then
        declare -F psm_users_inject >/dev/null || source "$LIB_DIR/users.sh"
        # Xray's per-user counters reset with the restart: banked first (best effort)
        [[ "$core" == xray ]] && { psm_users_checkpoint_quiet || true; }
        psm_users_inject "$core" || { log_error "the accounts could not be merged into ${core}'s config"; return 1; }
    fi
    psm_abuse_rules "$core" || { log_error "the abuse rules could not be added to ${core}'s config"; return 1; }
    psm_reality_guard "$core"
}

_psm_core_cfg() {
    case "$1" in
        xray)     printf '%s' "$XRAY_CFG_DIR/config.json" ;;
        sing-box) printf '%s' "$SINGBOX_CFG_DIR/config.json" ;;
        mihomo)   printf '%s' "$MIHOMO_CFG_DIR/config.yaml" ;;
    esac
}

# PSM's own HTTPS site (lib/nginx.sh, reality_own_site_ensure): the only
# place a camouflage fallback may lead.
PSM_OWN_SITE="127.0.0.1:8443"

# What nginx could load under /etc/nginx that PSM did not write, before PSM's
# first nginx (join, and nginx_install): any file or link, except PSM's own
# certificate store /etc/nginx/ssl (certificates can be issued before the
# first nginx, and nginx reads one only where a config names it; links are
# not allowed there either). A linked /etc/nginx or ssl is refused: what it
# points at cannot be established. Prints the first finding (path from /).
# 0: clean (or absent); 1: a finding; 2: it could not be read.
psm_nginx_leftovers() {
    local root="${PSM_FS_ROOT:-}" d out
    d="$root/etc/nginx"
    if [[ -L "$d" ]]; then echo "/etc/nginx (a link)"; return 1; fi
    [[ -e "$d" ]] || return 0
    if [[ ! -d "$d" ]]; then echo "/etc/nginx (not a directory)"; return 1; fi
    if [[ -L "$d/ssl" ]]; then echo "/etc/nginx/ssl (a link)"; return 1; fi
    if [[ -e "$d/ssl" && ! -d "$d/ssl" ]]; then echo "/etc/nginx/ssl (not a directory)"; return 1; fi
    out=$(find "$d" -mindepth 1 \( -path "$d/ssl" -prune \) -o ! -type d -print 2>/dev/null) \
        || { echo "/etc/nginx (could not be read)"; return 2; }
    if [[ -z "$out" && -d "$d/ssl" ]]; then
        out=$(find "$d/ssl" -mindepth 1 -type l -print 2>/dev/null) || { echo "/etc/nginx/ssl (could not be read)"; return 2; }
    fi
    [[ -n "$out" ]] || return 0
    out="${out%%$'\n'*}"
    printf '%s\n' "${out#"$root"}"
    return 1
}

# jq definitions for addresses, parsed rather than matched by prefix ("127.x"
# as the start of a host name proves nothing; an expanded ::1 is loopback):
#   loip     an IP literal on loopback (127.0.0.0/8 dotted quad, ::1 however written)
#   lohost   loip, or "localhost"
#   sockhost the host part of "host:port", "[v6]:port", a bare host or v6 literal
#   loaddr   sockhost | lohost — "" (":9090", every interface) is not loopback
PSM_JQ_ADDR='def loip: ascii_downcase as $h
    | if ($h | test("^127\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$")) then all($h | split(".")[] | tonumber; . <= 255)
      elif ($h | test("^[0-9a-f:]+$")) and ($h | contains(":")) then
        ($h | split("::")) as $p
        | if ($p | length) > 2 then false
          else [$p[0] | select(. != "") | split(":")[]] as $a
            | (if ($p | length) == 2 then [$p[1] | select(. != "") | split(":")[]] else [] end) as $b
            | (if ($p | length) == 2 then $a + [range(8 - ($a | length) - ($b | length)) | "0"] + $b else $a end) as $g
            | ($g | length) == 8 and all($g[]; test("^[0-9a-f]{1,4}$"))
              and all($g[0:7][]; test("^0+$")) and ($g[7] | test("^0*1$"))
          end
      else false end;
  def lohost: (ascii_downcase == "localhost") or loip;
  def sockhost: tostring | if startswith("[") then ((capture("^\\[(?<h>[^]]+)\\](:[0-9]*)?$") | .h) // "")
      elif (split(":") | length) > 2 then .
      elif contains(":") then split(":")[0]
      else . end;
  def loaddr: sockhost | lohost;'

# psm_fallback_violations <core> [config]: every camouflage fallback in a
# core's config that is not PSM's own site, one per line — REALITY (dest and
# target in Xray; both must be the own site), and ShadowTLS handshakes
# (sing-box, mihomo). A config that cannot be read is a violation too.
# The config as the guard reads it. Xray and sing-box read JSON keys without
# regard to case (Go), and Xray lower-cases a protocol or security name: so the
# keys the guard looks at are put in their canonical spelling, two spellings
# of one key (or a key outside ASCII) are refused (which one the core takes is not worth guessing), and
# those names are lower-cased. Prints the path of a temporary normalised copy
# (the caller removes it), or nothing (and status 1) when it cannot be made.
# mihomo's YAML keys are case-sensitive: its config is read as it is.
PSM_GUARD_KEYS="inbounds outbounds protocol settings auth accounts user pass users username password streamSettings security realitySettings dest target fallbacks fallback fallback_for_alpn listen listen_port port tag type method clients experimental clash_api external_controller v2ray_api tls reality enabled handshake handshake_for_server_name server server_port masquerade url"
_psm_guard_norm() {   # <core> <config>
    local out
    out=$(mktemp) || return 1
    if jq --arg keys "$PSM_GUARD_KEYS" '
        ($keys | split(" ") | map({key: ascii_downcase, value: .}) | from_entries) as $canon
        | walk(if type == "object" then
                 # a key with a letter outside ASCII (Go folds some, such as the
                 # long s, onto ASCII ones): nothing a core needs, refused
                 if any(keys[]; explode | any(. > 127)) then error("a key outside ASCII") else . end
                 | (to_entries | map(.key = ($canon[.key | ascii_downcase] // .key))) as $e
                 | if ($e | map(.key) | unique | length) != ($e | length)
                   then error("one key spelled two ways") else ($e | from_entries) end
                 | with_entries(if (.key | IN("protocol", "security", "type", "auth", "method")) and (.value | type) == "string"
                                then .value |= ascii_downcase else . end)
               else . end)' "$2" >"$out" 2>/dev/null; then
        printf '%s' "$out"
    else
        rm -f "$out"; return 1
    fi
}

psm_fallback_violations() {
    local core="$1" cfg="${2:-}" norm rc=0
    [[ -n "$cfg" ]] || cfg=$(_psm_core_cfg "$core")
    [[ -f "$cfg" ]] || return 0
    case "$core" in
        xray|sing-box)
            norm=$(_psm_guard_norm "$core" "$cfg") || { echo "$cfg cannot be read (or spells one key two ways)"; return 0; }
            _psm_fallback_violations_read "$core" "$norm" || rc=$?
            rm -f "$norm"; return "$rc" ;;
        *) _psm_fallback_violations_read "$core" "$cfg" ;;
    esac
}
_psm_fallback_violations_read() {   # <core> <config, normalised for xray / sing-box>
    local core="$1" cfg="$2" out
    case "$core" in
        xray) out=$(jq -r --arg own "$PSM_OWN_SITE" "$PSM_JQ_ADDR"'
            # VLESS / Trojan fallbacks: a port, a loopback address or a socket on this server only
            (.inbounds[]? | (.settings.fallbacks // [])[]? | (.dest // "") | tostring
             | select((test("^[0-9]+$") or test("^[/@]") or (test(":[0-9]+$") and loaddr)) | not)
             | "fallback to \(.)"),
            (.inbounds[]? | select((.streamSettings.security // "") == "reality") | .streamSettings.realitySettings as $r
            | [($r | has("dest")), ($r | has("target"))] as [$hd, $ht]
            | if ($hd | not) and ($ht | not) then "REALITY without a target"
              elif ($hd and ($r.dest | tostring) != $own) then "REALITY dest \($r.dest)"
              elif ($ht and ($r.target | tostring) != $own) then "REALITY target \($r.target)"
              else empty end)' "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
        sing-box) out=$(jq -r "$PSM_JQ_ADDR"'def offsite_masq: if type == "object" then (if (.type // "") == "proxy" then (.url // "" | tostring) else "" end) else tostring end
                | test("^https?://") and (test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?(/|$)") | not);
            # Trojan fallbacks (default and per ALPN), each on its own: an IP
            # literal on loopback, nothing else (a hostname proves nothing)
            (.inbounds[]? | [(.fallback // empty), ((.fallback_for_alpn // {}) | .[])][] | (.server // "") | tostring
             | select(loip | not) | "Trojan fallback to \(.)"),
            (.inbounds[]?
            | if .type == "hysteria2" and has("masquerade") and (.masquerade | offsite_masq) then "Hysteria2 masquerade \(.masquerade | tostring)"
              elif .tls.reality.enabled == true then .tls.reality.handshake as $h
                | select(($h.server // "") != "127.0.0.1" or ($h.server_port // 0) != 8443) | "REALITY handshake \($h.server):\($h.server_port)"
              elif .type == "shadowtls" then (.handshake // {}) as $h
                | select(($h.server // "") != "127.0.0.1" or ($h.server_port // 0) != 8443 or (.handshake_for_server_name // {} | length) > 0)
                | "ShadowTLS handshake \($h.server):\($h.server_port)"
              else empty end)' "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
        mihomo) out=$(jq -r --arg own "$PSM_OWN_SITE" 'def offsite_masq: if type == "object" then (if (.type // "") == "proxy" then (.url // "" | tostring) else "" end) else tostring end
                | test("^https?://") and (test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?(/|$)") | not);
            .listeners[]?
            | (if .type == "hysteria2" and has("masquerade") and (.masquerade | offsite_masq) then "Hysteria2 masquerade \(.masquerade | tostring)" else empty end),
              (if has("reality-config") then (.["reality-config"].dest // "" | tostring) | select(. != $own) | "REALITY dest \(.)" else empty end),
              (if (.["shadow-tls"].enable // false) then (.["shadow-tls"].handshake.dest // "" | tostring) | select(. != $own) | "ShadowTLS handshake \(.)" else empty end)' \
            "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
    esac
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

# psm_open_proxy_violations <core> [config]: listeners anyone can use without
# an account — a public SOCKS / HTTP / mixed proxy with no users, or a public
# port forward (Xray dokodemo-door / tunnel, sing-box direct, mihomo tunnel) —
# one per line. Loopback and unix-socket listeners are not public.
psm_open_proxy_violations() {
    local core="$1" cfg="${2:-}" norm rc=0
    [[ -n "$cfg" ]] || cfg=$(_psm_core_cfg "$core")
    [[ -f "$cfg" ]] || return 0
    case "$core" in
        xray|sing-box)
            norm=$(_psm_guard_norm "$core" "$cfg") || { echo "$cfg cannot be read (or spells one key two ways)"; return 0; }
            _psm_open_proxy_violations_read "$core" "$norm" || rc=$?
            rm -f "$norm"; return "$rc" ;;
        *) _psm_open_proxy_violations_read "$core" "$cfg" ;;
    esac
}
_psm_open_proxy_violations_read() {   # <core> <config, normalised for xray / sing-box>
    local core="$1" cfg="$2" out
    local pub="$PSM_JQ_ADDR"'
        def public: ((.listen // "0.0.0.0") | tostring) as $l | (($l | test("^[/@]")) or ($l | loaddr)) | not;'
    case "$core" in
        xray) out=$(jq -r "$pub"'
            .inbounds[]? | select(public) | (.protocol // "") as $p | ":\(.port // "?") (\(.tag // "untagged"))" as $w
            # (an account with no user name is no account)
            | ([(.settings.accounts // [])[]? | select(type == "object" and ((.user // "") | tostring | length) > 0)] | length) as $named
            | if ($p == "socks" or $p == "mixed") and (((.settings.auth // "noauth") != "password") or $named == 0) then "open \($p) proxy \($w)"
              elif $p == "http" and $named == 0 then "open HTTP proxy \($w)"
              elif $p == "shadowsocks" and ((.settings.method // "") | IN("none", "plain")) then "unencrypted Shadowsocks (no key) \($w)"
              elif $p == "dokodemo-door" or $p == "tunnel" then "port forward \($w)"
              else empty end' "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
        sing-box) out=$(jq -r "$pub"'
            (.inbounds[]? | select(public) | (.type // "") as $p | ":\(.listen_port // "?") (\(.tag // "untagged"))" as $w
            | ([(.users // [])[]? | select(type == "object" and ((.username // "") | tostring | length) > 0)] | length) as $named
            | if ($p == "socks" or $p == "http" or $p == "mixed") and $named == 0 then "open \($p) proxy \($w)"
              elif $p == "shadowsocks" and ((.method // "") | IN("none", "plain")) then "unencrypted Shadowsocks (no key) \($w)"
              elif $p == "direct" then "port forward \($w)"
              else empty end),
            # its control and stats APIs
            ([(.experimental.clash_api.external_controller // empty), (.experimental.v2ray_api.listen // empty)][]
             | tostring | select(length > 0 and (loaddr | not)) | "control API on \(.)")' "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
        mihomo) out=$(jq -r "$pub"'
            # a loopback address or a prefix inside 127.0.0.0/8 or ::1/128
            def lo: tostring | if contains("/") then split("/") as [$a, $m]
                    | ($a | loip) and (if ($a | contains(":")) then $m == "128" else (($m | tonumber? // -1) >= 8 and ($m | tonumber? // 99) <= 32) end)
                  else loaddr end;
            # global authentication counts unless a public range skips it
            ((.authentication // []) | length > 0) as $auth
            | ([(."skip-auth-prefixes" // [])[] | select(lo | not)] | length > 0) as $skips
            | ($auth and ($skips | not)) as $global_auth
            # the global ports listen publicly with allow-lan on a public bind;
            # their UDP (socks-port, mixed-port) is relayed without the account
            # or the LAN client list, so only the bind counts
            | ((."allow-lan" == true) and ((."bind-address" // "*") | lo | not)) as $lan
            | ((.listeners[]? | select(public) | (.type // "") as $p | ":\(.port // "?") (\(.name // "unnamed"))" as $w
                # its own accounts only: the global list (which mihomo may discard
                # entry by entry) is not counted for a public listener
                # every account named and with a password (mihomo installs each
                # one: a blank one alongside a good one would let anyone in)
                | ((.users // []) as $u | ($u | length) > 0
                   and all($u[]; type == "object" and ((.username // "") | tostring | length) > 0 and ((.password // "") | tostring | length) > 0)) as $authed
                | if ($p == "socks" or $p == "http" or $p == "mixed") and ($authed | not)
                  then "open \($p) proxy \($w)"
                  # mihomo relays a SOCKS listener'"'"'s UDP without the account
                  elif ($p == "socks" or $p == "mixed") and (if has("udp") then .udp != false else true end)
                  then "\($p) UDP relayed without an account \($w)"
                  elif $p == "tunnel" then "port forward \($w)"
                  else empty end),
               # PSM puts no global proxy port in a server config: on a public
               # bind each one is refused (their UDP is relayed without the
               # account, and mihomo can discard the accounts themselves)
               (if $lan then
                  (["port", "socks-port", "mixed-port", "redir-port", "tproxy-port"][] as $k | select(has($k) and (.[$k] // 0) != 0) | "open proxy on the global \($k)")
                else empty end),
               # top-level tunnels: each a port forward, public unless bound to loopback
               (.tunnels[]? | (if type == "string" then (split(",")[1] // "") else (.address // "") end) as $a
                | select($a | loaddr | not)
                | "port forward (tunnel \($a))"),
               # its control API (anyone reaching it could add a listener) and a DNS server
               ((["external-controller", "external-controller-tls"][] as $k
                 | select(has($k) and ((.[$k] // "") | tostring | length) > 0 and (.[$k] | loaddr | not))
                 | "control API on \(.[$k]) (\($k))"),
                (if (.dns.enable // false) and ((.dns.listen // "") | tostring | length) > 0
                    and (.dns.listen | loaddr | not)
                 then "DNS server on \(.dns.listen)" else empty end)),
               # listeners mihomo starts from top-level settings PSM never
               # writes (Shadowsocks, VMess, TUIC servers): not PSM nodes
               ((["ss-config", "vmess-config"][] as $k | select(((.[$k] // "") | tostring | length) > 0) | "a listener PSM does not manage (\($k))"),
                (if (."tuic-server".enable // false) == true then "a listener PSM does not manage (tuic-server)" else empty end)))' "$cfg" 2>/dev/null) || { echo "$cfg cannot be read"; return 0; } ;;
    esac
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
}

# The standalone Hysteria2 server's YAML: no masquerade that proxies another
# site (it would fetch that site for anyone). Checked before its every start
# (its unit runs lib/coreperm.sh hysteria), a restore's included.
psm_hy2_standalone_ok() {   # [config]
    local cfg="${1:-/etc/hysteria/config.yaml}" text sect
    [[ -e "$cfg" ]] || return 0
    text=$(cat "$cfg" 2>/dev/null) || { log_error "hysteria: $cfg cannot be read; hysteria-server was not started"; return 1; }
    # the masquerade, however it is written (a block, flow style, quoted keys):
    # from its key to the next top-level key; any "proxy" in it is refused
    # (PSM never writes one: the 404 default, or a file/string page)
    sect=$(awk '
        /^[[:space:]]*#/ { next }
        /^["'\'']?masquerade["'\'']?[[:space:]]*:/ { m = 1; print; next }
        m && /^[^[:space:]#}]/ { m = 0 }
        m { print }' <<<"$text")
    # a proxy masquerade: its type, or a "proxy:" block (a file or string page
    # that merely mentions the word is fine)
    local re_type="type[\"']?[[:space:]]*:[[:space:]]*[\"']?proxy([\"',}[:space:]]|$)" re_key="(^|[{,[:space:]])[\"']?proxy[\"']?[[:space:]]*:"
    if grep -Eqi "$re_type|$re_key" <<<"$sect" \
       || grep -Ei '^[^#]*[{,][[:space:]]*["'\'']?masquerade["'\'']?[[:space:]]*:' <<<"$text" | grep -Eqi "$re_type|$re_key"; then
        log_error "hysteria: its masquerade proxies a site ($cfg): anyone would be passed on to it; hysteria-server was not started"
        return 1
    fi
    return 0
}

# Refuses a config whose camouflage falls back anywhere but PSM's own site:
# such a fallback passes every connection without the key on to that site —
# behind a CDN, an open relay into the whole CDN.
psm_reality_guard() {
    local core="$1" cfg="${2:-}" bad
    # and a listener anyone can use without an account: an open proxy outright
    bad=$(psm_open_proxy_violations "$core" "$cfg")
    if [[ -n "$bad" ]]; then
        log_error "${core}: a listener anyone can use without an account ($(tr '\n' ';' <<<"$bad")): an open proxy. Give it accounts, or listen on 127.0.0.1 only; ${core} was not started"
        return 1
    fi
    bad=$(psm_fallback_violations "$core" "$cfg")
    [[ -z "$bad" ]] && return 0
    log_error "${core}: a camouflage fallback leads off this server ($(tr '\n' ';' <<<"$bad")): anyone without the key would be passed on to it, an open relay. Only PSM's own site (${PSM_OWN_SITE}, REALITY own_site) is allowed; ${core} was not started"
    return 1
}

# Blocks BitTorrent and SMTP (port 25) outbound, idempotently. mihomo cannot
# tell BitTorrent apart in its rules: it gets the port rule only.
psm_abuse_rules() {
    local core="$1" cfg tmp; cfg=$(_psm_core_cfg "$core")
    [[ -f "$cfg" ]] || return 0
    tmp=$(mktemp) || return 1
    case "$core" in
        xray) jq '
            ((.outbounds // []) | any(.tag == "blocked")) as $has
            | (if $has then . else .outbounds = ((.outbounds // []) + [{protocol: "blackhole", tag: "blocked"}]) end)
            | .routing.rules = ([{type: "field", ruleTag: "psm-abuse-bt", protocol: ["bittorrent"], outboundTag: "blocked"},
                                 {type: "field", ruleTag: "psm-abuse-smtp", network: "tcp", port: "25", outboundTag: "blocked"}]
                                + [(.routing.rules // [])[] | select((.ruleTag // "") | startswith("psm-abuse-") | not)])
            # BitTorrent is recognised by sniffing; an inbound that did not sniff
            # gets it for routing only (routeOnly: where traffic goes is unchanged)
            | .inbounds |= map(if ((.protocol // "") | IN("vless", "vmess", "trojan", "hysteria", "shadowsocks")) and (.sniffing.enabled != true)
                               then .sniffing = {enabled: true, destOverride: ["http", "tls"], routeOnly: true}
                               else . end)' "$cfg" > "$tmp" 2>/dev/null ;;
        sing-box) jq '
            def abuse: [{protocol: "bittorrent", action: "reject"}, {port: 25, action: "reject"}];
            def offsite_masq: if type == "object" then (if (.type // "") == "proxy" then (.url // "" | tostring) else "" end) else tostring end
                | test("^https?://") and (test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?(/|$)") | not);
            # a Hysteria2 masquerade proxying another site would fetch it for
            # anyone, at the cost of this server: none (sing-box answers 404) instead
            .inbounds = [(.inbounds // [])[] | if .type == "hysteria2" and has("masquerade") and (.masquerade | offsite_masq) then del(.masquerade) else . end] |
            .route.rules = ((.route.rules // []) | map(select(. != {protocol: "bittorrent", action: "reject"} and . != {port: 25, action: "reject"}))
                            | (if (.[0].action // "") == "sniff" then [.[0]] + abuse + .[1:] else [{action: "sniff"}] + abuse + . end))' "$cfg" > "$tmp" 2>/dev/null ;;
        mihomo) jq 'def offsite_masq: if type == "object" then (if (.type // "") == "proxy" then (.url // "" | tostring) else "" end) else tostring end
                | test("^https?://") and (test("^https?://(127\\.0\\.0\\.1|localhost|\\[::1\\])(:[0-9]+)?(/|$)") | not);
            .listeners = [(.listeners // [])[] | if .type == "hysteria2" and has("masquerade") and (.masquerade | offsite_masq) then del(.masquerade) else . end]
            # this server itself and private networks are no destination for a
            # user (the local page, loopback backends, cloud metadata, the
            # provider LAN), as in Xray (geoip:private) and sing-box
            # (ip_is_private); without no-resolve, so a name that resolves
            # there is refused too
            | ["IP-CIDR,0.0.0.0/8,REJECT", "IP-CIDR,127.0.0.0/8,REJECT", "IP-CIDR,10.0.0.0/8,REJECT",
               "IP-CIDR,172.16.0.0/12,REJECT", "IP-CIDR,192.168.0.0/16,REJECT", "IP-CIDR,169.254.0.0/16,REJECT",
               "IP-CIDR,100.64.0.0/10,REJECT", "IP-CIDR,198.18.0.0/15,REJECT", "IP-CIDR,224.0.0.0/3,REJECT",
               "IP-CIDR6,::1/128,REJECT", "IP-CIDR6,::ffff:0:0/96,REJECT", "IP-CIDR6,fc00::/7,REJECT",
               "IP-CIDR6,fe80::/10,REJECT", "DST-PORT,25,REJECT"] as $abuse
            | .rules = ($abuse + [(.rules // [])[] | select(. as $r | $abuse | index([$r]) | not)])' "$cfg" > "$tmp" 2>/dev/null ;;
        *) rm -f "$tmp"; return 0 ;;
    esac
    if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; return 1; fi
    # unchanged: leave it; changed: replaced atomically (mode and owner kept),
    # and a write that fails is a failure
    local rc=0
    cmp -s "$tmp" "$cfg" || psm_file_replace "$cfg" "$tmp" || rc=1
    rm -f "$tmp"
    return "$rc"
}

xray_test_restart() {
    # xray_rebuild_from_stores runs every module's apply in a row and tests the
    # finished config once; testing each half-rebuilt intermediate would fail.
    [[ -n "${PSM_XRAY_DEFER_RESTART:-}" ]] && return 0
    # psm-core must be able to read what PSM just wrote (lib/coreperm.sh)
    source "$LIB_DIR/coreperm.sh" && psm_core_nonroot_ensure xray
    # Camouflage sites from before the h2 fallback (lib/nginx.sh); only defined
    # once a module that uses the fallback has loaded lib/nginx.sh.
    declare -F nginx_upgrade_http_camouflage >/dev/null && nginx_upgrade_http_camouflage
    # accounts, abuse rules, REALITY fallbacks on this server only: a config
    # that fails these is never started (the last good one is put back below)
    local guarded=1 test_out="refused by PSM (see above)"
    psm_users_merge xray || guarded=0
    # The last config that passed its test and started is kept beside it; one
    # that fails either is replaced by it, and Xray started again — sing-box
    # and mihomo roll back the same way (their .prev). Before, a change Xray
    # refused stayed on disk, and the next restart of any kind took every node
    # down with it.
    local cfg="$XRAY_CFG_DIR/config.json" good="$XRAY_CFG_DIR/config.json.good"
    if (( guarded )) && { test_out=$("$XRAY_BIN" run -test -config "$cfg" 2>&1) \
        || test_out=$("$XRAY_BIN" -test -config "$cfg" 2>&1); }; then
        # still running a moment later (a port it could not bind ends it
        # right after a "successful" start) before it counts as the last good one
        if svc_restart xray && sleep "${PSM_XRAY_SETTLE:-1}" && svc_is_active xray; then
            cp -p "$cfg" "$good" 2>/dev/null || true
            log_ok "$(t common.xray.restarted)"
            return 0
        fi
        log_error "$(t common.xray.restart_fail)"
    else
        log_error "$(t common.xray.test_fail)"
        echo "$test_out" >&2
    fi
    if [[ -f "$good" ]] && ! cmp -s "$good" "$cfg"; then
        cat "$good" > "$cfg"
        log_warn "$(t common.xray.rolled_back)"
        svc_restart xray >/dev/null 2>&1 || true
    fi
    return 1
}

# ── Dependency check ──────────────────────────────────────────────────────────
require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "$(t common.err.missing_cmd "$cmd")"
    done
}

is_installed() { command -v "$1" &>/dev/null; }

# Package providing command <cmd>, where a distro names it differently.
_pkg_name() {
    case "${PKG_MGR}:$1" in
        apk:qrencode)       echo "libqrencode-tools" ;;
        apt:xz|apt-get:xz)  echo "xz-utils" ;;
        *)                  echo "$1" ;;
    esac
}

ensure_pkg_deps() {
    # ensure_pkg_deps <pkg1> [pkg2] ... — install any whose binary is missing.
    # Installs ONE AT A TIME on purpose: apt/dnf abort the whole transaction if
    # a single name is unavailable (dnf strict mode), so a batch would let one
    # EPEL-only package (e.g. qrencode on Rocky/Alma) block curl/jq/everything.
    # On the RHEL family, a failed package triggers one ensure_epel + retry —
    # that's where qrencode/fail2ban/wireguard-tools etc. live on EL8/9.
    local missing=() pkg
    for pkg in "$@"; do
        command -v "$pkg" &>/dev/null || missing+=("$pkg")
    done
    (( ${#missing[@]} == 0 )) && return 0

    log_step "$(t common.pkg.installing "${missing[*]}")"
    local failed=() epel_tried=0
    detect_os
    for pkg in "${missing[@]}"; do
        pkg_install "$(_pkg_name "$pkg")" &>/dev/null && continue
        if [[ "$PKG_MGR" == "yum" && $epel_tried -eq 0 ]]; then
            epel_tried=1
            ensure_epel || true
        fi
        pkg_install "$(_pkg_name "$pkg")" &>/dev/null && continue
        failed+=("$pkg")
    done

    if (( ${#failed[@]} == 0 )); then
        log_ok "$(t common.pkg.installed "${missing[*]}")"
    else
        # Warn but do NOT return non-zero: callers run under `set -e` and treat
        # this as best-effort; hard requirements are enforced via require_cmd.
        log_warn "$(t common.pkg.install_fail "${failed[*]}")"
    fi
    return 0
}

# Alpine ships busybox applets where PSM relies on GNU behaviour (date -d
# "now +1 month", mktemp --suffix, ps -C, grep -P, ss, …) and ships no zoneinfo.
# Installing the GNU userland once makes every module behave as it does on
# Debian. procps-ng was named procps before Alpine 3.19, hence the fallback.
ensure_alpine_base() {
    detect_os
    [[ "$PKG_MGR" == "apk" ]] || return 0
    log_step "$(t common.alpine.base_installing)"
    local failed=() pkg
    for pkg in bash coreutils findutils grep sed gawk procps-ng iproute2 \
               util-linux tzdata ca-certificates iptables ip6tables; do
        apk info -e "$pkg" &>/dev/null && continue
        pkg_install "$pkg" &>/dev/null && continue
        [[ "$pkg" == "procps-ng" ]] && pkg_install procps &>/dev/null && continue
        failed+=("$pkg")
    done
    (( ${#failed[@]} == 0 )) || log_warn "$(t common.pkg.install_fail "${failed[*]}")"
    return 0
}

# ── IP / domain validation ────────────────────────────────────────────────────
is_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

# ── Reality camouflage-target validation (shared by all cores) ────────────────
# A Reality "dest" is the real TLS 1.3 site the server forwards the client's
# handshake to for camouflage; the client presents <sni> and expects that dest
# to serve a certificate covering it. A mismatched (sni, dest) pair installs and
# passes -test but NO client can complete the Reality handshake. These helpers
# let an add-flow vet a manually entered pair before saving the node.

# True when <dest> points at a loopback/local backend (a private camouflage site
# the server cannot SNI-cert-validate from its own vantage — e.g. Nginx's
# 127.0.0.1:8443 HTTPS site). Callers skip the advisory check for these, mirroring
# how the watchdog's _rwd_check_dest tolerates IP literals / local hosts.
reality_dest_is_local() {
    local host="$1"
    host="${host%:*}"           # strip :port  (leaves host or [ipv6])
    host="${host#[}"; host="${host%]}"
    case "$host" in
        127.*|::1|0.0.0.0|localhost|localhost.*) return 0 ;;
    esac
    return 1
}

# ── ECH (Encrypted Client Hello) for sing-box / mihomo TLS nodes ──────────────
# A node with ECH carries ech_key (the server's "ECH KEYS" PEM) and ech_config
# (the base64 ECHConfigList clients need). Measured with the real cores: an
# ECH-enabled server still accepts clients that do not use ECH, so turning it
# on never breaks existing share links; it also works over QUIC (Hysteria2,
# TUIC). Share links cannot carry the config: clients get it from PSM's
# sing-box client export or `psm node export … --format ech` (mihomo ech-opts).

# psm_ech_keypair <public-name>: sets ECH_KEY_PEM and ECH_CONFIG_B64, using
# whichever of sing-box / mihomo is installed.
psm_ech_keypair() {
    local name="$1" out sb="${SB_BIN:-${SINGBOX_BIN:-/usr/local/bin/sing-box}}" mh="${MH_BIN:-${MIHOMO_BIN:-/usr/local/bin/mihomo}}"
    ECH_KEY_PEM=""; ECH_CONFIG_B64=""
    if [[ -x "$sb" ]] && out=$("$sb" generate ech-keypair "$name" 2>/dev/null); then
        ECH_KEY_PEM=$(sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p' <<<"$out")
        ECH_CONFIG_B64=$(sed -n '/BEGIN ECH CONFIGS/,/END ECH CONFIGS/p' <<<"$out" | grep -v -- '-----' | tr -d '\n')
    elif [[ -x "$mh" ]] && out=$("$mh" generate ech-keypair "$name" 2>/dev/null); then
        # mihomo prints "Config: <base64>" then "Key: -----BEGIN ECH KEYS-----" …
        ECH_CONFIG_B64=$(sed -n 's/^Config: *//p' <<<"$out" | head -1)
        ECH_KEY_PEM=$(sed -e 's/^Key: *//' <<<"$out" | sed -n '/BEGIN ECH KEYS/,/END ECH KEYS/p')
    fi
    [[ -n "$ECH_KEY_PEM" && -n "$ECH_CONFIG_B64" ]]
}

# ECH config as the PEM block sing-box clients take (tls.ech.config lines)
psm_ech_config_pem() {
    printf -- '-----BEGIN ECH CONFIGS-----\n%s\n-----END ECH CONFIGS-----\n' "$(fold -w 64 <<<"$1")"
}

# Builder wrappers: stdin is the inbound/listener JSON, $1 the node JSON.
_sb_ech_merge() {
    jq --argjson n "$1" 'if ($n.ech_key // "") != ""
        then .tls.ech = { enabled: true, key: ($n.ech_key | split("\n") | map(select(length > 0))) }
        else . end'
}
_mh_ech_merge() {
    jq --argjson n "$1" 'if ($n.ech_key // "") != "" then ."ech-key" = $n.ech_key else . end'
}

# ── Certificate pinning for self-signed TLS nodes ────────────────────────────
# A node with insecure = 1 has a certificate no CA vouches for (PSM signed it,
# or the user brought a self-signed one). Its exports used to tell clients to
# skip verification, but Xray refuses "allowInsecure" outright since
# 2026-06-01 (v26.6.2 deleted the field), and v2rayN, v2rayNG, Happ … no
# longer pass it on: they pin the certificate given in the link instead (pcs =
# pinnedPeerCertSha256, hysteria2:// pinSHA256). So every export of such a node
# carries the pin next to the old flag: clients that know the pin check the one
# certificate, the others keep skipping verification as before.

# psm_cert_sha256 <cert file>: SHA-256 of its first (leaf) certificate, DER,
# as 64 lowercase hex digits — what pcs, pinSHA256, mihomo's fingerprint,
# Surge, Quantumult X and Loon take.
psm_cert_sha256() {
    [[ -r "${1:-}" ]] || return 1
    local fp
    fp=$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null) || return 1
    fp=${fp#*=}; fp=${fp//:/}
    [[ "$fp" =~ ^[0-9A-Fa-f]{64}$ ]] || return 1
    printf '%s' "${fp,,}"
}

# psm_cert_spki_sha256 <cert file>: SHA-256 of its public key (SPKI, DER) in
# base64 — sing-box's certificate_public_key_sha256 (1.13+).
psm_cert_spki_sha256() {
    [[ -r "${1:-}" ]] || return 1
    local h
    h=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | openssl base64 -A 2>/dev/null) || return 1
    [[ ${#h} -eq 44 ]] || return 1
    printf '%s' "$h"
}

# psm_node_pins <node json>: {"sha256": hex, "spki": base64} for a node whose
# certificate is self-signed (insecure = 1 and cert_path readable), else {}.
# The export builders merge it into the node (._pin) — jq cannot hash files.
psm_node_pins() {
    local n="$1" cp crt spki
    [[ "$(printf '%s' "$n" | jq -r '(.insecure // 0) | tostring')" =~ ^(1|true)$ ]] || { printf '{}'; return 0; }
    cp=$(printf '%s' "$n" | jq -r '.cert_path // ""')
    crt=$(psm_cert_sha256 "$cp") || { printf '{}'; return 0; }
    spki=$(psm_cert_spki_sha256 "$cp") || spki=""
    jq -cn --arg c "$crt" --arg s "$spki" '{sha256: $c} + (if $s == "" then {} else {spki: $s} end)'
}

# psm_node_with_pins <node json>: the node with ._pin set (see psm_node_pins)
psm_node_with_pins() {
    printf '%s' "$1" | jq -c --argjson p "$(psm_node_pins "$1")" '._pin = $p'
}

# psm_pin_q <node json> <parameter>: "&<parameter>=<sha256>" for a
# self-signed node, for its share link (pcs, pinSHA256, hpkp); else nothing.
psm_pin_q() {
    [[ "$(printf '%s' "$1" | jq -r '(.insecure // 0) | tostring')" =~ ^(1|true)$ ]] || return 0
    local pin; pin=$(psm_cert_sha256 "$(printf '%s' "$1" | jq -r '.cert_path // ""')") || return 0
    printf '&%s=%s' "$2" "$pin"
}

# psm_pin_yaml <node json>: "    fingerprint: <sha256>" and a newline for a
# self-signed node, to go into a Clash proxy the menus print; else nothing.
psm_pin_yaml() {
    local q; q=$(psm_pin_q "$1" fingerprint)
    [[ -n "$q" ]] && printf '    fingerprint: %s\n' "${q#&fingerprint=}"
    return 0
}

# psm_tcp_listening <port>: something listens on that TCP port (read from
# /proc, so it needs neither ss nor netstat).
psm_tcp_listening() {
    local hex; hex=$(printf '%04X' "$1")
    awk -v p=":${hex}\$" '$4 == "0A" && toupper($2) ~ p { f = 1 } END { exit !f }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

# Free TCP port on loopback for throwaway listeners (probes).
_psm_free_port() {
    local p i
    for i in $(seq 1 50); do
        p=$(( RANDOM % 20000 + 40000 ))
        psm_tcp_listening "$p" || { printf '%s' "$p"; return 0; }
    done
    return 1
}

# Real-core REALITY probe. The openssl checks in reality_validate_dest cannot
# tell whether a target actually works with REALITY: measured, www.microsoft.com
# passes all of them, yet an Xray REALITY node pointed at it never completes a
# handshake. Start a throwaway server + client of the same core on loopback and
# push one HTTPS request to the target through the tunnel.
# Returns 0 = works, 1 = handshake/tunnel failed (REALITY_PROBE_REASON),
# 2 = not tested (core or curl missing) — callers treat 2 as unknown, not bad.
reality_probe_core() {
    local core="$1" dest="$2" sni="$3" bin
    REALITY_PROBE_REASON=""
    case "$core" in
        xray)     bin="${XRAY_BIN:-/usr/local/bin/xray}" ;;
        sing-box) bin="${SB_BIN:-/usr/local/bin/sing-box}" ;;
        mihomo)   bin="${MH_BIN:-/usr/local/bin/mihomo}" ;;
        *) REALITY_PROBE_REASON="bad_core"; return 2 ;;
    esac
    [[ -x "$bin" ]] || { REALITY_PROBE_REASON="no_core"; return 2; }
    command -v curl >/dev/null 2>&1 || { REALITY_PROBE_REASON="no_curl"; return 2; }

    local host port
    if [[ "$dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else
        host="${dest%:*}"; port="${dest##*:}"
    fi
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { REALITY_PROBE_REASON="bad_dest"; return 1; }

    local dir sp cp uuid keys priv pub
    dir=$(mktemp -d) || { REALITY_PROBE_REASON="tmp_failed"; return 2; }
    if ! sp=$(_psm_free_port) || ! cp=$(_psm_free_port); then
        rm -rf "$dir"; REALITY_PROBE_REASON="no_port"; return 2
    fi
    [[ "$sp" == "$cp" ]] && cp=$(( sp + 1 ))
    uuid=$(uuid_gen) && [[ -n "$uuid" ]] || { rm -rf "$dir"; REALITY_PROBE_REASON="uuid_failed"; return 2; }
    case "$core" in
        xray) keys=$("$bin" x25519 2>/dev/null) ;;
        *)    keys=$("$bin" generate reality-keypair 2>/dev/null) ;;
    esac
    # Xray prints "PrivateKey:" + "Password (PublicKey):" (older: "Public key:");
    # sing-box and mihomo print "PrivateKey:" + "PublicKey:".
    priv=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$keys")
    pub=$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$keys")
    [[ -n "$priv" && -n "$pub" ]] || { rm -rf "$dir"; REALITY_PROBE_REASON="keygen_failed"; return 2; }

    local -a sargs cargs
    case "$core" in
        xray)
            jq -n --argjson p "$sp" --arg u "$uuid" --arg d "$dest" --arg sn "$sni" --arg k "$priv" '{
              log: {loglevel: "none"},
              inbounds: [{listen: "127.0.0.1", port: $p, protocol: "vless",
                settings: {clients: [{id: $u}], decryption: "none"},
                streamSettings: {network: "tcp", security: "reality",
                  realitySettings: {dest: $d, serverNames: [$sn], privateKey: $k, shortIds: [""]}}}],
              outbounds: [{protocol: "freedom"}]}' > "$dir/s.json"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              log: {loglevel: "none"},
              inbounds: [{listen: "127.0.0.1", port: $c, protocol: "socks", settings: {udp: false}}],
              outbounds: [{protocol: "vless",
                settings: {vnext: [{address: "127.0.0.1", port: $p, users: [{id: $u, encryption: "none"}]}]},
                streamSettings: {network: "tcp", security: "reality",
                  realitySettings: {serverName: $sn, publicKey: $k, shortId: "", fingerprint: "chrome"}}}]}' > "$dir/c.json"
            sargs=(run -c "$dir/s.json"); cargs=(run -c "$dir/c.json") ;;
        sing-box)
            jq -n --argjson p "$sp" --arg u "$uuid" --arg h "$host" --argjson hp "$port" --arg sn "$sni" --arg k "$priv" '{
              log: {level: "panic"},
              inbounds: [{type: "vless", listen: "127.0.0.1", listen_port: $p, users: [{uuid: $u}],
                tls: {enabled: true, server_name: $sn,
                  reality: {enabled: true, handshake: {server: $h, server_port: $hp},
                            private_key: $k, short_id: [""]}}}],
              outbounds: [{type: "direct"}]}' > "$dir/s.json"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              log: {level: "panic"},
              inbounds: [{type: "mixed", listen: "127.0.0.1", listen_port: $c}],
              outbounds: [{type: "vless", server: "127.0.0.1", server_port: $p, uuid: $u,
                tls: {enabled: true, server_name: $sn, utls: {enabled: true, fingerprint: "chrome"},
                  reality: {enabled: true, public_key: $k, short_id: ""}}}]}' > "$dir/c.json"
            sargs=(run -c "$dir/s.json"); cargs=(run -c "$dir/c.json") ;;
        mihomo)
            mkdir -p "$dir/s" "$dir/c"
            jq -n --argjson p "$sp" --arg u "$uuid" --arg d "$dest" --arg sn "$sni" --arg k "$priv" '{
              "log-level": "silent",
              listeners: [{name: "probe", type: "vless", listen: "127.0.0.1", port: $p,
                users: [{username: "probe", uuid: $u}],
                "reality-config": {dest: $d, "private-key": $k, "short-id": [""], "server-names": [$sn]}}],
              rules: ["MATCH,DIRECT"]}' > "$dir/s/config.yaml"
            jq -n --argjson c "$cp" --argjson p "$sp" --arg u "$uuid" --arg sn "$sni" --arg k "$pub" '{
              "log-level": "silent", "mixed-port": $c, "bind-address": "127.0.0.1", "allow-lan": false,
              proxies: [{name: "probe", type: "vless", server: "127.0.0.1", port: $p, uuid: $u,
                network: "tcp", tls: true, servername: $sn, "client-fingerprint": "chrome",
                "reality-opts": {"public-key": $k, "short-id": ""}}],
              rules: ["MATCH,probe"]}' > "$dir/c/config.yaml"
            sargs=(-d "$dir/s" -f "$dir/s/config.yaml"); cargs=(-d "$dir/c" -f "$dir/c/config.yaml") ;;
    esac

    local spid cpid code i
    "$bin" "${sargs[@]}" >"$dir/s.log" 2>&1 & spid=$!
    "$bin" "${cargs[@]}" >"$dir/c.log" 2>&1 & cpid=$!
    for i in $(seq 1 25); do
        psm_tcp_listening "$sp" && psm_tcp_listening "$cp" && break
        sleep 0.2
    done
    # One retry: a single slow response must not condemn a working target.
    for i in 1 2; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            -x "socks5h://127.0.0.1:$cp" "https://${sni}/" 2>/dev/null)
        [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && break
    done
    kill "$spid" "$cpid" 2>/dev/null || true
    wait "$spid" "$cpid" 2>/dev/null || true
    rm -rf "$dir"
    [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && return 0
    REALITY_PROBE_REASON="handshake_failed"
    return 1
}

# Probe step for the interactive flows: returns 1 only when the probe ran and
# failed (a missing core or curl never blocks), and leaves the reason where
# each flow's failure message reads it.
reality_probe_step() {
    local rc
    log_step "$(t common.reality.probing_core "$1")"
    rc=0; reality_probe_core "$1" "$2" "$3" || rc=$?
    (( rc == 1 )) || return 0
    REALITY_DEST_REASON="core_handshake"; RWD_CHECK_REASON="core_handshake"
    log_warn "$(t common.reality.core_probe_failed "$1" "$3")"
    return 1
}

# Advisory validator: is <dest> a usable Reality camouflage target for <sni>?
# openssl-only distillation of xray/reality_watchdog.sh's _rwd_check_dest, so
# sing-box/mihomo (which never load the watchdog) can vet a pair too. Asserts the
# four hard Reality requirements: TCP reachable + TLS 1.3 negotiated + leaf cert
# host-matches the SNI + X25519 in the negotiated group. Returns 0 on success
# (round-trip in REALITY_DEST_RTT_MS); on failure sets REALITY_DEST_REASON to a
# short code (same vocabulary as _rwd_check_dest) and returns 1. Advisory only —
# callers may proceed regardless.
reality_validate_dest() {
    local dest="$1" sni="$2"
    REALITY_DEST_REASON=""
    REALITY_DEST_RTT_MS=""
    REALITY_DEST_WARN=""

    # Parse "host:port" or "[ipv6]:port"
    local host port
    if [[ "$dest" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    elif [[ "$dest" == *:* && "$dest" != *:*:* ]]; then
        host="${dest%:*}"; port="${dest##*:}"
    else
        REALITY_DEST_REASON="bad_dest"; return 1
    fi
    [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || { REALITY_DEST_REASON="bad_dest"; return 1; }

    local connect="${host}:${port}"
    [[ "$host" == *:* ]] && connect="[${host}]:${port}"

    local out rc start_ms end_ms
    out=$(mktemp) || { REALITY_DEST_REASON="tmp_failed"; return 1; }

    start_ms=$(date +%s%3N 2>/dev/null); [[ "$start_ms" =~ ^[0-9]+$ ]] || start_ms=$(( $(date +%s) * 1000 ))
    if command -v timeout &>/dev/null; then
        timeout 8 openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts </dev/null >"$out" 2>&1
        rc=$?
    else
        openssl s_client -connect "$connect" -servername "$sni" \
            -tls1_3 -alpn h2,http/1.1 -showcerts </dev/null >"$out" 2>&1
        rc=$?
    fi
    end_ms=$(date +%s%3N 2>/dev/null); [[ "$end_ms" =~ ^[0-9]+$ ]] || end_ms=$(( $(date +%s) * 1000 ))
    REALITY_DEST_RTT_MS=$(( end_ms - start_ms ))

    local reason=""
    if [[ "$rc" == "124" ]]; then
        reason="tls_timeout"
    elif grep -Eqi "connect:errno|Connection refused|No route to host|Network is unreachable|Connection timed out|Operation timed out|Operation not permitted|Name or service not known|nodename nor servname" "$out"; then
        reason="tcp_failed"
    elif grep -Eqi "protocol version|unsupported protocol|wrong version number|no protocols available|tlsv1 alert protocol version" "$out"; then
        reason="tls13_unsupported"
    elif ! grep -Eq "New, TLSv1\.3|Protocol *: TLSv1\.3|Protocol version: TLSv1\.3" "$out"; then
        reason="tls13_failed"
    else
        # Reality auth rides on X25519, so the negotiated group must contain it
        # (a hybrid like X25519MLKEM768 still counts). If openssl didn't report
        # the group (very old build), don't judge.
        local grp; grp=$(grep -Ei "Server Temp Key|Negotiated TLS1\.3 group" "$out")
        if [[ -n "$grp" ]] && ! printf '%s\n' "$grp" | grep -qi "X25519"; then
            reason="no_x25519"
        else
            local cert; cert=$(mktemp)
            awk '/-----BEGIN CERTIFICATE-----/{c=1} c{print} /-----END CERTIFICATE-----/{exit}' "$out" > "$cert"
            if ! grep -q "BEGIN CERTIFICATE" "$cert"; then
                reason="no_certificate"
            else
                local clean_sni="${sni#[}"; clean_sni="${clean_sni%]}"
                if is_ipv4 "$clean_sni" || [[ "$clean_sni" == *:* ]]; then
                    # IP-literal SNI: assert cert covers the IP only when openssl
                    # supports -checkip; otherwise we cannot judge, so accept.
                    if openssl x509 -help 2>&1 | grep -q -- "-checkip" \
                        && ! openssl x509 -in "$cert" -noout -checkip "$clean_sni" >/dev/null 2>&1; then
                        reason="sni_cert_mismatch"
                    fi
                elif openssl x509 -help 2>&1 | grep -q -- "-checkhost" \
                    && ! openssl x509 -in "$cert" -noout -checkhost "$sni" >/dev/null 2>&1; then
                    reason="sni_cert_mismatch"
                fi
            fi
            rm -f "$cert"
        fi
    fi

    rm -f "$out"
    if [[ -n "$reason" ]]; then
        REALITY_DEST_REASON="$reason"; return 1
    fi

    # 握手层面合格后，再判一次「这个 dest 是不是多租户共享前端」。属于告警而非否决：
    # 判定可能误伤，且是否接受风险由使用者决定（见 reality_dest_is_shared_frontend）。
    if reality_dest_is_shared_frontend "$host" "$port"; then
        REALITY_DEST_WARN="shared_frontend:${REALITY_DEST_SHARED_BY}"
    fi
    return 0
}

# ── Reality dest：多租户共享前端（CDN 边缘）判定 ──────────────────────────────
# Reality 会把「认证未通过」的连接原样转发给 dest 以维持伪装。若 dest 落在共享 CDN 前端
# 上，攻击者只要把 ClientHello 的 SNI 填成该 CDN 上的任意站点，就能拿本机当作通往整个
# CDN 的免费隧道 —— Xray 官方文档亦警告此点（"your server effectively becomes a port
# forwarder for Cloudflare and may be abused after scanning"）。
#
# 判定手法：用一批与 dest 无关的探针域名当 SNI 去连同一个 IP:port。单租户站点不会为
# 别人的域名出示有效证书，共享前端会。这直接测「该 IP 是否按 SNI 服务任意租户」这一
# 性质本身，不依赖 IP 段或 ASN 名单，因此对各家 CDN 一视同仁，也不会随 IP 段变动失效。
#
# 探针必须覆盖想检出的 CDN（各家边缘只服务自家租户），且不能选那些本身常被当作 dest 的
# 域名 —— 否则 dest 恰好是探针时会因跳过自身而漏判。列表可通过环境变量扩充。
# 命中时把探针域名回填到 REALITY_DEST_SHARED_BY 并返回 0。
REALITY_SHARED_FRONTEND_PROBES="${REALITY_SHARED_FRONTEND_PROBES:-cdnjs.cloudflare.com www.fastly.com www.akamai.com}"

# ── Reality 回落限速（Xray: limitFallback* / mihomo: limit-fallback-*）────────
# 只在 dest 是共享 CDN 前端时才写出来 —— 官方口径也是「迫不得已偷了 CDN 证书时才考虑」。
# 这是兜底而非解法：两个参数都是「每连接」语义，攻击者循环重连即可绕过，真正有效的是
# 换掉 dest 和 Nginx 侧的未知 SNI 黑洞。
#
# 取值权衡：after_bytes 太小 → 主动探测者拉一次完整页面就撞限速，速度突降本身成为指纹，
# 反而削弱伪装；太大 → 每条新连接都白送一份额度，等于没限。默认取 1MiB，够覆盖一次
# 正常页面加载与证书链，又不给多连接白嫖留出太大空间。
REALITY_FALLBACK_AFTER_BYTES="${REALITY_FALLBACK_AFTER_BYTES:-1048576}"        # 1 MiB
REALITY_FALLBACK_BYTES_PER_SEC="${REALITY_FALLBACK_BYTES_PER_SEC:-262144}"     # 256 KiB/s
REALITY_FALLBACK_BURST_BYTES_PER_SEC="${REALITY_FALLBACK_BURST_BYTES_PER_SEC:-1048576}"

reality_dest_is_shared_frontend() {
    local host="$1" port="${2:-443}"
    REALITY_DEST_SHARED_BY=""
    command -v openssl &>/dev/null || return 1
    # 本地伪装站不出网，不存在被当中继的问题
    reality_dest_is_local "$host" && return 1
    # 没有 -checkhost 就无法核验证书归属，宁可不判也不误报
    openssl x509 -help 2>&1 | grep -q -- "-checkhost" || return 1

    local connect="${host}:${port}"
    [[ "$host" == *:* ]] && connect="[${host}]:${port}"

    local probe out cert hit=1
    for probe in $REALITY_SHARED_FRONTEND_PROBES; do
        [[ "$probe" == "$host" ]] && continue
        out=$(mktemp) || return 1
        if command -v timeout &>/dev/null; then
            timeout 5 openssl s_client -connect "$connect" -servername "$probe" \
                </dev/null >"$out" 2>&1
        else
            openssl s_client -connect "$connect" -servername "$probe" \
                </dev/null >"$out" 2>&1
        fi
        cert=$(mktemp) || { rm -f "$out"; return 1; }
        awk '/-----BEGIN CERTIFICATE-----/{c=1} c{print} /-----END CERTIFICATE-----/{exit}' "$out" > "$cert"
        if grep -q "BEGIN CERTIFICATE" "$cert" \
            && openssl x509 -in "$cert" -noout -checkhost "$probe" >/dev/null 2>&1; then
            REALITY_DEST_SHARED_BY="$probe"
            hit=0
        fi
        rm -f "$out" "$cert"
        (( hit == 0 )) && return 0
    done
    return 1
}

# ── JSON helpers (requires jq) ────────────────────────────────────────────────
jq_get() {
    # jq_get <file> <jq_filter>
    jq -r "$2" "$1" 2>/dev/null
}

# psm_file_replace <file> <file with the new content>: the new content takes
# the file's place atomically (a rename within its directory, never across
# file systems from /tmp), keeping the file's mode and owner.
psm_file_replace() {
    local file="$1" new="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    cat "$new" > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -e "$file" ]]; then
        chmod "$(stat -c %a "$file" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null || true
        chown "$(stat -c %u:%g "$file" 2>/dev/null || echo 0:0)" "$tmp" 2>/dev/null || true
    fi
    mv -f "$tmp" "$file"
}

jq_set() {
    # jq_set <file> <jq_filter_with_value>: rewritten in place, atomically (the
    # temp file is next to it), with the file's own mode and owner
    local file="$1" filter="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if jq "$filter" "$file" > "$tmp" && [[ -s "$tmp" ]]; then
        chmod "$(stat -c %a "$file" 2>/dev/null || echo 600)" "$tmp" 2>/dev/null || true
        chown "$(stat -c %u:%g "$file" 2>/dev/null || echo 0:0)" "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$file"
    else
        rm -f "$tmp"; return 1
    fi
}

# ── Auto-backup wrapper ───────────────────────────────────────────────────────
with_backup() {
    # with_backup <description> <command...>
    local desc="$1"; shift
    # source backup module if available
    [[ -f "$LIB_DIR/backup.sh" ]] && source "$LIB_DIR/backup.sh" && do_quick_backup "$desc"
    "$@"
}

# ── i18n 初始化（放在文件末尾，state_get / 路径就绪之后）──────────────────────
source "$LIB_DIR/i18n.sh" || { echo "PSM: cannot load $LIB_DIR/i18n.sh" >&2; exit 1; }
i18n_init
