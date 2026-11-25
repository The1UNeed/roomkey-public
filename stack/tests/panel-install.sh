#!/usr/bin/env bash
# roomkey's private install: a server installed with the panel's command gets
# PSM's scripts and psm-agent from the panel, authenticated by the join token
# during the install and by its agent token after (never on curl's command
# line), and an update is checked against SHA256SUMS before anything is copied.

set -euo pipefail
export LC_ALL=C

PSM_ROOT_REAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source "$PSM_ROOT_REAL/lib/common.sh"
fail() { echo "panel-install: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# the panel: a bundle in a directory, and a curl that serves it and records
# the URL and the header file it was given
srv="$tmp_dir/panel"; mkdir -p "$srv/x"
printf '#!/bin/sh\necho new\n' >"$srv/x/manager.sh"; printf 'v2\n' >"$srv/x/.psm-version"
( cd "$srv/x" && tar -czf "$srv/stack.tgz" . )
( cd "$srv" && sha stack.tgz >SHA256SUMS )
curl() {
    local out="" url="" hdr="" a
    while (( $# )); do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            -H) hdr="$2"; shift 2 ;;
            --retry|--connect-timeout) shift 2 ;;
            -*) shift ;;
            *) url="$1"; shift ;;
        esac
    done
    printf '%s %s %s\n' "$url" "$hdr" "$(cat "${hdr#@}" 2>/dev/null)" >>"$tmp_dir/calls"
    cp "$srv/${url##*/}" "$out"
}

# 1. during the install: the join token, in a header file, to this panel
: >"$tmp_dir/calls"
PSM_PANEL_URL=https://sub.example.com PSM_AGENT_TOKEN=join-tok psm_panel_get SHA256SUMS "$tmp_dir/s" || fail "join download failed"
grep -q '^https://sub.example.com/api/agent/bundle/SHA256SUMS @.* X-PSM-Join: join-tok$' "$tmp_dir/calls" || fail "join call: $(cat "$tmp_dir/calls")"
grep -q 'join-tok' <<<"$(cut -d' ' -f1-2 "$tmp_dir/calls")" && fail "the token was on curl's command line"
hfile=$(awk '{print $2}' "$tmp_dir/calls"); [[ ! -e "${hfile#@}" ]] || fail "the header file was left behind"

# 2. after joining: the agent token from agent.json
PSM_AGENT_CFG="$tmp_dir/agent.json"; echo '{"panel":"https://sub.example.com","token":"agent-tok"}' >"$PSM_AGENT_CFG"
: >"$tmp_dir/calls"
psm_panel_get stack.tgz "$tmp_dir/t" || fail "agent download failed"
grep -q 'Authorization: Bearer agent-tok$' "$tmp_dir/calls" || fail "agent call: $(cat "$tmp_dir/calls")"

# 3. an update: checked, then copied over the scripts; PSM's state stays
PSM_ROOT="$tmp_dir/psm"; mkdir -p "$PSM_ROOT/config"
printf 'old\n' >"$PSM_ROOT/manager.sh"; echo '{"keep":1}' >"$PSM_ROOT/config/users.json"; echo panel >"$PSM_ROOT/.psm-source"
psm_from_panel || fail "a panel install was not recognised"
psm_panel_update || fail "a good update failed"
grep -q new "$PSM_ROOT/manager.sh" && [[ "$(cat "$PSM_ROOT/config/users.json")" == '{"keep":1}' ]] || fail "update: scripts not replaced or state touched"
[[ "$(psm_version)" == v2 ]] || fail "the version of a panel install: $(psm_version)"
# … and one that does not match its checksum changes nothing
printf 'old\n' >"$PSM_ROOT/manager.sh"
echo "0000000000000000000000000000000000000000000000000000000000000000  stack.tgz" >"$srv/SHA256SUMS"
! psm_panel_update || fail "an update that does not match its checksum was taken"
grep -q old "$PSM_ROOT/manager.sh" || fail "a bad update changed the scripts"

echo "ok: the panel install downloads with the right token (never in argv) and updates only what checks out"
