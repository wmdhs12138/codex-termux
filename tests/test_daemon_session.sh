#!/usr/bin/env bash
# Code Mode through the shared background server, end to end.
#
#   tests/test_daemon_session.sh /path/to/codex
#
# The daemon is started from a CODEX_HOME whose config points at tests/mock_responses.py, then a
# client (tests/daemon_session.py) attaches to the control socket the way the TUI does and runs
# one turn: the fake model makes the same `exec` calls as the plain `codex exec` Code Mode test,
# so the daemon's app-server must find codex-code-mode-host, run the scripts on QuickJS and
# send the results back, and tests/check_code_mode.py checks them.
#
# DAEMON_TEST_SEED=1 links the managed package by hand, for a codex built before patch 0013.
set -Eeuo pipefail

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${DAEMON_SESSION_DIR:-$ROOT/work/daemon-session}"
rm -rf "$W"; mkdir -p "$W/cwd" "$W/mock"
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="$W/home"
mkdir -p "$CODEX_HOME"
if [ "${DAEMON_TEST_SEED:-0}" = 1 ]; then
  mkdir -p "$CODEX_HOME/packages/app-server-daemon/current/bin"
  ln -s "$CODEX" "$CODEX_HOME/packages/app-server-daemon/current/bin/codex"
fi

OUTSIDE="$W/outside.txt"
python3 "$ROOT/tests/code_mode_script.py" "$OUTSIDE" > "$W/script.json"
python3 "$ROOT/tests/mock_responses.py" "$W/mock/out" "$W/mock/port" "$W/script.json" &
MOCK_PID=$!
cleanup() {
  "$CODEX" app-server daemon stop >/dev/null 2>&1 || true
  kill "$MOCK_PID" 2>/dev/null || true
  wait "$MOCK_PID" 2>/dev/null || true
  if [ -f "$CODEX_HOME/app-server-daemon/daemon.stderr.log" ]; then
    echo "--- daemon.stderr.log (tail)"; tail -20 "$CODEX_HOME/app-server-daemon/daemon.stderr.log"
  fi
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT
for _ in $(seq 1 50); do [ -s "$W/mock/port" ] && break; sleep 0.2; done
PORT="$(cat "$W/mock/port")"

cat > "$CODEX_HOME/config.toml" <<EOF
model_provider = "mock"
sandbox_mode = "workspace-write"
approval_policy = "never"

[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:$PORT/v1"
wire_api = "responses"
env_key = "MOCK_KEY"
supports_websockets = false

[features]
code_mode_only = true
EOF

echo "== start the server (it keeps the environment it is started with)"
MOCK_KEY=x "$CODEX" app-server daemon start
SOCKET="$CODEX_HOME/app-server-control/app-server-control.sock"

echo "== one turn through the control socket"
python3 "$ROOT/tests/daemon_session.py" "$SOCKET" "$W/cwd" "run the scripts"

LAST="$(ls "$W/mock/out" | sort -V | tail -1)"
echo "== check what the model was sent back ($LAST)"
python3 "$ROOT/tests/check_code_mode.py" "$W/mock/out/$LAST"
[ "$(cat "$W/cwd/nested.txt")" = "nested ok" ] || { echo "nested apply_patch inside the workspace did not run" >&2; exit 1; }
[ ! -e "$OUTSIDE" ] || { echo "nested apply_patch outside the workspace was not refused" >&2; exit 1; }

echo "daemon session test: OK"
