#!/usr/bin/env bash
# Lifecycle of the shared background server (`codex app-server daemon`) on Bionic.
#
#   tests/test_daemon.sh /path/to/codex
#
# Needs a real Termux userland (procps `ps`, the Termux prefix); CI runs it inside
# termux-docker after the build. It covers patches 0011 (rendezvous directory and socket
# path length) and 0012 (/proc based process identity), neither of which any other test
# reaches: before them `codex app-server --listen unix://` failed with EACCES on /tmp.
#
# The managed package is seeded by hand (a symlink to the binary under test): the daemon
# only installs its own copy from an official package layout, which this port does not
# ship yet. Starting, probing, restarting and stopping do not care.
set -Eeuo pipefail

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="${DAEMON_TEST_HOME:-$ROOT/work/daemon-home}"
rm -rf "$CODEX_HOME"
mkdir -p "$CODEX_HOME/packages/app-server-daemon/current/bin"
ln -s "$CODEX" "$CODEX_HOME/packages/app-server-daemon/current/bin/codex"

VERSION="$("$CODEX" --version | awk '{print $2}')"
SOCKET="$CODEX_HOME/app-server-control/app-server-control.sock"
PID_FILE="$CODEX_HOME/app-server-daemon/daemon.pid"
fail() { echo "daemon test: $*" >&2; exit 1; }

cleanup() {
  "$CODEX" app-server daemon stop >/dev/null 2>&1 || true
  if [ -f "$CODEX_HOME/app-server-daemon/daemon.stderr.log" ]; then
    echo "--- daemon.stderr.log"; cat "$CODEX_HOME/app-server-daemon/daemon.stderr.log"
  fi
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

field() { jq -er ".$2" <<<"$1"; }   # $1 = json, $2 = jq path; fails when missing or null

alive() { kill -0 "$1" 2>/dev/null && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null; }

echo "== start"
out="$("$CODEX" app-server daemon start)"
echo "$out"
[ "$(field "$out" status)" = started ] || fail "first start did not report 'started'"
[ "$(field "$out" backend)" = pid ] || fail "unexpected backend"
[ "$(field "$out" appServerVersion)" = "$VERSION" ] || fail "server version != $VERSION"
PID="$(field "$out" pid)"
alive "$PID" || fail "daemon pid $PID is not running"
tr '\0' ' ' <"/proc/$PID/cmdline" | grep -q 'app-server --listen unix://' || fail "unexpected daemon command line"

echo "== rendezvous socket (0011)"
[ -L "$SOCKET" ] || fail "$SOCKET is not a symlink"
TARGET="$(readlink "$SOCKET")"
echo "$TARGET (${#TARGET} bytes)"
case "$TARGET" in
  /data/data/com.termux/files/usr/tmp/codex-daemon-"$(id -u)"/*) ;;
  *) fail "socket target is outside the Termux prefix tmp: $TARGET" ;;
esac
# bind() needs the whole path in sun_path (108 bytes including the terminator).
[ "${#TARGET}" -le 107 ] || fail "socket path is ${#TARGET} bytes, sun_path holds 107"
[ -S "$TARGET" ] || fail "$TARGET is not a socket"

echo "== process identity (0012)"
jq -e '.pid == '"$PID"' and (.processIdentity.bootId | length > 0) and (.processIdentity.startTicks > 0)' \
  "$PID_FILE" >/dev/null || { cat "$PID_FILE"; fail "pid record has no /proc based identity"; }

echo "== start again reuses the server"
out="$("$CODEX" app-server daemon start)"
[ "$(field "$out" status)" = alreadyRunning ] || fail "second start did not report 'alreadyRunning': $out"
alive "$PID" || fail "second start killed the daemon"

echo "== version"
out="$("$CODEX" app-server daemon version)"
echo "$out"
[ "$(field "$out" cliVersion)" = "$VERSION" ] || fail "cli version != $VERSION"
[ "$(field "$out" appServerVersion)" = "$VERSION" ] || fail "server version != $VERSION"

echo "== restart"
out="$("$CODEX" app-server daemon restart)"
echo "$out"
[ "$(field "$out" status)" = restarted ] || fail "restart did not report 'restarted'"
NEW="$(field "$out" pid)"
[ "$NEW" != "$PID" ] || fail "restart kept pid $PID"
alive "$PID" && fail "old daemon $PID survived the restart"
alive "$NEW" || fail "restarted daemon $NEW is not running"
[ -S "$(readlink "$SOCKET")" ] || fail "no socket after restart"

echo "== stop"
out="$("$CODEX" app-server daemon stop)"
echo "$out"
[ "$(field "$out" status)" = stopped ] || fail "stop did not report 'stopped'"
alive "$NEW" && fail "daemon $NEW survived stop"
[ ! -S "$(readlink "$SOCKET" 2>/dev/null || echo /nonexistent)" ] || fail "socket left behind after stop"
out="$("$CODEX" app-server daemon stop)"
[ "$(field "$out" status)" = notRunning ] || fail "second stop did not report 'notRunning': $out"

echo "daemon test: OK"
