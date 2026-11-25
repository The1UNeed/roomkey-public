#!/usr/bin/env bash

set -euo pipefail

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# offline: the names of nodes do without the flag of the server's country
export PSM_SERVER_COUNTRY="${PSM_SERVER_COUNTRY-}"

"$PSM_ROOT/tests/config-regression.sh"
"$PSM_ROOT/tests/doctor-smoke.sh"
"$PSM_ROOT/tests/node-cli-smoke.sh"
"$PSM_ROOT/tests/users-import.sh"
"$PSM_ROOT/tests/reality-own-site.sh"
"$PSM_ROOT/tests/guard-hook.sh"
"$PSM_ROOT/tests/users-restore.sh"
"$PSM_ROOT/tests/restore-flow.sh"
"$PSM_ROOT/tests/relays-off.sh"
"$PSM_ROOT/tests/migrate-off.sh"
"$PSM_ROOT/tests/users-grants.sh"
"$PSM_ROOT/tests/xray-unmanaged.sh"
"$PSM_ROOT/tests/open-proxy.sh"
"$PSM_ROOT/tests/nginx-forwards.sh"
"$PSM_ROOT/tests/panel-install.sh"
"$PSM_ROOT/tests/ports.sh"
"$PSM_ROOT/tests/traffic-move.sh"
"$PSM_ROOT/tests/standalone-activate.sh"
"$PSM_ROOT/tests/hy2-masquerade.sh"
"$PSM_ROOT/tests/users-apply-retry.sh"
"$PSM_ROOT/tests/tg-notify.sh"
"$PSM_ROOT/tests/cert-ip.sh"
"$PSM_ROOT/tests/gost-version.sh"
"$PSM_ROOT/tests/client-exports.sh"
"$PSM_ROOT/tests/tg-bot.sh"
