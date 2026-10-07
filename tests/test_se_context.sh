#!/usr/bin/env bash
# Every child Codex starts gets Termux's SELinux context in its environment (patch 0017).
#
#   tests/test_se_context.sh /path/to/codex
#
# termux-exec, the execve hook Termux preloads, reads TERMUX__SE_PROCESS_CONTEXT and otherwise
# fopen()s /proc/self/attr/current. It runs in the forked child before the exec, where a libc
# stdio lock that another thread held at the fork blocks it forever: a daemon child stuck like
# that kept the control socket open, and `daemon restart` could not bring up a new server.
# Codex exports the variable at startup; this checks that it reaches a shell command under
# `shell_environment_policy.inherit = "core"`, an MCP server (whose environment is a fixed
# allow-list) and the shared daemon.
#
# Outside Android's SELinux (termux-docker on a Linux host, where /proc/self/attr/current holds
# an AppArmor label) nothing may be exported: termux-exec would warn about it on every exec.
set -Eeuo pipefail
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${SE_CONTEXT_DIR:-$ROOT/work/se-context}"
rm -rf "$W"; mkdir -p "$W/cwd"
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="$W/home"
mkdir -p "$CODEX_HOME"
fail() { echo "se-context test: $*" >&2; exit 1; }
# Codex has to find the context itself, not inherit it from the shell running the test.
unset TERMUX__SE_PROCESS_CONTEXT

# What termux-exec accepts, with its own pattern.
EXPECTED="$(python3 - <<'PY'
import re
try:
    raw = open("/proc/self/attr/current", "rb").read().decode().rstrip("\0\n")
except OSError:
    raw = ""
print(raw if re.fullmatch(r"u:r:[^\n :]+:s0(:c[0-9]+,c[0-9]+(,c[0-9]+,c[0-9]+)?)?", raw) else "")
PY
)"
echo "expected context: '${EXPECTED}'"

# A model that runs a command and calls the MCP tool from one Code Mode script, then answers "ok".
python3 - "$W/script.json" <<'PY'
import json, sys
source = ("const r = await tools.exec_command({cmd: 'echo \"se-context=[$TERMUX__SE_PROCESS_CONTEXT]\"'});\n"
          'text(JSON.stringify(r));\n'
          'await tools.mcp__echo__echo({text: "hello"});\n')
json.dump([[{"type": "custom_tool_call", "id": "ctc_1", "status": "completed", "call_id": "call_exec1",
             "name": "exec", "input": source}]], open(sys.argv[1], "w"))
PY
python3 "$ROOT/tests/mock_responses.py" "$W/out" "$W/port" "$W/script.json" &
MOCK_PID=$!
cleanup() {
  kill "$MOCK_PID" 2>/dev/null || true
  "$CODEX" app-server daemon stop >/dev/null 2>&1 || true
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT
for _ in $(seq 1 50); do [ -s "$W/port" ] && break; sleep 0.2; done
cat > "$CODEX_HOME/config.toml" <<TOML
model_provider = "mock"

[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:$(cat "$W/port")/v1"
wire_api = "responses"
env_key = "MOCK_KEY"
supports_websockets = false

[shell_environment_policy]
inherit = "core"
TOML
export MOCK_KEY=x

# The MCP server records its environment before it starts serving.
"$CODEX" mcp add echo -- sh -c 'printf %s "$TERMUX__SE_PROCESS_CONTEXT" > "$1"; exec python3 "$2"' \
  sh "$W/mcp-context.txt" "$ROOT/tests/mcp_echo.py" >/dev/null

echo "== a shell command under inherit = \"core\""
timeout 90 "$CODEX" exec --skip-git-repo-check -C "$W/cwd" -c 'sandbox_mode="workspace-write"' \
  -c 'approval_policy="never"' --enable code_mode_only "run it" </dev/null >"$W/exec.txt" 2>&1 \
  || { cat "$W/exec.txt"; fail "codex exec failed"; }
LAST="$(ls "$W/out" | sort -V | tail -1)"
python3 - "$W/out/$LAST" "$EXPECTED" <<'PY' || fail "the command got the wrong context"
import json, re, sys
outputs = " ".join(json.dumps(item["output"]) for item in json.load(open(sys.argv[1]))["input"]
                   if item.get("type") in ("custom_tool_call_output", "function_call_output"))
# The output may quote the command line too; skip the unexpanded "$TERMUX__..." there.
seen = re.findall(r"se-context=\[([^\]\\$]*)\]", outputs)
assert seen, "the command's output is missing: " + outputs[:2000]
assert seen[0] == sys.argv[2], "command saw %r, expected %r" % (seen[0], sys.argv[2])
print("command saw: '%s'" % seen[0])
PY

echo "== an MCP server (allow-listed environment)"
[ -f "$W/mcp-context.txt" ] || fail "the MCP server was not started"
[ "$(cat "$W/mcp-context.txt")" = "$EXPECTED" ] \
  || fail "MCP server saw '$(cat "$W/mcp-context.txt")', expected '$EXPECTED'"
echo "MCP server saw: '$(cat "$W/mcp-context.txt")'"

echo "== the shared daemon"
out="$("$CODEX" app-server daemon start)"
PID="$(jq -er .pid <<<"$out")"
DAEMON="$(tr '\0' '\n' <"/proc/$PID/environ" | sed -n 's/^TERMUX__SE_PROCESS_CONTEXT=//p')"
[ "$DAEMON" = "$EXPECTED" ] || fail "daemon got '$DAEMON', expected '$EXPECTED'"
echo "daemon got: '$DAEMON'"

echo "se-context test: all checks passed"
