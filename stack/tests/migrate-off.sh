#!/usr/bin/env bash
# roomkey moves a server through the panel: psm migrate import and push are
# refused (CLI and menu alike, the menu without asking for a file first), and
# nothing on export, help or the menu points at them any more.

set -euo pipefail
export LC_ALL=C

PSM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
fail() { echo "migrate-off: $*" >&2; exit 1; }

# the CLI, as an operator types it: refused with 2, nothing asked or read
for cmd in "import /root/x.tgz --yes" "push root@203.0.113.9" "import" "push"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(bash "$PSM_ROOT/manager.sh" migrate $cmd </dev/null 2>&1) || rc=$?
    [[ $rc == 2 ]] || fail "psm migrate $cmd exited $rc: $out"
    [[ "$out" == *"through the panel"* && "$out" == *"is off"* ]] || fail "psm migrate $cmd: $out"
done

# the menu entry: refuses before any prompt (ask is never reached)
(
    source "$PSM_ROOT/lib/migrate.sh" >/dev/null 2>&1
    ask() { echo ASKED >&2; return 1; }
    rc=0; out=$(migrate_menu_import 2>&1) || rc=$?
    [[ $rc != 0 ]] || fail "the menu import returned success"
    [[ "$out" != *ASKED* ]] || fail "the menu asked for a file before refusing"
    [[ "$out" == *"through the panel"* ]] || fail "menu import: $out"
)
# … and the backup menu no longer offers it
! grep -q 'migrate_menu_import\|migrate\.menu\.import' "$PSM_ROOT/lib/backup.sh" || fail "the backup menu still offers import"

# nothing recommends import or push: help, the export's next step, the usage
help=$(bash "$PSM_ROOT/manager.sh" help 2>&1 || true)
mhelp=$(bash "$PSM_ROOT/manager.sh" migrate --help 2>&1 || true)
[[ "$help" != *"migrate export|import"* && "$help" != *"migrate push"* ]] || fail "psm help still lists import/push"
[[ "$mhelp" != *"migrate import FILE"* && "$mhelp" != *"migrate push ["* ]] || fail "psm migrate --help still lists import/push: $mhelp"
for l in "$PSM_ROOT"/lang/*/migrate.sh; do
    ! grep -q 'psm migrate import\|psm migrate push' "$l" || fail "$(basename "$(dirname "$l")") strings recommend import/push"
done
# the import machinery is gone, not just unreachable
! grep -q '_mig_restore\|_mig_validate\|_mig_unpack\|_coreperm_nginx_forwards' "$PSM_ROOT/lib/migrate.sh" || fail "import code is still in migrate.sh"

echo "ok: migrate import and push are refused (CLI and menu, no prompt first); nothing points at them"
