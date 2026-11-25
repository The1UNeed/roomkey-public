#!/usr/bin/env bash
# roomkey's nginx forwards nowhere off the server (the DMIT failure: a route to
# a third-party host is an open relay):
#  - PSM's menus take only loopback upstreams (sites, SNI routes, upstream edits);
#  - every reload, nginx's start (systemd drop-in) and psm guard refuse any
#    proxy_pass / upstream server / SNI route off the server;
# and a certificate path never opens up a file outside the certificate dirs.

set -euo pipefail
export LC_ALL=C

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
source "$PSM_ROOT/lib/nginx.sh" >/dev/null 2>&1
fail() { echo "nginx-forwards: $*" >&2; exit 1; }

# 1. upstreams: loopback only
for u in 127.0.0.1:8443 127.0.0.2:9000 localhost:3001 '[::1]:8080'; do
    _sni_valid_upstream "$u" || fail "a loopback upstream was refused: $u"
done
for u in speed.cloudflare.com:443 1.1.1.1:443 '[2606:4700::1111]:443' example.com:80 127.0.0.1.nip.io:443 0.0.0.0:443; do
    ! _sni_valid_upstream "$u" || fail "an upstream off the server passed: $u"
done
# the menu's SNI route (Opus's demo) is refused before anything is written
NGINX_STREAM_D="$tmp_dir/stream.d"; mkdir -p "$NGINX_STREAM_D"
_sni_map_file() { echo "$NGINX_STREAM_D/sni_map.conf"; }
printf 'map $ssl_preread_server_name $psm_backend {\n    # PSM:ENTRIES:BEGIN\n    # PSM:ENTRIES:END\n    default "";\n}\n' >"$(_sni_map_file)"
real_reload=$(declare -f nginx_test_reload)
nginx_test_reload() { echo RELOADED; }
out=$(_sni_add_entry speed.cloudflare.com speed.cloudflare.com:443 2>&1) && fail "an SNI route off the server was accepted"
! grep -q cloudflare "$(_sni_map_file)" || fail "the route was written: $(cat "$(_sni_map_file)")"
eval "$real_reload"

# 2. the forward scan over a config tree
root="$tmp_dir/fs"; ng="$root/etc/nginx"; mkdir -p "$ng/conf.d" "$ng/stream.d"
cat >"$ng/conf.d/camouflage-n1.conf" <<'C'
server { listen 127.0.0.1:8443 ssl; server_name n1.myroom.asia; root /var/www/n1; }
server { listen 127.0.0.1:8080; location / { proxy_pass http://127.0.0.1:3001; } }
C
cat >"$ng/stream.d/sni_map.conf" <<'C'
map $ssl_preread_server_name $psm_backend {
    # PSM:ENTRIES:BEGIN
    n1.myroom.asia   127.0.0.1:8443;
    # PSM:ENTRIES:END
    default     "";
}
server { listen 443 reuseport; proxy_pass $psm_backend; ssl_preread on; }
C
[[ -z "$(PSM_FS_ROOT="$root" psm_nginx_forwards)" ]] || fail "PSM's own tree reported: $(PSM_FS_ROOT="$root" psm_nginx_forwards)"
bash "$PSM_ROOT/lib/nginx_forwards.sh" "$ng" || fail "the start check refused PSM's own tree"
check_off() {   # <file> <content> <what>
    printf '%s\n' "$2" >"$ng/$1"
    [[ -n "$(PSM_FS_ROOT="$root" psm_nginx_forwards)" ]] || fail "$3 was not reported"
    ! bash "$PSM_ROOT/lib/nginx_forwards.sh" "$ng" 2>/dev/null || fail "the start check let $3 through"
    rm -f "$ng/$1"
}
check_off conf.d/site.conf 'server { location / { proxy_pass http://www.cloudflare.com; } }' "a site proxying off the server"
check_off conf.d/grpc.conf 'server { location / { grpc_pass grpc://203.0.113.9:443; } }' "a grpc_pass off the server"
check_off conf.d/up.conf $'upstream far {\n    server 203.0.113.9:443;\n}\nserver { location / { proxy_pass http://far; } }' "an upstream server off the server"
check_off stream.d/route.conf $'map $ssl_preread_server_name $b2 {\n    speed.cloudflare.com speed.cloudflare.com:443;\n}\nserver { listen 8444; proxy_pass $b2; ssl_preread on; }' "an SNI route off the server"
# hand-written forms a line-by-line reading missed (Opus's re-review)
check_off conf.d/nl.conf $'server { location / {\n    proxy_pass\n        http://203.0.113.9;\n} }' "a proxy_pass with its value on the next line"
check_off stream.d/one.conf 'map $ssl_preread_server_name $b3 { default 203.0.113.9:443; } server { listen 8445; proxy_pass $b3; }' "a one-line map"
check_off stream.d/noport.conf $'map $ssl_preread_server_name $b4 {\n    default www.cloudflare.com;\n}\nserver { listen 8446; proxy_pass $b4:443; }' "a map value without a port"
check_off conf.d/glued.conf 'server{location /{proxy_pass http://203.0.113.9;}}' "directives glued to braces"
check_off conf.d/quoted.conf 'server { location / { "proxy_pass" "http://203.0.113.9"; } }' "a quoted directive"
check_off conf.d/var.conf 'server { location / { proxy_pass http://$host; } }' "a proxy_pass to a variable the client chooses"
check_off routes.inc 'server { location / { proxy_pass http://203.0.113.9; } }' "a file not named .conf"
check_off conf.d/inc.conf 'map $ssl_preread_server_name $b5 { include /etc/nginx/b5.list; } server { listen 8447; proxy_pass $b5; }' "an include inside a map"
# … while a map that routes nothing, and PSM's own websocket map, are fine
printf 'map $http_upgrade $connection_upgrade { default upgrade; "" close; }\nmap $x $unused { a.com 203.0.113.9:443; }\n' >"$ng/conf.d/ok.conf"
[[ -z "$(PSM_FS_ROOT="$root" psm_nginx_forwards)" ]] || fail "maps that route nothing were reported: $(PSM_FS_ROOT="$root" psm_nginx_forwards)"
rm "$ng/conf.d/ok.conf"
ln -s /etc/passwd "$ng/conf.d/out.conf"
[[ "$(PSM_FS_ROOT="$root" psm_nginx_forwards)" == *"links out of the nginx tree"* ]] || fail "a link out of the tree was not reported"
rm "$ng/conf.d/out.conf"

# 3. a reload refuses (nginx keeps what it runs), naming the forward
printf 'server { location / { proxy_pass http://1.1.1.1; } }\n' >"$ng/conf.d/bad.conf"
nginx() { echo "nginx $*" >>"$tmp_dir/calls"; }; svc_reload() { echo "reload $*" >>"$tmp_dir/calls"; }
: >"$tmp_dir/calls"
out=$(PSM_FS_ROOT="$root" nginx_test_reload 2>&1) && fail "a reload went ahead with a forward off the server"
[[ "$out" == *"1.1.1.1"* && ! -s "$tmp_dir/calls" ]] || fail "reload: $out / $(cat "$tmp_dir/calls")"
rm "$ng/conf.d/bad.conf"
PSM_FS_ROOT="$root" nginx_test_reload >/dev/null 2>&1 || fail "a clean reload was refused"
unset -f nginx svc_reload

# 4. nginx's own start: the systemd drop-in runs the check
_uses_systemd() { return 0; }; systemctl() { :; }
PSM_SYSTEMD_DIR="$tmp_dir/units" psm_nginx_start_hook || fail "the drop-in was not written"
grep -q "^ExecStartPre=/bin/bash $LIB_DIR/nginx_forwards.sh$" "$tmp_dir/units/nginx.service.d/psm-forwards.conf" || fail "drop-in: $(cat "$tmp_dir/units/nginx.service.d/psm-forwards.conf")"
unset -f _uses_systemd systemctl

# 5. certificates: only files in the certificate dirs
NGINX_SSL_DIR="$tmp_dir/ssl"; mkdir -p "$NGINX_SSL_DIR/n1"; : >"$NGINX_SSL_DIR/n1/privkey.pem"
psm_cert_file_allowed "$NGINX_SSL_DIR/n1/privkey.pem" || fail "a key in the certificate store was refused"
mkdir -p "$tmp_dir/etc-psm"; : >"$tmp_dir/etc-psm/agent.json"
! psm_cert_file_allowed "$tmp_dir/etc-psm/agent.json" || fail "the agent token counted as a certificate"
! psm_cert_file_allowed /etc/passwd || fail "/etc/passwd counted as a certificate"
ln -s "$tmp_dir/etc-psm/agent.json" "$NGINX_SSL_DIR/n1/sneaky.pem"
! psm_cert_file_allowed "$NGINX_SSL_DIR/n1/sneaky.pem" || fail "a link from the store to the agent token passed"
( source "$PSM_ROOT/lib/coreperm.sh" >/dev/null 2>&1
  chgrp() { echo "chgrp $*" >>"$tmp_dir/grants"; }; chmod() { echo "chmod $*" >>"$tmp_dir/grants"; }
  : >"$tmp_dir/grants"
  _coreperm_grant_file "$tmp_dir/etc-psm/agent.json" >/dev/null 2>&1
  _coreperm_grant_file "$NGINX_SSL_DIR/n1/sneaky.pem" >/dev/null 2>&1
  [[ ! -s "$tmp_dir/grants" ]] || { echo "granted: $(cat "$tmp_dir/grants")"; exit 1; }
  _coreperm_grant_file "$NGINX_SSL_DIR/n1/privkey.pem" >/dev/null 2>&1
  grep -q "privkey.pem" "$tmp_dir/grants" ) || fail "core read access went outside the certificate dirs"
# a node with a certificate path elsewhere is refused
( source "$PSM_ROOT/lib/node_cli.sh" >/dev/null 2>&1
  ! _node_cli_tls_auto sing-box trojan '{"cert_path":"/etc/passwd","key_path":"/etc/passwd"}' >/dev/null 2>&1 ) \
    || fail "a node took /etc/passwd as its certificate"

echo "ok: nginx forwards nowhere off the server (menus, reloads, starts); certificate paths stay in the certificate dirs"
