#!/usr/bin/env bash
# The interactive TUI and the shared background server, with Codex's default settings.
#
#   tests/test_daemon_tui.sh /path/to/codex
#
# As in upstream, the TUI starts the shared daemon itself and attaches to it instead of embedding
# an app-server (`features.daemon_auto_start` is on by default). Upstream aborts that path with
# "no complete local package" unless it runs from an official package layout; on Android the
# daemon links its own package (patch 0013). Run the TUI on a pty and check that it reaches its
# first screen without complaining about the shared server, that it left a running, reachable
# daemon behind, and that remote control stays off (it is opt-in, also upstream). Then the two
# ways to opt out of the daemon: `--no-daemon` and `features.daemon_auto_start=false`.
#
# DAEMON_TEST_SEED=1 links the managed package by hand, for a codex built before patch 0013.
set -Eeuo pipefail

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${DAEMON_TUI_DIR:-$ROOT/work/daemon-tui}"
rm -rf "$W"; mkdir -p "$W"
fail() { echo "daemon tui test: $*" >&2; exit 1; }
cleanup() {
  for home in "$W"/*/home; do CODEX_HOME="$home" "$CODEX" app-server daemon stop >/dev/null 2>&1 || true; done
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

# run_tui <name> [codex options...]: the TUI on a pty for 15 s in a fresh CODEX_HOME.
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
run_tui() {
  local name="$1"; shift
  export CODEX_HOME="$W/$name/home"
  mkdir -p "$CODEX_HOME"
  if [ "${DAEMON_TEST_SEED:-0}" = 1 ]; then
    mkdir -p "$CODEX_HOME/packages/app-server-daemon/current/bin"
    ln -s "$CODEX" "$CODEX_HOME/packages/app-server-daemon/current/bin/codex"
  fi
  set +e
  timeout -s KILL 15 script -qfec "$CODEX $*" "$W/$name/tui.raw" </dev/null >/dev/null 2>&1
  set -e
  strings -n 4 "$W/$name/tui.raw" > "$W/$name/tui.txt"
  head -12 "$W/$name/tui.txt"
  # (not `--no-daemon`: `script` prints the command line, and the hint itself says "background server")
  if grep -q -E 'background server|no complete local package' "$W/$name/tui.txt"; then
    fail "$name: the TUI could not start"
  fi
  grep -q '?1049h' "$W/$name/tui.txt" || fail "$name: the TUI never reached its first screen"
}

echo "== default settings: the TUI starts the daemon and attaches to it"
run_tui default
PID="$(jq -er .pid "$CODEX_HOME/app-server-daemon/daemon.pid")" || fail "no daemon pid record: the TUI did not start the daemon"
kill -0 "$PID" 2>/dev/null || fail "the daemon (pid $PID) is not running"
out="$("$CODEX" app-server daemon version)"
echo "$out"
[ "$(jq -er .status <<<"$out")" = running ] || fail "the daemon does not answer on its control socket"
CMDLINE="$(tr '\0' ' ' <"/proc/$PID/cmdline")"
echo "$CMDLINE"
case "$CMDLINE" in
  *--remote-control*) fail "remote control is on by default; it must be opt-in, as in upstream" ;;
esac
"$CODEX" app-server daemon stop >/dev/null

echo "== --no-daemon: the TUI embeds its server and starts no daemon"
run_tui no-daemon --no-daemon
[ ! -e "$CODEX_HOME/app-server-daemon/daemon.pid" ] || fail "--no-daemon still started a daemon"

echo "== features.daemon_auto_start=false: the same through the config"
run_tui config-off -c features.daemon_auto_start=false
[ ! -e "$CODEX_HOME/app-server-daemon/daemon.pid" ] || fail "daemon_auto_start=false still started a daemon"

echo "daemon tui test: OK"
