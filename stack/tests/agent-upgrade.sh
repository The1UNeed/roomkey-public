#!/usr/bin/env bash
# psm agent upgrade with psm-agent already at this version (only PSM changed):
# the agent is restarted all the same, running or not, so the panel sees the
# new PSM version and capabilities at the next sync rather than within the hour.

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fail() { echo "agent-upgrade: $*" >&2; exit 1; }

# $1: "active" or "inactive" → the service calls made, one per line (to a file:
# the helper sends the service manager's own output to /dev/null)
calls_for() {
    : >"$tmp_dir/calls"
    ( set -euo pipefail
      # shellcheck source=/dev/null
      source "$PSM_ROOT/lib/agent.sh"
      log_ok() { :; }
      svc_is_active() { echo "is_active $1" >>"$tmp_dir/calls"; [[ "$state" == active ]]; }
      svc_restart() { echo "restart $1" >>"$tmp_dir/calls"; }
      state="$1"
      _agent_restart_same
    )
    cat "$tmp_dir/calls"
}

out=$(calls_for active)
grep -qx "restart psm-agent" <<<"$out" || fail "a running psm-agent was not restarted after a PSM-only update: $out"
out=$(calls_for inactive)
grep -qx "restart psm-agent" <<<"$out" || fail "a stopped psm-agent was not started: $out"
[[ $(grep -c "^restart " <<<"$out") -eq 1 ]] || fail "restarted more than once: $out"

echo "ok: a PSM-only upgrade restarts psm-agent, so the panel sees the new PSM at once"
