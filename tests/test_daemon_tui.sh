#!/usr/bin/env bash
# The interactive TUI with the shared background server switched on.
#
#   tests/test_daemon_tui.sh /path/to/codex
#
# With `features.daemon_auto_start=true` the TUI starts the daemon itself and attaches to it
# instead of embedding an app-server. Upstream aborts that path with "no complete local
# package" unless it runs from an official package layout (patches 0004 and 0013). Run the TUI
# on a pty and check that it reaches its first screen without complaining about the shared
# server, and that it left a running, reachable daemon behind.
#
# DAEMON_TEST_SEED=1 links the managed package by hand, for a codex built before patch 0013.
set -Eeuo pipefail

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${DAEMON_TUI_DIR:-$ROOT/work/daemon-tui}"
rm -rf "$W"; mkdir -p "$W"
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="$W/home"
mkdir -p "$CODEX_HOME"
if [ "${DAEMON_TEST_SEED:-0}" = 1 ]; then
  mkdir -p "$CODEX_HOME/packages/app-server-daemon/current/bin"
  ln -s "$CODEX" "$CODEX_HOME/packages/app-server-daemon/current/bin/codex"
fi
cleanup() { "$CODEX" app-server daemon stop >/dev/null 2>&1 || true; }
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT
fail() { echo "daemon tui test: $*" >&2; exit 1; }

set +e
timeout -s KILL 15 script -qfec "$CODEX -c features.daemon_auto_start=true" "$W/tui.raw" </dev/null >/dev/null 2>&1
set -e
strings -n 4 "$W/tui.raw" > "$W/tui.txt"
head -20 "$W/tui.txt"
if grep -q -E 'shared background server|--no-daemon|no complete local package' "$W/tui.txt"; then
  fail "the TUI could not use the shared server"
fi
grep -q '?1049h' "$W/tui.txt" || fail "the TUI never reached its first screen"

PID="$(jq -er .pid "$CODEX_HOME/app-server-daemon/daemon.pid")" || fail "no daemon pid record: the TUI did not start the daemon"
kill -0 "$PID" 2>/dev/null || fail "the daemon (pid $PID) is not running"
out="$("$CODEX" app-server daemon version)"
echo "$out"
[ "$(jq -er .status <<<"$out")" = running ] || fail "the daemon does not answer on its control socket"

echo "daemon tui test: OK"
