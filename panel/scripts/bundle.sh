#!/usr/bin/env bash
# The install bundle the panel serves to servers (roomkey's private install):
#   install-bundle/stack.tgz               PSM's scripts, from the last commit
#   install-bundle/psm-agent-linux-*       psm-agent for amd64, arm64, armv7
#   install-bundle/SHA256SUMS
# `npm run build` copies it into the Worker's assets (web/dist/_install), where
# only a server with a good join or agent token can fetch it.
set -euo pipefail

PANEL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$PANEL/.." && pwd)"
OUT="$PANEL/install-bundle"
command -v git >/dev/null 2>&1 || { echo "bundle: git is needed" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# PSM: what is committed under stack/, without tests, docs, CI or the agent's
# source. (BUNDLE_WORKTREE=1, for tests: with the uncommitted edits too.)
ref=HEAD
if [[ -n "${BUNDLE_WORKTREE:-}" ]]; then ref=$(git -C "$ROOT" stash create 2>/dev/null); ref="${ref:-HEAD}"; fi
git -C "$ROOT" archive --format=tar "$ref:stack" -- . ':!tests' ':!.github' ':!agent' ':!README*.md' ':!CHANGELOG.md' \
    | tar -x -C "$tmp" -f -
# the version a server reports (psm version): this commit's date and hash
git -C "$ROOT" log -1 --format='%cs %h' >"$tmp/.psm-version"
# plain ustar, no extended attributes (macOS tar adds them otherwise)
( cd "$tmp" && COPYFILE_DISABLE=1 tar --format=ustar -czf "$OUT/stack.tgz" . )

# psm-agent, as its release workflow builds it; without Go here, the published
# release of this version (checked against its SHA256SUMS)
if command -v go >/dev/null 2>&1; then
    for t in amd64:amd64 arm64:arm64 arm:armv7; do
        ( cd "$ROOT/stack/agent" && CGO_ENABLED=0 GOOS=linux GOARCH="${t%%:*}" GOARM=7 \
            go build -trimpath -ldflags "-s -w" -o "$OUT/psm-agent-linux-${t##*:}" . )
    done
else
    ver=$(sed -n 's/^const agentVersion = "\(.*\)"/\1/p' "$ROOT/stack/agent/main.go")
    rel="${ROOMKEY_AGENT_RELEASES:-https://github.com/The1UNeed/roomkey-public/releases/download}/agent-v$ver"
    echo "bundle: no Go here; psm-agent $ver from $rel"
    curl -fsSL --retry 3 -o "$tmp/agent-sums" "$rel/SHA256SUMS" || { echo "bundle: could not download $rel/SHA256SUMS (install Go to build psm-agent here)" >&2; exit 1; }
    for a in amd64 arm64 armv7; do
        curl -fsSL --retry 3 -o "$OUT/psm-agent-linux-$a" "$rel/psm-agent-linux-$a" || { echo "bundle: download failed: psm-agent-linux-$a" >&2; exit 1; }
        want=$(awk -v f="psm-agent-linux-$a" '$2 == f || $2 == "*" f { print $1 }' "$tmp/agent-sums")
        got=$( { command -v sha256sum >/dev/null 2>&1 && sha256sum "$OUT/psm-agent-linux-$a" || shasum -a 256 "$OUT/psm-agent-linux-$a"; } | awk '{ print $1 }')
        [[ -n "$want" && "$want" == "$got" ]] || { echo "bundle: psm-agent-linux-$a does not match the release's checksum" >&2; exit 1; }
        chmod 755 "$OUT/psm-agent-linux-$a"
    done
fi

( cd "$OUT"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum stack.tgz psm-agent-linux-* > SHA256SUMS
  else shasum -a 256 stack.tgz psm-agent-linux-* > SHA256SUMS; fi )
# the PSM version servers report once they run this bundle (the panel's
# updater compares it with what each server reports)
cp "$tmp/.psm-version" "$OUT/VERSION"
echo "bundle: $(git -C "$ROOT" log -1 --format='%h %cs') → $OUT"
cat "$OUT/SHA256SUMS"
