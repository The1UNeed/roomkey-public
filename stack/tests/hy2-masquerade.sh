#!/usr/bin/env bash
# A Hysteria2 masquerade that proxies another site would fetch it for anyone:
# every core start strips it (sing-box, mihomo), the guard reports it, and PSM
# refuses it on a new node. One on this server itself, or a directory, stays.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
fail() { echo "hy2-masquerade: $*" >&2; exit 1; }
SINGBOX_CFG_DIR="$tmp_dir/sb"; MIHOMO_CFG_DIR="$tmp_dir/mh"; mkdir -p "$SINGBOX_CFG_DIR" "$MIHOMO_CFG_DIR"
psm_file_replace() { mv -f "$2" "$1"; }

cat >"$SINGBOX_CFG_DIR/config.json" <<'J'
{"inbounds":[{"type":"hysteria2","tag":"a","masquerade":{"type":"proxy","url":"https://www.bing.com","rewrite_host":true}},
 {"type":"hysteria2","tag":"b","masquerade":{"type":"proxy","url":"https://127.0.0.1:8443"}},
 {"type":"hysteria2","tag":"c","masquerade":"file:///var/www"},{"type":"hysteria2","tag":"d","masquerade":"http://evil.example"}],"route":{"rules":[]}}
J
[[ $(psm_fallback_violations sing-box | wc -l) -eq 2 ]] || fail "sing-box: the guard missed an off-site masquerade"
psm_abuse_rules sing-box
jq -e '[.inbounds[] | .masquerade] == [null, {"type":"proxy","url":"https://127.0.0.1:8443"}, "file:///var/www", null]' \
    "$SINGBOX_CFG_DIR/config.json" >/dev/null || fail "sing-box: $(cat "$SINGBOX_CFG_DIR/config.json")"
[[ -z "$(psm_fallback_violations sing-box)" ]] || fail "sing-box: still reported after the strip"

echo '{"listeners":[{"type":"hysteria2","name":"x","masquerade":"https://www.bing.com"},{"type":"hysteria2","name":"y","masquerade":"http://localhost:8080/"}],"rules":[]}' \
    >"$MIHOMO_CFG_DIR/config.yaml"
[[ -n "$(psm_fallback_violations mihomo)" ]] || fail "mihomo: the guard missed an off-site masquerade"
psm_abuse_rules mihomo
jq -e '[.listeners[] | .masquerade] == [null, "http://localhost:8080/"]' "$MIHOMO_CFG_DIR/config.yaml" >/dev/null \
    || fail "mihomo: $(cat "$MIHOMO_CFG_DIR/config.yaml")"

# PSM's node command: no masquerade by default, another site refused
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/node_cli.sh"
hy='"sni":"hy.example.org","cert_path":"/etc/psm/c.pem","key_path":"/etc/psm/k.pem"'
out=$(psm_node_cli node add sing-box hysteria2 --tag hy-1 --port 31444 --data "{$hy}" --store-only --json --show-secrets)
jq -e '.item.node.masquerade == ""' <<<"$out" >/dev/null || fail "default masquerade: $out"
if psm_node_cli node add sing-box hysteria2 --tag hy-2 --port 31445 --data "{$hy,\"masquerade\":\"https://www.bing.com\"}" --store-only --json >/dev/null 2>&1; then
    fail "an off-site masquerade was accepted"
fi
echo "ok: Hysteria2 masquerade stays on this server"
