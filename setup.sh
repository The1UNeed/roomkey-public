#!/usr/bin/env bash
# roomkey setup — puts the panel on your Cloudflare account and gives you the
# command that installs your first server. Run it from this repository:
#
#   ./setup.sh            guided: asks a few questions, then does everything
#   ./setup.sh --dry-run  everything up to Cloudflare (tools, bundle, config), nothing sent
#
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
    command -v git >/dev/null 2>&1 || { echo "roomkey: git is needed (macOS: xcode-select --install; Debian/Ubuntu: apt install git)" >&2; exit 1; }
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
DRY=0
case "${1:-}" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
n=0
step() { n=$((n + 1)); printf '\n%s[%d] %s%s\n' "$B$C" "$n" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
ask() {   # <var> <question> [default]
    local v
    if [[ -n "${3:-}" ]]; then read -r -p "  $2 [$3]: " v; v="${v:-$3}"; else read -r -p "  $2: " v; fi
    printf -v "$1" '%s' "$v"
}
ask_secret() {   # <var> <question>
    local v
    read -r -s -p "  $2: " v; echo
    printf -v "$1" '%s' "$v"
}
yes_no() {   # <question> <default y|n>
    local v; read -r -p "  $1 [$( [[ $2 == y ]] && echo Y/n || echo y/N )]: " v
    v="${v:-$2}"; [[ "$v" =~ ^[Yy] ]]
}
save() {   # remember an answer (no secrets here)
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    grep -v "^$1=" "$ENV_FILE" >"$ENV_FILE.tmp" 2>/dev/null || true
    printf '%s=%q\n' "$1" "$2" >>"$ENV_FILE.tmp"; mv "$ENV_FILE.tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}
wr() { ( cd "$PANEL" && npx --no-install wrangler "$@" ); }

printf '%sroomkey setup%s — the panel on Cloudflare, then the command for your first server.\n' "$B" "$N"
[[ $DRY == 1 ]] && warn "dry run: nothing is sent to Cloudflare"
# shellcheck source=/dev/null
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

# ── 1. tools ──────────────────────────────────────────────────────────────────
step "Checking the tools on this computer"
missing=()
for t in node npm git openssl curl; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else missing+=("$t"); fi
done
if command -v go >/dev/null 2>&1; then ok "go (psm-agent is built here)"
else note "go: not installed — psm-agent comes from the published release instead"; fi
if (( ${#missing[@]} )); then
    note "Missing: ${missing[*]}"
    command -v brew >/dev/null 2>&1 \
        && note "Install them with:  brew install ${missing[*]/npm/node}" \
        || note "Install them (macOS: https://brew.sh, then brew install ${missing[*]/npm/node}; Debian/Ubuntu: apt install nodejs npm git openssl curl)"
    die "install the missing tools, then run ./setup.sh again"
fi
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' || die "Node.js 20 or newer is needed (node --version says $(node --version))"
if [[ -n "$(git -C "$ROOT" status --porcelain -- stack panel 2>/dev/null)" ]]; then
    warn "stack/ or panel/ has uncommitted changes: servers get PSM as of the last commit ($(git -C "$ROOT" log -1 --format='%h %cs'))"
fi

# ── 2. panel dependencies ─────────────────────────────────────────────────────
step "Installing the panel's dependencies"
if [[ ! -d "$PANEL/node_modules" || "$PANEL/package-lock.json" -nt "$PANEL/node_modules/.package-lock.json" ]]; then
    ( cd "$PANEL" && npm ci --no-audit --no-fund --loglevel=error >/dev/null ) || die "npm ci failed in panel/"
fi
ok "panel/node_modules ($(wr --version 2>/dev/null | tail -1 | tr -d ' ' || echo wrangler))"

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
        ask_secret CLOUDFLARE_API_TOKEN "Cloudflare API token"
        export CLOUDFLARE_API_TOKEN
        wr whoami >/dev/null 2>&1 || die "Cloudflare did not accept that token"
        ok "token accepted (it is not saved)"
    else
        note "A browser window opens: sign in to Cloudflare and allow Wrangler."
        wr login || die "Cloudflare sign-in did not finish"
        ok "signed in"
    fi
else
    ok "already signed in: $(wr whoami 2>/dev/null | grep -iE 'email|associated' | head -1 | sed 's/^[[:space:]]*//' | cut -c1-80)"
fi

# ── 4. questions ──────────────────────────────────────────────────────────────
step "A few questions (remembered for next time)"
note "The panel gets two addresses on your Cloudflare domain: one for you (the admin page),"
note "one for subscriptions and servers. The domain must already be on this Cloudflare account."
ask ADMIN_HOST "Admin page address" "${ADMIN_HOST:-admin.myroom.asia}"
ask SUB_HOST "Subscription address (friends' clients and servers use it)" "${SUB_HOST:-sub.myroom.asia}"
for h in "$ADMIN_HOST" "$SUB_HOST"; do
    [[ "$h" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]] || die "not a host name: $h"
done
[[ "$ADMIN_HOST" != "$SUB_HOST" ]] || die "the admin and subscription addresses must differ"
save ADMIN_HOST "$ADMIN_HOST"; save SUB_HOST "$SUB_HOST"

ADMIN_PASSWORD=""; again=""
if [[ "${DEPLOYED:-}" == 1 ]]; then
    note "Admin password: press Enter to keep the current one."
fi
while :; do
    ask_secret ADMIN_PASSWORD "Admin password (8+ characters)"
    if [[ -z "$ADMIN_PASSWORD" && "${DEPLOYED:-}" == 1 ]]; then ok "keeping the current password"; break; fi
    (( ${#ADMIN_PASSWORD} >= 8 )) || { warn "at least 8 characters"; continue; }
    ask_secret again "Again"
    [[ "$again" == "$ADMIN_PASSWORD" ]] && break
    warn "the two entries differ"
done

CF_DNS_TOKEN=""
note "Optional: a Cloudflare API token with Zone · DNS · Edit on the servers' domain lets the panel"
note "keep each server's host name pointing at its IP. Press Enter to skip (you can add it later)."
ask_secret CF_DNS_TOKEN "DNS token"
if [[ -n "$CF_DNS_TOKEN" ]]; then
    ask CF_ZONE_ID "That zone's ID (Cloudflare → the domain → Overview, right column)" "${CF_ZONE_ID:-}"
    save CF_ZONE_ID "$CF_ZONE_ID"
fi

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
        wr d1 create "$DB_NAME" --location apac >/dev/null || die "could not create the D1 database '$DB_NAME'"
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
ADMIN_PASSWORD="$ADMIN_PASSWORD" CF_DNS_TOKEN="$CF_DNS_TOKEN" KEY="$( (( send_key )) && cat "$KEY_FILE" || true)" node -e '
  const e = process.env, s = {}
  if (e.ADMIN_PASSWORD) s.ADMIN_PASSWORD = e.ADMIN_PASSWORD
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

if [[ -z "$ADMIN_PASSWORD" ]]; then ask_secret ADMIN_PASSWORD "Admin password (to make the install command)"; fi
while :; do
    ask SERVER_NAME "A name for the server (letters, digits, -)" "${SERVER_NAME:-hk1}"
    [[ "$SERVER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,30}$ ]] && break
    warn "letters, digits and -, up to 31"
done
jar=$(mktemp); trap 'rm -f "$jar"' EXIT
login=$(node -e 'process.stdout.write(JSON.stringify({ password: process.argv[1] }))' "$ADMIN_PASSWORD")
curl -s -c "$jar" -H 'content-type: application/json' --data-binary "$login" "$ADMIN_URL/api/login" -o /dev/null -w '%{http_code}' | grep -q 200 \
    || die "the panel did not accept the password"
resp=$(curl -s -b "$jar" -H 'content-type: application/json' --data-binary "{\"name\":\"$SERVER_NAME\"}" "$ADMIN_URL/api/servers")
cmd=$(node -e 'try { process.stdout.write(JSON.parse(process.argv[1]).install_command || "") } catch {}' "$resp")
rm -f "$jar"
[[ "$cmd" == *"/api/agent/install/"* ]] || die "the panel did not make an install command: $resp"
save SERVER_NAME "$SERVER_NAME"

cat <<EOF

${B}${G}Done.${N} The panel: ${B}$ADMIN_URL${N}

${B}Install command for "$SERVER_NAME"${N} — run it as root on the server (works once, for 24 hours):

  $cmd

${Y}Before you run it:${N}
  • Use a ${B}freshly installed${N} VPS (Debian 12/13, Ubuntu 22.04/24.04 or Alpine). roomkey refuses a
    server that already runs other proxies (3x-ui, Xray, Marzban…) or nginx, and changes nothing there.
  • Open ports 80 and 443 in the provider's firewall.
  • Then, in the panel: create nodes on the server and users for your friends.
More servers: the panel's 服务器 page → 添加服务器 (or run ./setup.sh again).
EOF
