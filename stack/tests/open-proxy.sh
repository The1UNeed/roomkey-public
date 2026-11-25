#!/usr/bin/env bash
# The pre-start check refuses a listener anyone can use without an account: a
# public SOCKS / HTTP / mixed proxy with no users, or a public port forward.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
fail() { echo "open-proxy: $*" >&2; exit 1; }

cat >"$tmp_dir/x.json" <<'J'
{"inbounds":[{"tag":"api","listen":"127.0.0.1","port":10085,"protocol":"dokodemo-door"},
 {"tag":"s","port":1080,"protocol":"socks","settings":{"auth":"noauth"}},
 {"tag":"f","port":9,"protocol":"dokodemo-door"},
 {"tag":"h","port":8080,"protocol":"http","settings":{}},
 {"tag":"ok","port":2,"protocol":"socks","settings":{"auth":"password","accounts":[{"user":"a","pass":"b"}]}},
 {"tag":"lo","listen":"127.0.0.1","port":3,"protocol":"socks","settings":{"auth":"noauth"}}]}
J
out=$(psm_open_proxy_violations xray "$tmp_dir/x.json" | tr '\n' ';')
[[ "$out" == "open socks proxy :1080 (s);port forward :9 (f);open HTTP proxy :8080 (h);" ]] || fail "xray: '$out'"
if psm_reality_guard xray "$tmp_dir/x.json" 2>/dev/null; then fail "xray: an open SOCKS was let start"; fi

echo '{"inbounds":[{"type":"mixed","listen":"::","listen_port":7890,"tag":"m"},{"type":"direct","listen":"127.0.0.1","listen_port":5},{"type":"socks","listen":"::","listen_port":6,"tag":"u","users":[{"username":"a","password":"b"}]}]}' >"$tmp_dir/s.json"
out=$(psm_open_proxy_violations sing-box "$tmp_dir/s.json" | tr '\n' ';')
[[ "$out" == "open mixed proxy :7890 (m);" ]] || fail "sing-box: '$out'"

echo '{"allow-lan":true,"mixed-port":7890,"listeners":[{"name":"t","type":"tunnel","port":53},{"name":"ok","type":"socks","port":4,"udp":false,"users":[{"username":"a","password":"b"}]}]}' >"$tmp_dir/m.json"
out=$(psm_open_proxy_violations mihomo "$tmp_dir/m.json" | tr '\n' ';')
[[ "$out" == "port forward :53 (t);open proxy on the global mixed-port;" ]] || fail "mihomo: '$out'"

# Xray's mixed is SOCKS without authentication by default
echo '{"inbounds":[{"tag":"mx","port":7891,"protocol":"mixed","settings":{}}]}' >"$tmp_dir/xm.json"
[[ "$(psm_open_proxy_violations xray "$tmp_dir/xm.json")" == "open mixed proxy :7891 (mx)" ]] || fail "xray mixed"
# mihomo: a top-level tunnel forwards; global authentication covers listeners and global ports,
# unless a public range skips it; loopback binds are not public
echo '{"tunnels":["tcp/udp,0.0.0.0:6553,8.8.8.8:53",{"network":["tcp"],"address":"127.0.0.1:7777","target":"x:1"}]}' >"$tmp_dir/mt.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mt.json")" == "port forward (tunnel 0.0.0.0:6553)" ]] || fail "mihomo tunnels: $(psm_open_proxy_violations mihomo "$tmp_dir/mt.json")"
# a global mixed port relays UDP without the account, credentials or not
echo '{"allow-lan":true,"mixed-port":7890,"authentication":["a:b"],"listeners":[{"name":"in","type":"socks","port":4,"udp":false,"users":[{"username":"a","password":"b"}]}]}' >"$tmp_dir/ma.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/ma.json")" == "open proxy on the global mixed-port" ]] || fail "mihomo global mixed with auth: $(psm_open_proxy_violations mihomo "$tmp_dir/ma.json")"
# a public global HTTP port is refused too, credentials or not (PSM writes none)
echo '{"allow-lan":true,"port":7892,"authentication":["a:b"],"skip-auth-prefixes":["::1/128","127.0.0.0/8"]}' >"$tmp_dir/mh.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mh.json")" == "open proxy on the global port" ]] || fail "mihomo global HTTP port: $(psm_open_proxy_violations mihomo "$tmp_dir/mh.json")"
# every account of a public listener needs a name and a password
echo '{"listeners":[{"name":"b","type":"http","port":8,"users":[{"username":"a","password":"b"},{"username":"x","password":""}]}]}' >"$tmp_dir/mb2.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mb2.json")" == "open http proxy :8 (b)" ]] || fail "mihomo blank account beside a good one: $(psm_open_proxy_violations mihomo "$tmp_dir/mb2.json")"
# a named listener counts its own accounts only, not the global list
echo '{"authentication":["a:b"],"listeners":[{"name":"h","type":"http","port":9}]}' >"$tmp_dir/mi.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mi.json")" == "open http proxy :9 (h)" ]] || fail "mihomo inherited auth: $(psm_open_proxy_violations mihomo "$tmp_dir/mi.json")"
echo '{"allow-lan":true,"mixed-port":7890,"authentication":["a:b"],"skip-auth-prefixes":["0.0.0.0/0"]}' >"$tmp_dir/ms.json"
[[ -n "$(psm_open_proxy_violations mihomo "$tmp_dir/ms.json")" ]] || fail "mihomo skip-auth-prefixes"
echo '{"allow-lan":true,"bind-address":"127.0.0.1","mixed-port":7890}' >"$tmp_dir/mb.json"
[[ -z "$(psm_open_proxy_violations mihomo "$tmp_dir/mb.json")" ]] || fail "mihomo loopback bind"

# mihomo SOCKS relays UDP without the account; an explicit empty user list is no account
echo '{"listeners":[{"name":"s","type":"socks","port":5,"users":[{"username":"a","password":"b"}]},{"name":"t","type":"socks","port":6,"udp":false,"users":[{"username":"a","password":"b"}]}]}' >"$tmp_dir/mu.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mu.json")" == "socks UDP relayed without an account :5 (s)" ]] || fail "mihomo SOCKS UDP: $(psm_open_proxy_violations mihomo "$tmp_dir/mu.json")"
echo '{"authentication":["a:b"],"listeners":[{"name":"e","type":"http","port":7,"users":[]}]}' >"$tmp_dir/me.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/me.json")" == "open http proxy :7 (e)" ]] || fail "mihomo explicit empty users"
# a LAN client list does not cover the UDP of a public global mixed port
echo '{"allow-lan":true,"lan-allowed-ips":["127.0.0.1/8","::1/128"],"mixed-port":7890}' >"$tmp_dir/ml.json"
[[ -n "$(psm_open_proxy_violations mihomo "$tmp_dir/ml.json")" ]] || fail "mihomo lan-allowed-ips was taken as closing the global port"
# VLESS/Trojan fallbacks and sing-box Trojan fallbacks stay on this server
echo '{"inbounds":[{"protocol":"vless","settings":{"fallbacks":[{"dest":80},{"dest":"127.0.0.1:8443"},{"dest":"/dev/shm/f.sock"},{"dest":"www.cloudflare.com:443"}]}}]}' >"$tmp_dir/xf.json"
[[ "$(psm_fallback_violations xray "$tmp_dir/xf.json")" == "fallback to www.cloudflare.com:443" ]] || fail "xray fallbacks"
echo '{"inbounds":[{"type":"trojan","fallback":{"server":"127.0.0.1","server_port":80},"fallback_for_alpn":{"h2":{"server":"1.1.1.1","server_port":443}}}]}' >"$tmp_dir/sf.json"
[[ -n "$(psm_fallback_violations sing-box "$tmp_dir/sf.json")" ]] || fail "sing-box Trojan fallback"

# control APIs and DNS servers that anyone can reach
echo '{"external-controller":"0.0.0.0:9090","dns":{"enable":true,"listen":"0.0.0.0:53"}}' >"$tmp_dir/mc.json"
[[ "$(psm_open_proxy_violations mihomo "$tmp_dir/mc.json" | tr '\n' ';')" == "control API on 0.0.0.0:9090 (external-controller);DNS server on 0.0.0.0:53;" ]] || fail "mihomo controller/dns: $(psm_open_proxy_violations mihomo "$tmp_dir/mc.json")"
echo '{"external-controller":"127.0.0.1:9090"}' >"$tmp_dir/mc2.json"
[[ -z "$(psm_open_proxy_violations mihomo "$tmp_dir/mc2.json")" ]] || fail "a loopback mihomo controller was refused"
echo '{"experimental":{"clash_api":{"external_controller":"0.0.0.0:9090"}}}' >"$tmp_dir/sc.json"
[[ "$(psm_open_proxy_violations sing-box "$tmp_dir/sc.json")" == "control API on 0.0.0.0:9090" ]] || fail "sing-box clash_api"

echo '{"inbounds":[{"tag":"vless","port":443,"protocol":"vless"}]}' >"$tmp_dir/clean.json"
[[ -z "$(psm_open_proxy_violations xray "$tmp_dir/clean.json")" ]] || fail "a VLESS node counted as open"

# hand-written spellings the cores accept (Go reads JSON keys without regard
# to case; Xray lower-cases protocol and security names), unencrypted
# Shadowsocks, and accounts without a user name: all refused
refused() {   # <core> <json> <what>
    printf '%s' "$2" >"$tmp_dir/c.json"
    if psm_reality_guard "$1" "$tmp_dir/c.json" 2>/dev/null; then fail "$3 passed the guard"; fi
}
refused xray '{"inbounds":[{"port":443,"protocol":"vless","streamSettings":{"security":"REALITY","realitySettings":{"dest":"www.example.com:443"}}}]}' 'security "REALITY" to a third party'
refused xray '{"inbounds":[{"port":1080,"protocol":"SOCKS","settings":{"auth":"noauth"}}]}' 'protocol "SOCKS"'
refused xray '{"inbounds":[{"port":53,"protocol":"Dokodemo-Door","settings":{"address":"8.8.8.8","port":53}}]}' 'protocol "Dokodemo-Door"'
refused xray '{"Inbounds":[{"port":1080,"protocol":"socks","settings":{"auth":"noauth"}}]}' 'an "Inbounds" key'
refused xray '{"inbounds":[{"port":443,"protocol":"vless","StreamSettings":{"security":"reality","realitySettings":{"dest":"www.example.com:443"}}}]}' 'a "StreamSettings" key'
refused xray '{"inbounds":[{"port":443,"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:8443","Target":"www.example.com:443"}}}]}' 'a "Target" beside the dest'
refused xray '{"inbounds":[{"port":443,"protocol":"vless","streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:8443","Dest":"www.example.com:443"}}}]}' 'one key spelled two ways'
refused sing-box '{"Inbounds":[{"type":"mixed","listen":"::","listen_port":7890}]}' 'a sing-box "Inbounds" key'
refused xray '{"inbounds":[{"port":1080,"protocol":"socks","settings":{"auth":"password","accounts":[{"user":"","pass":""}]}}]}' 'a SOCKS account with no user name'
refused xray '{"inbounds":[{"port":8080,"protocol":"http","settings":{"accounts":[{"user":"","pass":""}]}}]}' 'an HTTP account with no user name'
refused xray '{"inbounds":[{"port":8388,"protocol":"shadowsocks","settings":{"method":"none","password":""}}]}' 'Xray Shadowsocks method none'
refused sing-box '{"inbounds":[{"type":"shadowsocks","listen":"::","listen_port":8388,"method":"none"}]}' 'sing-box Shadowsocks method none'
refused sing-box '{"inbounds":[{"type":"vless","listen":"::","listen_port":443,"users":[{"uuid":"x"}],"tls":{"enabled":true,"reality":{"Enabled":true,"handshake":{"server":"www.example.com","server_port":443}}}}]}' 'a sing-box REALITY "Enabled" to a third party'
refused xray '{"inbound\u017f":[{"port":1080,"protocol":"socks","settings":{"auth":"noauth"}}]}' 'a key with a non-ASCII letter Go folds (long s)'
# … and PSM's own shapes still pass after the normalisation
printf '%s' '{"inbounds":[{"tag":"r","port":443,"protocol":"vless","settings":{"clients":[{"id":"x"}]},"streamSettings":{"security":"reality","realitySettings":{"dest":"127.0.0.1:8443","serverNames":["n1.myroom.asia"]}}},{"tag":"ss","port":8388,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"k"}}]}' >"$tmp_dir/c.json"
psm_reality_guard xray "$tmp_dir/c.json" 2>/dev/null || fail "a PSM REALITY + SS2022 config was refused"

echo "ok: open proxies are never started"
