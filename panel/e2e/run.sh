#!/usr/bin/env bash
# The panel end to end: a fresh local panel (empty local D1, e2e/state), a mock
# of Cloudflare's and Telegram's APIs, then e2e.mjs (a simulated psm-agent and
# the admin API), then everything is stopped. `npm run e2e`.
# Ports: E2E_PORT (58384) for the panel, E2E_MOCK_PORT (58385) for the mock.
set -u
E2E="$(cd "$(dirname "$0")" && pwd)"
PANEL="$(cd "$E2E/.." && pwd)"
PORT="${E2E_PORT:-58384}"; MOCK_PORT="${E2E_MOCK_PORT:-58385}"
rm -rf "$E2E/state"
E2E_MOCK_PORT="$MOCK_PORT" node "$E2E/mock.mjs" & mock=$!
( cd "$PANEL" && NO_BUNDLE=1 npm run build >/dev/null 2>&1 && exec npx wrangler dev --local --port "$PORT" --persist-to "$E2E/state" --test-scheduled \
    --var ADMIN_PASSWORD:roomkey-e2e-pass --var ADMIN_USERNAME:Admin-e2e --var SYNC_INTERVAL:5 \
    --var CF_DNS_TOKEN:cf-test-token --var CF_ZONE_ID:zone1 --var "CF_API_BASE:http://127.0.0.1:$MOCK_PORT" --var "TELEGRAM_API_BASE:http://127.0.0.1:$MOCK_PORT" \
    --var ADMIN_HOSTS:localhost --var "UPDATE_BASE:http://127.0.0.1:$MOCK_PORT/__release" --var CF_UPDATE_TOKEN:upd-token --var CF_ACCOUNT_ID:acc1 --var WORKER_NAME:roomkey-test --var INSTALL_URL:https://raw.githubusercontent.com/example/roomkey-stack/main/bootstrap.sh --var PSM_REPO:https://github.com/example/roomkey-stack ) > "$E2E/wrangler.log" 2>&1 &
pid=$!
for _ in $(seq 1 90); do grep -q "Ready on" "$E2E/wrangler.log" 2>/dev/null && break; sleep 1; done
BASE="http://localhost:$PORT" E2E_MOCK_PORT="$MOCK_PORT" node "$E2E/e2e.mjs"; rc=$?
kill $mock 2>/dev/null; pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; pkill -f "wrangler dev --local --port $PORT" 2>/dev/null

# The private install (panel-served bundle): a small stand-in bundle, a fresh
# panel, then e2e/bundle.mjs.
if (( rc == 0 )); then
    fake="$E2E/state-bundle"; rm -rf "$fake" "$E2E/state"; mkdir -p "$fake"
    printf 'stack' >"$fake/stack.tgz"; for a in amd64 arm64 armv7; do printf "agent-$a" >"$fake/psm-agent-linux-$a"; done
    ( cd "$fake" && { command -v sha256sum >/dev/null && sha256sum stack.tgz psm-agent-linux-* || shasum -a 256 stack.tgz psm-agent-linux-*; } >SHA256SUMS )
    ( cd "$PANEL" && BUNDLE_DIR="$fake" npm run build >/dev/null 2>&1 && exec npx wrangler dev --local --port "$PORT" --persist-to "$E2E/state" \
        --var ADMIN_PASSWORD:roomkey-e2e-pass --var ADMIN_HOSTS:localhost --var ALLOW_HTTP_INSTALL:1 ) > "$E2E/wrangler-bundle.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 90); do grep -q "Ready on" "$E2E/wrangler-bundle.log" 2>/dev/null && break; sleep 1; done
    BASE="http://localhost:$PORT" BUNDLE_DIR="$fake" node "$E2E/bundle.mjs"; rc=$?
    pkill -P $pid 2>/dev/null; kill $pid 2>/dev/null; pkill -f "wrangler dev --local --port $PORT" 2>/dev/null
    rm -rf "$fake"
    # the build left for others is one without the stand-in
    ( cd "$PANEL" && npm run build >/dev/null 2>&1 )
fi
(( rc == 0 )) || grep -iE "error|exception" "$E2E/wrangler.log" | grep -v "ERROR_LOG\|DEPRECATED" | head -5
exit $rc
