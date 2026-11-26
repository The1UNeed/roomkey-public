#!/usr/bin/env bash
# roomkey setup — puts the panel on your Cloudflare account and gives you the
# command that installs your first server, or connects this server to a panel
# you already have. Run it from this repository:
#
#   ./setup.sh            guided: asks what you want, a few questions, then does everything
#   ./setup.sh --join     connect this server to an existing panel (only needs curl)
#   ./setup.sh --yes      answer "yes" to installing tools and updates
#   ./setup.sh --dry-run  a new panel up to Cloudflare (tools, bundle, config), nothing sent
#
# Every question shows its suggestion in [brackets]: press Enter to take it.
#
# What it installs when missing: git, curl, openssl, tar (the system's package
# manager, with sudo when not root) and Node.js 22 (the official build, checked
# against nodejs.org's SHA256SUMS, into ~/.roomkey/node: nothing system-wide).
# Safe to run again (after pulling changes, say): it remembers your answers in
# ~/.roomkey/ and only redeploys. The repository stays private: servers get
# PSM and psm-agent from the panel itself, with a one-time install command.
set -euo pipefail

# Run with curl (bash <(curl -fsSL …/setup.sh)): no checkout here yet, so the
# repository is fetched to ~/roomkey (or updated there) and its own copy runs.
ROOMKEY_GIT="${ROOMKEY_GIT:-https://github.com/The1UNeed/roomkey-public.git}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
if [[ ! -f "$ROOT/panel/package.json" || ! -d "$ROOT/stack" ]]; then
    dest="${ROOMKEY_DIR:-$HOME/roomkey}"
    if ! command -v git >/dev/null 2>&1; then
        echo "roomkey: installing git ..."
        sudo_=""; [[ $EUID -eq 0 ]] || sudo_=sudo
        if command -v apt-get >/dev/null 2>&1; then { $sudo_ apt-get update -qq && $sudo_ env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git ca-certificates; } >/dev/null
        elif command -v dnf >/dev/null 2>&1; then $sudo_ dnf install -y -q git
        elif command -v yum >/dev/null 2>&1; then $sudo_ yum install -y -q git
        elif command -v apk >/dev/null 2>&1; then $sudo_ apk add --no-cache git
        elif command -v brew >/dev/null 2>&1; then brew install git
        else xcode-select --install 2>/dev/null; fi
        command -v git >/dev/null 2>&1 || { echo "roomkey: git could not be installed; install it, then run this again" >&2; exit 1; }
    fi
    if [[ -d "$dest/.git" ]]; then
        echo "roomkey: updating $dest ..."
        git -C "$dest" pull --ff-only -q || { echo "roomkey: could not update $dest (local changes?)" >&2; exit 1; }
    else
        echo "roomkey: downloading roomkey into $dest ..."
        git clone -q --depth 1 "$ROOMKEY_GIT" "$dest" || exit 1
    fi
    if [[ -t 0 ]] || ! ( : </dev/tty ) 2>/dev/null; then exec bash "$dest/setup.sh" "$@"; fi
    exec bash "$dest/setup.sh" "$@" </dev/tty
fi
PANEL="$ROOT/panel"
STATE_DIR="${ROOMKEY_HOME:-$HOME/.roomkey}"
ENV_FILE="$STATE_DIR/setup.env"
KEY_FILE="$STATE_DIR/token-key"
LOCAL_CFG="$PANEL/wrangler.local.jsonc"
LOGIN_FILE="$STATE_DIR/admin-login"   # the admin's username and password (mode 600), for later runs
DRY=0; YES=0; MODE=""
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1; MODE="new" ;;
        --join) MODE="join" ;;
        --yes|-y) YES=1 ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    esac
done

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
n=0
step() { n=$((n + 1)); printf '\n%s[%d] %s%s\n' "$B$C" "$n" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
TTY_INIT=""; [[ -t 0 ]] && TTY_INIT=$(stty -g 2>/dev/null || true)
tty_back() { [[ -n "$TTY_INIT" ]] && stty "$TTY_INIT" 2>/dev/null; true; }
ask() {   # <var> <question> [default]: Enter takes the default
    local v; tty_back
    if [[ -n "${3:-}" ]]; then read -r -p "  $2 [$3]: " v; v="${v:-$3}"; else read -r -p "  $2: " v; fi
    printf -v "$1" '%s' "$v"
}
ask_secret() {   # <var> <question> [letters to show]: typing shows the first few letters, then *
    local v="" c rest show="${3:-0}"
    if [[ ! -t 0 ]]; then read -r v; printf -v "$1" '%s' "$v"; return; fi
    # echo stays off for the whole entry, so pasted text never shows between keystrokes
    TTY_SAVED=$(stty -g); stty -echo
    trap 'stty "$TTY_SAVED"; echo; exit 130' INT
    printf '  %s: ' "$2"
    while IFS= read -r -s -n1 c; do
        case "$c" in
            "") break ;;                                    # Enter
            $'\177' | $'\b')                                # Backspace
                if [[ -n "$v" ]]; then v="${v%?}"; printf '\b \b'; fi ;;
            $'\025')                                        # Ctrl-U: start over
                while [[ -n "$v" ]]; do v="${v%?}"; printf '\b \b'; done ;;
            $'\033') read -r -s -n2 -t 1 rest || true ;;     # arrow keys and the like: ignored
            [[:cntrl:]]) ;;
            *)  v+="$c"
                if (( ${#v} <= show )); then printf '%s' "$c"; else printf '*'; fi ;;
        esac
    done
    stty "$TTY_SAVED"; trap - INT
    echo
    printf -v "$1" '%s' "$v"
}
token_hint() {   # what was typed, for checking against the dashboard: "abcd...wxyz (40 characters)"
    local t="$1"
    (( ${#t} > 8 )) && printf '%s...%s (%d characters)' "${t:0:4}" "${t: -4}" "${#t}" || printf '%d characters' "${#t}"
}
yes_no() {   # <question> <default y|n> (--yes answers yes)
    (( YES )) && { printf '  %s [yes]\n' "$1"; return 0; }
    local v; tty_back; read -r -p "  $1 [$( [[ $2 == y ]] && echo Y/n || echo y/N )]: " v
    v="${v:-$2}"; [[ "$v" =~ ^[Yy] ]]
}

# ── installing what is missing ────────────────────────────────────────────────
SUDO=""
if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO=sudo; fi
can_root() { [[ $EUID -eq 0 || -n "$SUDO" ]]; }
pkg_mgr() {
    local m
    for m in apt-get dnf yum apk pacman zypper brew; do command -v "$m" >/dev/null 2>&1 && { echo "$m"; return; }; done
}
# the package managers' own chatter goes to ~/.roomkey/setup.log (errors still show)
LOG="$STATE_DIR/setup.log"
quiet() { mkdir -p "$STATE_DIR"; "$@" >>"$LOG"; }
pkg_refresh() { quiet pkg_refresh_; }
pkg_upgrade() { quiet pkg_upgrade_; }
pkg_install() { quiet pkg_install_ "$@"; }
pkg_refresh_() {
    case "$(pkg_mgr)" in
        apt-get) $SUDO apt-get update -qq ;;
        apk) $SUDO apk update -q ;;
        pacman) $SUDO pacman -Sy --noconfirm >/dev/null ;;
        brew) brew update -q >/dev/null || true ;;
    esac
}
pkg_upgrade_() {
    case "$(pkg_mgr)" in
        apt-get) $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade ;;
        dnf) $SUDO dnf -y -q upgrade ;;
        yum) $SUDO yum -y -q update ;;
        apk) $SUDO apk upgrade --no-cache -q ;;
        pacman) $SUDO pacman -Su --noconfirm ;;
        zypper) $SUDO zypper -q -n update ;;
        brew) brew upgrade -q || true ;;
    esac
}
pkg_install_() {   # <packages…>
    case "$(pkg_mgr)" in
        apt-get) $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf) $SUDO dnf install -y -q "$@" ;;
        yum) $SUDO yum install -y -q "$@" ;;
        apk) $SUDO apk add --no-cache -q "$@" ;;
        pacman) $SUDO pacman -S --noconfirm --needed "$@" ;;
        zypper) $SUDO zypper -q -n install "$@" ;;
        brew) brew install "$@" ;;
        *) return 1 ;;
    esac
}
node_ok() {
    command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
        && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' 2>/dev/null
}
# Node.js 22, the official build for this system, checked against nodejs.org's
# SHA256SUMS, into ~/.roomkey/node (Alpine, musl: its own nodejs package).
install_node() {
    if [[ -f /etc/alpine-release ]]; then pkg_install nodejs npm; return; fi
    local os arch base sums file tmp want got
    case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) return 1 ;; esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; armv7l) arch=armv7l ;;
        *) warn "no official Node.js build for $(uname -m)"; return 1 ;;
    esac
    base="https://nodejs.org/dist/latest-v22.x"
    sums=$(curl -fsSL --retry 3 "$base/SHASUMS256.txt") || return 1
    file=$(awk -v s="-$os-$arch.tar.gz" 'substr($2, length($2) - length(s) + 1) == s { print $2; exit }' <<<"$sums")
    [[ -n "$file" ]] || return 1
    tmp=$(mktemp -d)
    curl -fsSL --retry 3 -o "$tmp/$file" "$base/$file" || { rm -rf "$tmp"; return 1; }
    want=$(awk -v f="$file" '$2 == f { print $1 }' <<<"$sums")
    got=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum "$tmp/$file" || shasum -a 256 "$tmp/$file"; } | awk '{ print $1 }')
    [[ -n "$want" && "$want" == "$got" ]] || { rm -rf "$tmp"; warn "the Node.js download does not match its checksum"; return 1; }
    rm -rf "$STATE_DIR/node"; mkdir -p "$STATE_DIR/node"
    tar -xzf "$tmp/$file" -C "$STATE_DIR/node" --strip-components 1 || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    export PATH="$STATE_DIR/node/bin:$PATH"
}
save() {   # remember an answer (no secrets here)
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    grep -v "^$1=" "$ENV_FILE" >"$ENV_FILE.tmp" 2>/dev/null || true
    printf '%s=%q\n' "$1" "$2" >>"$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
wr() { ( cd "$PANEL" && npx --no-install wrangler "$@" ) </dev/null; }   # never waits on a question
export WRANGLER_SEND_METRICS=false

rand_text() {   # <length> [characters, as tr knows them]: random text from /dev/urandom
    head -c 192 /dev/urandom | base64 | tr -dc "${2:-A-Za-z0-9}" | cut -c "1-$1"
}
json_str() { local t=$1; t=${t//\\/\\\\}; t=${t//\"/\\\"}; printf '"%s"' "$t"; }
json_field() {   # <name> <json>: the first string field of that name (no quotes inside it)
    sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -1
}
panel_url() {   # <what was typed>: https://host[:port] (http:// only when typed so), or nothing
    local u=${1%%[[:space:]]}
    [[ "$u" == http://* || "$u" == https://* ]] || u="https://$u"
    u=$(sed -E 's#^(https?://[^/]+).*#\1#' <<<"$u")
    [[ "$u" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] && printf '%s' "$u"
}
default_server_name() {   # this machine's host name, as the panel takes it; else server-xxxx
    local h; h=$(hostname 2>/dev/null | cut -d. -f1 | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9-' | sed 's/^-*//' | cut -c1-31)
    [[ "$h" =~ ^[a-z0-9][a-z0-9-]*$ && "$h" != localhost ]] && printf '%s' "$h" || printf 'server-%s' "$(rand_text 4 a-z0-9)"
}
# Signs in to a panel and adds a server: INSTALL_CMD on success, PANEL_ERR (and 1) when not.
# The password goes to curl on stdin, never on its command line.
panel_install_command() {   # <admin url> <username> <password> <server name>
    local url=$1 jar code resp
    INSTALL_CMD=""; PANEL_ERR=""
    jar=$(mktemp)
    code=$(printf '{"username":%s,"password":%s}' "$(json_str "$2")" "$(json_str "$3")" |
        curl -sS -c "$jar" -o /dev/null -w '%{http_code}' --max-time 20 -H 'content-type: application/json' \
            --data-binary @- "$url/api/login" 2>/dev/null) || true
    case "$code" in
        200) ;;
        401) PANEL_ERR="the panel did not accept that username and password" ;;
        429) PANEL_ERR="too many failed sign-ins from this address: wait 15 minutes" ;;
        404) PANEL_ERR="$url is not a roomkey admin page (use the admin address, not the subscription one)" ;;
        503) PANEL_ERR="that panel has no admin password set yet" ;;
        *)   PANEL_ERR="could not reach $url (HTTP ${code:-000})" ;;
    esac
    if [[ -z "$PANEL_ERR" ]]; then
        resp=$(curl -sS -b "$jar" --max-time 20 -H 'content-type: application/json' \
            --data-binary "{\"name\":$(json_str "$4")}" "$url/api/servers" 2>&1) || true
        INSTALL_CMD=$(json_field install_command "$resp")
        [[ "$INSTALL_CMD" == *"/api/agent/install/"* || "$INSTALL_CMD" == *"bootstrap"* ]] ||
            { INSTALL_CMD=""; PANEL_ERR="the panel did not make an install command: $(json_field message "$resp" || true)"; }
    fi
    rm -f "$jar"
    [[ -n "$INSTALL_CMD" ]]
}
install_here() {   # runs INSTALL_CMD as root; says what happened
    note "roomkey first checks this server and refuses (changing nothing) if it already runs other"
    note "proxies (3x-ui, Xray, Marzban…) or nginx."
    if $SUDO sh -c "$INSTALL_CMD"; then return 0; fi
    warn "the install above did not finish; the server was left as the check found it"
    return 1
}

# ── connecting this server to a panel you already have ──────────────────────
join_existing_panel() {
    local input url user="" pass name tries=0
    step "Connecting this server to your roomkey panel"
    [[ "$(uname -s)" == Linux ]] || die "run this on the Linux server you want to connect"
    can_root || die "connecting a server needs root (or sudo)"
    if ! command -v curl >/dev/null 2>&1; then
        note "Installing curl …"
        pkg_refresh || true
        pkg_install curl ca-certificates || pkg_install curl || die "curl could not be installed"
    fi
    note "You need your panel's admin address and sign-in, or an install command copied from the"
    note "panel (服务器 → 添加服务器). Press Enter to take a suggestion in [brackets]."
    ask input "Admin address, or paste an install command" "${ADMIN_HOST:-}"
    if [[ "$input" == *"/api/agent/install/"* || "$input" == *"bootstrap.sh"*"--join"* ]]; then
        INSTALL_CMD=$input
    else
        url=$(panel_url "$input") || die "not an address: $input"
        name=$(default_server_name)
        while :; do
            ask user "Admin username (Enter if your panel has none)" "${user:-${ADMIN_USER:-}}"
            ask_secret pass "Admin password" 0
            while :; do
                ask name "A name for this server (letters, digits, -)" "$name"
                [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,30}$ ]] && break
                warn "letters, digits and -, up to 31"
            done
            panel_install_command "$url" "$user" "$pass" "$name" && break
            warn "$PANEL_ERR"
            (( ++tries < 3 )) || die "could not get an install command from $url"
            [[ "$PANEL_ERR" == *"exists"* ]] && note "That name is taken: pick another."
        done
        ok "the panel added \"$name\""
    fi
    install_here || die "fix what it names (or use a freshly installed VPS), then run this again"
    printf '\n%s%sDone.%s This server is connected: open %s and create its nodes.\n' "$B" "$G" "$N" "${url:-your panel}"
}

[[ -x "$STATE_DIR/node/bin/node" ]] && export PATH="$STATE_DIR/node/bin:$PATH"
export NPM_CONFIG_UPDATE_NOTIFIER=false NPM_CONFIG_FUND=false   # no npm adverts in the middle of setup
printf '%sroomkey setup%s — your panel on Cloudflare, and your servers.\n' "$B" "$N"
[[ $DRY == 1 ]] && warn "dry run: nothing is sent to Cloudflare"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] && export CLOUDFLARE_ACCOUNT_ID

if [[ -z "$MODE" ]]; then
    note ""
    note "What would you like to do?"
    note "  1) Set up a new roomkey panel on your Cloudflare account"
    note "  2) Connect this server to a roomkey panel you already have"
    note "Every question shows its suggestion in [brackets]: press Enter to take it."
    choice=""
    while :; do
        ask choice "Your choice, 1 or 2" 1
        case "$choice" in 1) MODE="new"; break ;; 2) MODE="join"; break ;; esac
        warn "type 1 or 2"
    done
fi
if [[ "$MODE" == join ]]; then join_existing_panel; exit 0; fi

# ── 1. tools ──────────────────────────────────────────────────────────────────
step "Checking the tools on this computer"
missing=()
for t in git curl openssl tar gzip; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else missing+=("$t"); fi
done
if node_ok; then ok "node $(node --version), npm $(npm --version)"
elif command -v node >/dev/null 2>&1; then note "node $(node --version) is older than 20: Node.js 22 will be installed for roomkey"
else note "node: not installed"; fi
if command -v go >/dev/null 2>&1; then ok "go (psm-agent is built here)"
else note "go: not needed — psm-agent comes from the published release"; fi

if (( ${#missing[@]} )) || ! node_ok; then
    note ""
    (( ${#missing[@]} )) && note "To install: ${missing[*]} (with $(pkg_mgr || echo 'no package manager')${SUDO:+, through sudo})"
    node_ok || note "To install: Node.js 22 (official build, checksum-checked, into $STATE_DIR/node)"
    yes_no "Install them now?" y || die "roomkey needs them: install them, then run ./setup.sh again"
    if (( ${#missing[@]} )); then
        can_root || die "installing ${missing[*]} needs root (or sudo): run this as root, or install them yourself"
        [[ -n "$(pkg_mgr)" ]] || die "no package manager found: install ${missing[*]} yourself"
        pkgs=("${missing[@]}")
        [[ "$(pkg_mgr)" == apt-get ]] && pkgs+=(ca-certificates)
        pkg_refresh || warn "the package list could not be refreshed"
        pkg_install "${pkgs[@]}" || die "installing ${missing[*]} failed (above)"
        for t in "${missing[@]}"; do command -v "$t" >/dev/null 2>&1 || die "$t is still missing"; done
        ok "installed ${missing[*]}"
    fi
    if ! node_ok; then
        note "Downloading Node.js 22 …"
        install_node || die "Node.js could not be installed (install Node.js 20+ yourself: https://nodejs.org)"
        node_ok || die "Node.js is still not usable"
        ok "node $(node --version), npm $(npm --version) in $STATE_DIR/node"
    fi
fi

# system updates, when this is a machine you look after as root (a server)
if [[ "$(uname -s)" == Linux ]] && can_root && [[ -n "$(pkg_mgr)" && "${UPDATED_AT:-}" != "$(date +%Y-%m-%d)" ]]; then
    if yes_no "Install this system's pending updates first ($(pkg_mgr) upgrade)?" y; then
        note "Updating the system (this can take a few minutes; details in $LOG) …"
        { pkg_refresh && pkg_upgrade; } || warn "some updates did not install (above); setup goes on"
        save UPDATED_AT "$(date +%Y-%m-%d)"
        ok "system up to date"
        [[ -f /var/run/reboot-required ]] && warn "the system asks for a reboot to finish its updates (after setup: reboot)"
    fi
fi
if [[ -n "$(git -C "$ROOT" status --porcelain -- stack panel 2>/dev/null)" ]]; then
    warn "stack/ or panel/ has uncommitted changes: servers get PSM as of the last commit ($(git -C "$ROOT" log -1 --format='%h %cs'))"
fi

# ── 2. panel dependencies ─────────────────────────────────────────────────────
step "Installing the panel's dependencies"
if [[ ! -d "$PANEL/node_modules" || "$PANEL/package-lock.json" -nt "$PANEL/node_modules/.package-lock.json" ]]; then
    ( cd "$PANEL" && npm ci --no-audit --no-fund --loglevel=error >/dev/null ) || die "npm ci failed in panel/"
fi
ok "panel/node_modules ($(wr --version 2>/dev/null | tail -1 | tr -d ' ' || echo wrangler))"

cf_api() {   # <path>: GET from the Cloudflare API with the token (kept out of the process list)
    curl -sS ${CF_IPV4:+-4} --max-time 20 -H @<(printf 'Authorization: Bearer %s\n' "$CLOUDFLARE_API_TOKEN") \
        "https://api.cloudflare.com/client/v4$1" 2>&1
}
cf_json() {   # <node expression over j, the parsed answer>: prints its lines; "!reason" when Cloudflare said no
    node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
          let j
          try { j = JSON.parse(s) } catch { return console.log(`!~could not reach api.cloudflare.com: ${s.trim().slice(0, 200)}`) }
          if (!j.success) return console.log("!" + ((j.errors ?? []).map((e) => `${e.message} (code ${e.code})`).join("; ") || "no reason given"))
          const out = eval(process.argv[1]); if (out) console.log(out) })' "$1"
}
node_reaches_cf() {   # can Node (what Wrangler runs on) use the token? prints the reason when not
    node -e '
        fetch("https://api.cloudflare.com/client/v4/user/tokens/verify", {
          headers: { Authorization: `Bearer ${process.env.CLOUDFLARE_API_TOKEN}` }, signal: AbortSignal.timeout(15000) })
          .then((r) => r.json())
          .then((j) => { if (!j.success) { console.log(JSON.stringify(j.errors)); process.exit(1) } })
          .catch((e) => { const c = e.cause ?? e; console.log(`${c.code ?? c.name ?? ""} ${c.message ?? e.message}`.trim()); process.exit(1) })'
}
zone_of() {   # <host>: "<zone id> <zone name>" of the zone holding it, as CF_DNS_TOKEN sees it; "!why" when not
    local h=$1 r
    while [[ "$h" == *.* ]]; do
        r=$( { CLOUDFLARE_API_TOKEN="$CF_DNS_TOKEN" cf_api "/zones?name=$h" || true; } |
            cf_json '(j.result ?? [])[0] ? `${j.result[0].id} ${j.result[0].name}` : ""')
        if [[ -n "$r" ]]; then printf '%s' "$r"; return; fi
        h=${h#*.}
    done
    printf '!this token sees no zone for %s' "$1"
}
cf_says() {   # <"!reason" from cf_json>
    if [[ "$1" == '!~'* ]]; then warn "${1#!~}"; else warn "Cloudflare says: ${1#!}"; fi
}
use_ipv4() {   # from here on, curl and Node (so Wrangler) reach Cloudflare over IPv4 only
    export CF_IPV4=1 NODE_OPTIONS="--dns-result-order=ipv4first --no-network-family-autoselection ${NODE_OPTIONS:-}"
}
cf_token_ok() {   # checks CLOUDFLARE_API_TOKEN and fills $accounts ("<id> <name>" lines); on a problem, says why
    local verify out v4 where
    if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then warn "nothing was pasted"; return 1; fi
    # Cloudflare's own verdict on the token: active, expired, disabled, invalid…
    verify=$( { cf_api /user/tokens/verify || true; } | cf_json 'j.result?.status')
    # a token limited to some IP addresses ("Client IP Address Filtering"): this server may have
    # reached Cloudflare over IPv6 while the token lists its IPv4 address, so try that first
    if [[ "$verify" == *"from location"* ]]; then
        where=$(sed -n 's/.*from location: \([^ ]*\).*/\1/p' <<<"$verify")
        if [[ -z "${CF_IPV4:-}" ]]; then
            v4=$( { CF_IPV4=1 cf_api /user/tokens/verify || true; } | cf_json 'j.result?.status')
            if [[ "$v4" != *"from location"* && "$v4" != *"could not reach"* ]]; then
                use_ipv4
                note "This token only works from some IP addresses, and this server's IPv6 address ($where) is"
                note "not one of them; its IPv4 address is. roomkey talks to Cloudflare over IPv4 from here on."
                cf_token_ok; return
            fi
        fi
        warn "this token only works from some IP addresses, and this server ($where) is not one of them."
        note "Fix: Cloudflare → API Tokens → the token → Edit → Client IP Address Filtering: add this"
        note "server's addresses (or remove the filter). Or make a token without IP filtering."
        return 1
    fi
    if [[ "$verify" == active ]]; then
        accounts=$( { cf_api '/accounts?per_page=50' || true; } | cf_json 'j.result.map((a) => `${a.id} ${a.name}`).join("\n")')
        if [[ "$accounts" == '!'* ]]; then cf_says "$accounts"; return 1; fi
        if [[ -z "$accounts" ]]; then
            warn "the token works, but it reaches no Cloudflare account."
            note "Edit the token: under Account Resources, include your account."
            return 1
        fi
        # curl got through; Wrangler runs on Node, which connects differently (no IPv4 fallback, no curl proxy settings)
        if ! out=$(node_reaches_cf 2>&1); then
            if NODE_OPTIONS="--dns-result-order=ipv4first ${NODE_OPTIONS:-}" node_reaches_cf >/dev/null 2>&1; then
                export NODE_OPTIONS="--dns-result-order=ipv4first ${NODE_OPTIONS:-}"
                note "Node could not reach Cloudflare over IPv6 on this server; it uses IPv4 from here on."
            else
                warn "the token is valid (curl reached Cloudflare), but Node, which Wrangler runs on, could not: $out"
                note "Something on this server (a proxy, firewall or DNS change) treats Node's traffic differently."
                [[ -n "${https_proxy:-}${HTTPS_PROXY:-}${http_proxy:-}${HTTP_PROXY:-}" ]] &&
                    note "A proxy is set in this shell (https_proxy/HTTPS_PROXY); try again without it, or with HTTPS_PROXY in capitals."
                return 1
            fi
        fi
        return 0
    fi
    if [[ "$verify" != '!'* ]]; then warn "Cloudflare says the token is ${verify:-not usable}"; return 1; fi
    if [[ "$verify" != *"code 1000"* ]]; then cf_says "$verify"; return 1; fi
    # "invalid" here can also mean an account-owned token, which only Wrangler can check
    if out=$(wr whoami --json 2>/dev/null); then
        accounts=$(node -e '
            try { for (const a of JSON.parse(process.argv[1]).accounts ?? []) console.log(`${a.id} ${a.name}`) } catch {}' "$out")
        [[ -n "$accounts" && "$accounts" != '!'* ]] && return 0
    fi
    cf_says "$verify"
    note "Copy the token again with the copy button next to it; a missing or extra letter makes it invalid."
    return 1
}

# ── 3. Cloudflare account ─────────────────────────────────────────────────────
step "Signing in to Cloudflare"
if [[ $DRY == 1 ]]; then
    note "(skipped: dry run)"
elif [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] && wr whoami 2>&1 | grep -qi 'not authenticated'; then
    if [[ -n "${SSH_CONNECTION:-}" || ( "$(uname -s)" == Linux && -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ) ]]; then
        # no browser here (a server over SSH): an API token instead
        note "No browser here: use a Cloudflare API token. Create one at"
        note "  https://dash.cloudflare.com/profile/api-tokens → Create Token → \"Edit Cloudflare Workers\" template,"
        note "  then add: Account · D1 · Edit, and Zone · DNS · Edit for your domain."
        tries=0
        while :; do
            ask_secret CLOUDFLARE_API_TOKEN "Cloudflare API token (paste it)" 4
            note "got $(token_hint "$CLOUDFLARE_API_TOKEN")"
            export CLOUDFLARE_API_TOKEN
            cf_token_ok && break
            (( ++tries < 3 )) || die "Cloudflare did not accept the token (the reason is above)"
            note "Paste it again (or a new token), or press Ctrl-C to stop."
        done
        ok "token accepted (it is not saved)"
        # which account gets the panel (named up front, so Wrangler needs no extra permissions to find it)
        if (( $(grep -c . <<<"$accounts") == 1 )); then
            CLOUDFLARE_ACCOUNT_ID=${accounts%% *}
            note "account: ${accounts#* } (${CLOUDFLARE_ACCOUNT_ID})"
        else
            note "This token reaches several Cloudflare accounts:"
            while read -r id name; do note "  $id  $name"; done <<<"$accounts"
            ask CLOUDFLARE_ACCOUNT_ID "Account ID for the panel" "${CLOUDFLARE_ACCOUNT_ID:-$(head -1 <<<"$accounts" | cut -d' ' -f1)}"
        fi
        export CLOUDFLARE_ACCOUNT_ID; save CLOUDFLARE_ACCOUNT_ID "$CLOUDFLARE_ACCOUNT_ID"
    else
        note "A browser window opens: sign in to Cloudflare and allow Wrangler."
        ( cd "$PANEL" && npx --no-install wrangler login ) || die "Cloudflare sign-in did not finish"
        ok "signed in"
    fi
else
    ok "already signed in: $(wr whoami 2>/dev/null | grep -iE 'email|associated' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)"
fi

# ── 4. questions ──────────────────────────────────────────────────────────────
step "A few questions (remembered for next time)"
note "The panel gets two addresses on your Cloudflare domain: one for you (the admin page),"
note "one for subscriptions and servers. The domain must already be on this Cloudflare account."
note "Press Enter to take the suggestion in [brackets]."
ask ADMIN_HOST "Admin page address" "${ADMIN_HOST:-admin.myroom.asia}"
ask SUB_HOST "Subscription address (friends' clients and servers use it)" "${SUB_HOST:-sub.myroom.asia}"
for h in "$ADMIN_HOST" "$SUB_HOST"; do
    [[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "not a host name: $h"
done
[[ "$ADMIN_HOST" != "$SUB_HOST" ]] || die "the admin and subscription addresses must differ"
save ADMIN_HOST "$ADMIN_HOST"; save SUB_HOST "$SUB_HOST"

# the admin's sign-in: a username, and a password (made for you when you press Enter)
saved_pw=""; [[ -s "$LOGIN_FILE" ]] && saved_pw=$(sed -n 's/^password: //p' "$LOGIN_FILE")
while :; do
    ask ADMIN_USER "Admin username" "${ADMIN_USER:-admin-$(rand_text 4 a-z0-9)}"
    [[ "$ADMIN_USER" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,31}$ ]] && break
    warn "3 to 32 letters, digits, dots, - or _"
    ADMIN_USER=""
done
save ADMIN_USER "$ADMIN_USER"
ADMIN_PASSWORD=""; again=""; PW_MADE=0
if [[ -n "$saved_pw" || "${DEPLOYED:-}" == 1 ]]; then keep=keep; note "Admin password: press Enter to keep the current one, or type a new one (8+ characters)."
else keep=random; note "Admin password: press Enter for a strong random one, or type your own (8+ characters)."; fi
while :; do
    ask_secret ADMIN_PASSWORD "Admin password [Enter = $keep]" 0
    if [[ -z "$ADMIN_PASSWORD" ]]; then
        if [[ -n "$saved_pw" ]]; then ADMIN_PASSWORD=$saved_pw; ok "keeping the current password"
        elif [[ "${DEPLOYED:-}" == 1 ]]; then ok "keeping the current password"
        else ADMIN_PASSWORD=$(rand_text 20); PW_MADE=1; ok "made a random 20-character password (shown at the end)"; fi
        break
    fi
    (( ${#ADMIN_PASSWORD} >= 8 )) || { warn "at least 8 characters"; continue; }
    ask_secret again "Again" 0
    [[ "$again" == "$ADMIN_PASSWORD" ]] && break
    warn "the two entries differ"
done
if [[ -n "$ADMIN_PASSWORD" ]]; then
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    ( umask 077; printf 'admin page: https://%s\nusername: %s\npassword: %s\n' "$ADMIN_HOST" "$ADMIN_USER" "$ADMIN_PASSWORD" >"$LOGIN_FILE" )
fi

CF_DNS_TOKEN=""
note "Optional: a Cloudflare API token with Zone · DNS · Edit on the servers' domain lets the panel"
note "keep each server's host name pointing at its IP. You can add it later."
while :; do
    ask_secret CF_DNS_TOKEN "DNS token [Enter = skip]" 4
    if [[ -z "$CF_DNS_TOKEN" ]]; then note "skipped: no DNS token"; break; fi
    note "got $(token_hint "$CF_DNS_TOKEN")"
    if [[ $DRY == 1 ]]; then   # nothing goes to Cloudflare in a dry run: the zone is asked for
        ask CF_ZONE_ID "That zone's ID (Cloudflare → the domain → Overview, right column)" "${CF_ZONE_ID:-}"
        break
    fi
    zone=$(zone_of "$SUB_HOST")
    if [[ -n "$zone" && "$zone" != '!'* ]]; then
        CF_ZONE_ID=${zone%% *}; ok "zone ${zone#* } ($CF_ZONE_ID), found with that token"; break
    fi
    cf_says "${zone:-!no zone}"
    note "The token needs Zone · DNS · Edit on the zone of $SUB_HOST. Paste another, or press Enter to skip."
    CF_DNS_TOKEN=""
done
[[ -n "$CF_DNS_TOKEN" ]] && save CF_ZONE_ID "$CF_ZONE_ID"

# ── 5. what servers download ──────────────────────────────────────────────────
step "Building what servers download from the panel (PSM + psm-agent)"
( cd "$PANEL" && bash scripts/bundle.sh >/dev/null ) || die "building the bundle failed (see above)"
ok "bundle: $(git -C "$ROOT" log -1 --format='%h %cs'), psm-agent for amd64 / arm64 / armv7"
( cd "$PANEL" && npm run -s build >/dev/null ) || die "building the panel failed"
ok "panel built, bundle included"

# ── 6. database and configuration ─────────────────────────────────────────────
step "Database and configuration"
DB_NAME="${DB_NAME:-roomkey}"
if [[ $DRY == 1 ]]; then
    DB_ID="${DB_ID:-00000000-0000-0000-0000-000000000000}"
    note "(dry run: the D1 database '$DB_NAME' would be created if missing)"
else
    DB_ID=$(wr d1 list --json 2>/dev/null | node -e '
        let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
          try { const db = JSON.parse(s).find((d) => d.name === process.argv[1]); process.stdout.write(db ? db.uuid : "") } catch {} })' "$DB_NAME")
    if [[ -z "$DB_ID" ]]; then
        wr d1 create "$DB_NAME" --location apac --update-config=false >/dev/null || die "could not create the D1 database '$DB_NAME'"
        DB_ID=$(wr d1 list --json | node -e '
            let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
              const db = JSON.parse(s).find((d) => d.name === process.argv[1]); process.stdout.write(db ? db.uuid : "") })' "$DB_NAME")
        [[ -n "$DB_ID" ]] || die "the new database did not show up"
        ok "created the D1 database '$DB_NAME' (new and empty)"
    else
        ok "D1 database '$DB_NAME' is there"
    fi
fi
save DB_NAME "$DB_NAME"
# the deploy's own config: wrangler.jsonc plus your addresses and database
ADMIN_HOST="$ADMIN_HOST" SUB_HOST="$SUB_HOST" DB_NAME="$DB_NAME" DB_ID="$DB_ID" CF_ZONE_ID="${CF_ZONE_ID:-}" \
node -e '
  const fs = require("fs")
  const src = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => !/^\s*\/\//.test(l)).join("\n")
  const c = JSON.parse(src), e = process.env
  c.name = "roomkey"
  c.vars = { ...c.vars, ADMIN_HOSTS: e.ADMIN_HOST, PANEL_URL: `https://${e.SUB_HOST}`, ...(e.CF_ZONE_ID ? { CF_ZONE_ID: e.CF_ZONE_ID } : {}) }
  c.d1_databases = [{ ...c.d1_databases[0], database_name: e.DB_NAME, database_id: e.DB_ID }]
  c.routes = [{ pattern: e.ADMIN_HOST, custom_domain: true }, { pattern: e.SUB_HOST, custom_domain: true }]
  fs.writeFileSync(process.argv[2], "// written by setup.sh (not committed): wrangler.jsonc with your addresses and database\n" + JSON.stringify(c, null, 2) + "\n")
' "$PANEL/wrangler.jsonc" "$LOCAL_CFG"
ok "panel/wrangler.local.jsonc: $ADMIN_HOST (admin), $SUB_HOST (subscriptions, servers)"

# the key that encrypts the panel's secrets: made once, kept here and on Cloudflare
send_key=0
if [[ -s "$KEY_FILE" ]]; then
    send_key=1
elif [[ $DRY == 0 && "${DEPLOYED:-}" == 1 ]] && wr secret list -c wrangler.local.jsonc 2>/dev/null | grep -q '"TOKEN_KEY"'; then
    warn "the panel already has a TOKEN_KEY that is not in $KEY_FILE: keeping it as it is"
else
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    ( umask 077; openssl rand -base64 32 >"$KEY_FILE" )
    send_key=1
    ok "made the encryption key: $KEY_FILE"
    warn "back this file up somewhere safe: without it, a restored panel cannot read its own data"
fi

# ── 7. deploy ─────────────────────────────────────────────────────────────────
step "Deploying the panel to Cloudflare"
secrets=$(mktemp); chmod 600 "$secrets"; trap 'rm -f "$secrets"' EXIT
ADMIN_PASSWORD="$ADMIN_PASSWORD" ADMIN_USERNAME="$ADMIN_USER" CF_DNS_TOKEN="$CF_DNS_TOKEN" KEY="$( (( send_key )) && cat "$KEY_FILE" || true)" node -e '
  const e = process.env, s = {}
  if (e.ADMIN_PASSWORD) s.ADMIN_PASSWORD = e.ADMIN_PASSWORD
  if (e.ADMIN_USERNAME) s.ADMIN_USERNAME = e.ADMIN_USERNAME
  if (e.KEY) s.TOKEN_KEY = e.KEY.trim()
  if (e.CF_DNS_TOKEN) s.CF_DNS_TOKEN = e.CF_DNS_TOKEN
  require("fs").writeFileSync(process.argv[1], JSON.stringify(s))
' "$secrets"
if [[ $DRY == 1 ]]; then
    note "(dry run) would run: npx wrangler deploy -c panel/wrangler.local.jsonc --secrets-file <temporary file>"
    note "the secrets file would set: $(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1]))).join(", ") || "nothing")' "$secrets")"
else
    wr deploy -c wrangler.local.jsonc --secrets-file "$secrets" || die "the deploy failed (above). A custom domain needs its domain on this Cloudflare account."
    save DEPLOYED 1
    ok "deployed"
fi
rm -f "$secrets"

# ── 8. first server ───────────────────────────────────────────────────────────
step "Your first server"
ADMIN_URL="https://$ADMIN_HOST"
if [[ $DRY == 1 ]]; then
    note "(dry run) the panel would answer at $ADMIN_URL; then this step makes the install command"
    exit 0
fi
note "Waiting for $ADMIN_URL to answer (a new address takes a minute or two to get its certificate)…"
up=0
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$ADMIN_URL/api/session" || true)
    [[ "$code" == 200 ]] && { up=1; break; }
    sleep 5
done
(( up )) || die "$ADMIN_URL does not answer yet. Wait a few minutes and open it in a browser; the panel's 服务器 page makes install commands."
ok "the panel answers at $ADMIN_URL"

summary() {   # the panel and how to sign in
    printf '\n%s%sDone.%s Your roomkey panel is live.\n\n' "$B" "$G" "$N"
    printf '  Admin page   %s%s%s\n' "$B" "$ADMIN_URL" "$N"
    printf '  Username     %s\n' "$ADMIN_USER"
    if (( PW_MADE )); then printf '  Password     %s%s%s   (made for you: save it in your password manager)\n' "$B" "$ADMIN_PASSWORD" "$N"
    else printf '  Password     the one you chose\n'; fi
    [[ -s "$LOGIN_FILE" ]] && printf '  Saved in     %s (only you can read it)\n' "$LOGIN_FILE"
    printf '  Friends and servers use https://%s\n' "$SUB_HOST"
    printf '  Back up      %s (the panel'"'"'s encryption key)\n' "$KEY_FILE"
}

if [[ -z "$ADMIN_PASSWORD" ]]; then ask_secret ADMIN_PASSWORD "Admin password (to make the install command)" 0; fi
here=0; [[ "$(uname -s)" == Linux ]] && can_root && here=1
default_name=${SERVER_NAME:-hk1}; (( here )) && default_name=${SERVER_NAME:-$(default_server_name)}
tries=0
while :; do
    ask SERVER_NAME "A name for the server (letters, digits, -)" "$default_name"
    [[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,30}$ ]] || { warn "letters, digits and -, up to 31"; continue; }
    panel_install_command "$ADMIN_URL" "$ADMIN_USER" "$ADMIN_PASSWORD" "$SERVER_NAME" && break
    warn "$PANEL_ERR"
    (( ++tries < 3 )) || die "the panel did not make an install command (above)"
    [[ "$PANEL_ERR" == *"username and password"* ]] && ask_secret ADMIN_PASSWORD "Admin password" 0
done
save SERVER_NAME "$SERVER_NAME"

# on a Linux server: install roomkey right here too
if (( here )); then
    note ""
    note "This computer is a Linux server: it can become \"$SERVER_NAME\" now."
    if yes_no "Install roomkey on this server now?" y; then
        if install_here; then
            summary
            printf '\n  This server is "%s" in the panel: open the admin page and create its nodes.\n' "$SERVER_NAME"
            exit 0
        fi
        note "Fix what it names (or use a freshly installed VPS) and run the command below there."
    fi
fi

summary
cat <<EOF

${B}Install command for "$SERVER_NAME"${N} — run it as root on the server (works once, for 24 hours):

  $INSTALL_CMD

${Y}Before you run it:${N}
  • Use a ${B}freshly installed${N} VPS (Debian 12/13, Ubuntu 22.04/24.04 or Alpine). roomkey refuses a
    server that already runs other proxies (3x-ui, Xray, Marzban…) or nginx, and changes nothing there.
  • Open ports 80 and 443 in the provider's firewall.
  • Then, in the panel: create nodes on the server and users for your friends.
More servers: the panel's 服务器 page → 添加服务器, or on that server run this setup and choose 2.
EOF
