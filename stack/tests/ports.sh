#!/usr/bin/env bash
# Port reservations follow what each node really listens on: mKCP and QUIC are
# UDP, Shadowsocks and Snell are TCP and UDP; a UDP port inside a Hysteria2
# hopping range belongs to that range.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT/lib/common.sh"
CFG_DIR="$tmp_dir/config"
# shellcheck disable=SC2034
PSM_STATE="$CFG_DIR/psm.state"
source "$PSM_ROOT/lib/node_cli.sh"
fail() { echo "ports: $*" >&2; exit 1; }

hy=$(_node_cli_store_path sing-box hysteria2); mkdir -p "$(dirname "$hy")"
echo '[{"tag":"hy","port":443,"hop_ports":"20000-20010"}]' >"$hy"

refused() { ! _node_cli_check_port_conflict "$@" 2>/dev/null; }
refused xray xhttp kcp 20005 '{"mode":"mkcp"}' || fail "an mKCP node took a hopping port"
refused xray ss2022 ss 443 '{}' || fail "Shadowsocks (TCP+UDP) took Hysteria2's UDP base port"
refused sing-box vless q 443 '{"transport":"quic"}' || fail "a QUIC node took Hysteria2's UDP base port"
_node_cli_check_port_conflict xray xhttp web 443 '{"mode":"xhttp"}' 2>/dev/null || fail "a TCP node was refused beside a UDP one"
_node_cli_check_port_conflict xray xhttp web2 20005 '{"mode":"xhttp"}' 2>/dev/null || fail "a TCP node was refused inside a (UDP) hopping range"

# a UDP node's quota pause leaves TCP on the same port alone (REALITY beside Hysteria2 on 443)
acts=$( source "$PSM_ROOT/lib/traffic.sh" >/dev/null 2>&1
        _IPT() { echo "$*"; }; _IPT=_IPT; ss() { echo "ss $*"; }; conntrack() { echo "conntrack $*"; }
        _trf_iptables_pause 443 udp )
[[ "$acts" == *"-p udp"* && "$acts" != *"-p tcp"* && "$acts" != *"ss -K"* ]] || fail "a UDP pause touched TCP: $acts"
acts=$( source "$PSM_ROOT/lib/traffic.sh" >/dev/null 2>&1
        _IPT() { echo "$*"; }; _IPT=_IPT; _trf_ipt_ensure_chain() { :; }
        _trf_ipt_ensure_rules hy 443 "" udp )
[[ "$acts" == *"-p udp"* && "$acts" != *"-p tcp"* ]] || fail "a UDP meter counts TCP: $acts"

echo "ok: ports by transport"
