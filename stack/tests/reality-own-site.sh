#!/usr/bin/env bash
# REALITY with "own_site": the target is the node's own HTTPS site on
# 127.0.0.1:8443, never a third party (store-only: nothing is installed).

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034  # read by the sourced library
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/node_cli.sh"

fail() { echo "reality-own-site: $*" >&2; exit 1; }
keys='"private_key":"ci-private","public_key":"ci-public"'

out=$(psm_node_cli node add xray reality --tag own-1 --port 31443 \
    --data '{"own_site":true,"server_name":"n1.example.org",'"$keys"'}' --store-only --json --show-secrets)
jq -e '.item.node | .dest == "127.0.0.1:8443" and .server_names_raw == "n1.example.org" and .own_site == true and (has("limit_fallback") | not)' \
    <<<"$out" >/dev/null || fail "add: $out"

# a new domain moves the site with it
out=$(psm_node_cli node update xray reality own-1 --data '{"server_name":"n2.example.org"}' --store-only --json --show-secrets)
jq -e '.item.node | .dest == "127.0.0.1:8443" and .server_name == "n2.example.org" and .server_names_raw == "n2.example.org"' \
    <<<"$out" >/dev/null || fail "update: $out"

# an IP cannot have its own site (no certificate for a name)
if psm_node_cli node add xray reality --tag own-2 --port 31444 \
    --data '{"own_site":true,"server_name":"192.0.2.1",'"$keys"'}' --store-only --json >/dev/null 2>&1; then
    fail "accepted an IP as the own site"
fi

# without own_site a target is still required (no silent third-party default)
if psm_node_cli node add xray reality --tag third-1 --port 31445 \
    --data '{"server_name":"x.example.org",'"$keys"'}' --store-only --json >/dev/null 2>&1; then
    fail "accepted REALITY without a target"
fi

# REALITY + XHTTP (reality-layer) gets the own site too
out=$(psm_node_cli node add xray xhttp --tag own-layer --port 31446 \
    --data '{"mode":"reality-layer","own_site":true,"server_name":"n3.example.org",'"$keys"'}' --store-only --json --show-secrets)
jq -e '.item.node | .dest == "127.0.0.1:8443" and .own_site == true' <<<"$out" >/dev/null || fail "reality-layer own site: $out"

# The final guard in every core's restart path: a config whose REALITY falls
# back anywhere but this server is never started, whoever wrote it.
cfgdir="$tmp_dir/cores"; mkdir -p "$cfgdir/xray" "$cfgdir/sb" "$cfgdir/mh"
XRAY_CFG_DIR="$cfgdir/xray"; SINGBOX_CFG_DIR="$cfgdir/sb"; MIHOMO_CFG_DIR="$cfgdir/mh"
echo '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"www.cloudflare.com:443"}}}]}' > "$XRAY_CFG_DIR/config.json"
if psm_reality_guard xray 2>/dev/null; then fail "Xray REALITY with a third-party dest passed the guard"; fi
echo '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:8443"}}}]}' > "$XRAY_CFG_DIR/config.json"
psm_reality_guard xray || fail "Xray REALITY on the own site refused"
echo '{"inbounds":[{"type":"vless","tls":{"reality":{"enabled":true,"handshake":{"server":"learn.microsoft.com","server_port":443}}}}]}' > "$SINGBOX_CFG_DIR/config.json"
if psm_reality_guard sing-box 2>/dev/null; then fail "sing-box REALITY with a third-party handshake passed the guard"; fi
echo '{"listeners":[{"type":"vless","reality-config":{"dest":"example.com:443"}}]}' > "$MIHOMO_CFG_DIR/config.yaml"
if psm_reality_guard mihomo 2>/dev/null; then fail "mihomo REALITY with a third-party dest passed the guard"; fi

# strict: exactly PSM's own site, both Xray fields, ShadowTLS too, and an unreadable config is refused
for bad in '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:9000"}}}]}' \
           '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:8443","target":"www.apple.com:443"}}}]}' \
           '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"/run/forward.sock"}}}]}' \
           '{"inbounds":[{"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{}}}]}' \
           'not json'; do
    printf '%s' "$bad" > "$XRAY_CFG_DIR/config.json"
    if psm_reality_guard xray 2>/dev/null; then fail "Xray guard passed: $bad"; fi
done
echo '{"inbounds":[{"type":"vless","tls":{"reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":9999}}}}]}' > "$SINGBOX_CFG_DIR/config.json"
if psm_reality_guard sing-box 2>/dev/null; then fail "sing-box guard passed another loopback port"; fi
echo '{"inbounds":[{"type":"shadowtls","handshake":{"server":"www.bing.com","server_port":443}}]}' > "$SINGBOX_CFG_DIR/config.json"
if psm_reality_guard sing-box 2>/dev/null; then fail "sing-box ShadowTLS with a third-party handshake passed"; fi
echo '{"inbounds":[{"type":"vless","tls":{"reality":{"enabled":true,"handshake":{"server":"127.0.0.1","server_port":8443}}}}]}' > "$SINGBOX_CFG_DIR/config.json"
psm_reality_guard sing-box || fail "sing-box REALITY on the own site refused"
echo '{"listeners":[{"type":"shadowsocks","shadow-tls":{"enable":true,"version":3,"handshake":{"dest":"www.microsoft.com:443"}}}]}' > "$MIHOMO_CFG_DIR/config.yaml"
if psm_reality_guard mihomo 2>/dev/null; then fail "mihomo ShadowTLS with a third-party handshake passed"; fi
echo '{"listeners":[{"type":"vless","reality-config":{"dest":"127.0.0.1:8443"}}]}' > "$MIHOMO_CFG_DIR/config.yaml"
psm_reality_guard mihomo || fail "mihomo REALITY on the own site refused"

# a config that cannot be written refuses the restart (not a silent success)
echo '{"rules":["MATCH,DIRECT"]}' > "$MIHOMO_CFG_DIR/config.yaml"
if ( psm_file_replace() { return 1; }; psm_abuse_rules mihomo ) 2>/dev/null; then fail "a failed config write reported success"; fi

# abuse rules: BitTorrent and SMTP blocked, once, whatever ran before
echo '{"inbounds":[{"protocol":"vless"}],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"}]}}' > "$XRAY_CFG_DIR/config.json"
psm_abuse_rules xray && psm_abuse_rules xray || fail "abuse rules (xray)"
jq -e '([.routing.rules[] | select(.ruleTag == "psm-abuse-bt")] | length) == 1 and ([.routing.rules[] | select(.ruleTag == "psm-abuse-smtp" and .port == "25")] | length) == 1
       and any(.outbounds[]; .tag == "blocked") and .inbounds[0].sniffing.routeOnly == true and (.routing.rules | length) == 3' "$XRAY_CFG_DIR/config.json" >/dev/null \
    || fail "xray abuse rules: $(cat "$XRAY_CFG_DIR/config.json")"
echo '{"route":{"rules":[{"action":"sniff"},{"ip_is_private":true,"action":"reject"}],"final":"direct"}}' > "$SINGBOX_CFG_DIR/config.json"
psm_abuse_rules sing-box && psm_abuse_rules sing-box || fail "abuse rules (sing-box)"
jq -e '.route.rules | length == 4 and .[0].action == "sniff" and .[1].protocol == "bittorrent" and .[2].port == 25' "$SINGBOX_CFG_DIR/config.json" >/dev/null \
    || fail "sing-box abuse rules: $(cat "$SINGBOX_CFG_DIR/config.json")"
echo '{"rules":["MATCH,DIRECT"]}' > "$MIHOMO_CFG_DIR/config.yaml"
psm_abuse_rules mihomo && psm_abuse_rules mihomo || fail "abuse rules (mihomo)"
# (run twice above: idempotent) loopback and private destinations refused
# first, as in Xray and sing-box; the user's own rules after
jq -e '(.rules | length) == 15 and .rules[-1] == "MATCH,DIRECT" and (.rules | index(["IP-CIDR,127.0.0.0/8,REJECT"])) == 1
       and any(.rules[]; . == "IP-CIDR,169.254.0.0/16,REJECT") and any(.rules[]; . == "IP-CIDR6,::1/128,REJECT")
       and any(.rules[]; . == "DST-PORT,25,REJECT")' "$MIHOMO_CFG_DIR/config.yaml" >/dev/null || fail "mihomo abuse rules: $(cat "$MIHOMO_CFG_DIR/config.yaml")"

# a site that takes a moment to answer after the reload is waited for
# (bounded); one that never answers is still a failure
os_out=$( source "$PSM_ROOT/lib/nginx.sh" >/dev/null 2>&1
    SSL_DIR="$tmp_dir/ossl"; NGINX_HTTP_D="$tmp_dir/oconf"; mkdir -p "$SSL_DIR/n1.myroom.asia" "$NGINX_HTTP_D"
    : >"$SSL_DIR/n1.myroom.asia/fullchain.pem"; : >"$SSL_DIR/n1.myroom.asia/privkey.pem"; : >"$NGINX_HTTP_D/camouflage-n1.myroom.asia.conf"
    is_installed() { return 0; }; nginx_ensure_local_http() { :; }; _own_site_acme_route() { :; }
    nginx_test_reload() { :; }; sleep() { :; }
    cert_install_domain() { :; }; source() { :; }
    echo 0 >"$tmp_dir/answers"
    _own_site_answers() { local n; n=$(( $(cat "$tmp_dir/answers") + 1 )); echo "$n" >"$tmp_dir/answers"; (( n >= 3 )); }
    reality_own_site_ensure n1.myroom.asia >/dev/null 2>&1 && echo "late:ok" || echo "late:fail"
    _own_site_answers() { return 1; }
    reality_own_site_ensure n1.myroom.asia >/dev/null 2>&1 && echo "never:ok" || echo "never:fail" )
[[ "$os_out" == $'late:ok\nnever:fail' ]] || fail "own-site readiness: $os_out"
# a probe that stalls every time: one 10-second deadline in all, each probe
# given only the time left (not ten 8-second probes)
os_out=$( source "$PSM_ROOT/lib/nginx.sh" >/dev/null 2>&1
    SSL_DIR="$tmp_dir/ossl"; NGINX_HTTP_D="$tmp_dir/oconf"
    is_installed() { return 0; }; nginx_ensure_local_http() { :; }; _own_site_acme_route() { :; }
    nginx_test_reload() { :; }; sleep() { SECONDS=$(( SECONDS + $1 )); }
    cert_install_domain() { :; }; source() { :; }
    # (each stalls for its whole limit, at most 8 s as in the real probe)
    _own_site_answers() { local l=${2:-8}; (( l > 8 )) && l=8; echo "probe $l" >>"$tmp_dir/probes"; SECONDS=$(( SECONDS + l )); return 1; }
    : >"$tmp_dir/probes"; start=$SECONDS
    reality_own_site_ensure n1.myroom.asia >/dev/null 2>&1
    echo "$(tr '\n' ' ' <"$tmp_dir/probes")elapsed $(( SECONDS - start ))" )
[[ "$os_out" == "probe 8 probe 1 elapsed 10" ]] || fail "stalled probes outlast the deadline: $os_out"

echo "ok: REALITY own site, the final REALITY guard and the abuse rules"
