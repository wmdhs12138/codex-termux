#!/usr/bin/env bash
# Subcommands that need no network and no account, against a fake Responses API.
#
#   tests/test_subcommands.sh /path/to/codex
#
# Everything runs in a throw-away CODEX_HOME under work/. Covers: an MCP server (tests/mcp_echo.py)
# started over stdio and called by the model through Code Mode, `plugin` with a local marketplace
# (add, install, list, remove), the session commands (`exec resume`, `archive`, `unarchive`,
# `delete`), `migrate-rollouts`, `features enable/disable` and `completion`.
set -Eeuo pipefail
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

CODEX="$(readlink -f "$1")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${SUBCOMMANDS_DIR:-$ROOT/work/subcommands}"
rm -rf "$W"; mkdir -p "$W"
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="$W/home"
mkdir -p "$CODEX_HOME"
fail() { echo "subcommands test: $*" >&2; exit 1; }

# A model that calls the MCP tool from a Code Mode script, then answers "ok".
python3 - "$W/script.json" <<'PY'
import json, sys
source = 'const r = await tools.mcp__echo__echo({text: "hello mcp"});\ntext(JSON.stringify(r));\n'
json.dump([[{"type": "custom_tool_call", "id": "ctc_1", "status": "completed", "call_id": "call_exec1",
             "name": "exec", "input": source}]], open(sys.argv[1], "w"))
PY
python3 "$ROOT/tests/mock_responses.py" "$W/out" "$W/port" "$W/script.json" &
MOCK_PID=$!
trap 'rc=$?; kill "$MOCK_PID" 2>/dev/null || true; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT
for _ in $(seq 1 50); do [ -s "$W/port" ] && break; sleep 0.2; done
PORT="$(cat "$W/port")"
cat > "$CODEX_HOME/config.toml" <<TOML
model_provider = "mock"

[model_providers.mock]
name = "mock"
base_url = "http://127.0.0.1:$PORT/v1"
wire_api = "responses"
env_key = "MOCK_KEY"
supports_websockets = false
TOML
export MOCK_KEY=x

echo "== completion"
for shell in bash zsh fish; do
  [ "$("$CODEX" completion "$shell" | wc -l)" -gt 100 ] || fail "completion $shell is too short"
done

echo "== mcp: add, list, call a tool through Code Mode, remove"
"$CODEX" mcp add echo -- python3 "$ROOT/tests/mcp_echo.py" >/dev/null
"$CODEX" mcp list | grep -q '^echo ' || fail "mcp list does not show the server"
"$CODEX" mcp get echo | grep -q 'transport: stdio' || fail "mcp get: wrong transport"
mkdir -p "$W/cwd"
timeout 90 "$CODEX" exec --skip-git-repo-check -C "$W/cwd" "call the echo tool" </dev/null >"$W/exec.txt" 2>&1 || { cat "$W/exec.txt"; fail "codex exec failed"; }
LAST="$(ls "$W/out" | sort -V | tail -1)"
python3 - "$W/out/$LAST" <<'PY' || fail "the model did not get the MCP tool's answer"
import json, sys
outputs = [json.dumps(item["output"]) for item in json.load(open(sys.argv[1]))["input"]
           if item.get("type") in ("custom_tool_call_output", "function_call_output")]
assert any("echo: hello mcp" in o for o in outputs), outputs
print("mcp tool answered: echo: hello mcp")
PY
"$CODEX" mcp remove echo >/dev/null
"$CODEX" mcp list | grep -q 'No MCP servers' || fail "mcp remove left the server behind"

echo "== plugin: local marketplace"
MK="$W/marketplace"
mkdir -p "$MK/.agents/plugins" "$MK/plugins/hello/.codex-plugin" "$MK/plugins/hello/skills/hello"
echo '{"name": "termux-test", "plugins": [{"name": "hello", "source": {"source": "local", "path": "./plugins/hello"}}]}' > "$MK/.agents/plugins/marketplace.json"
echo '{"name": "hello", "description": "Test plugin", "skills": "./skills"}' > "$MK/plugins/hello/.codex-plugin/plugin.json"
printf -- '---\nname: hello\ndescription: Say hello\n---\nSay hello.\n' > "$MK/plugins/hello/skills/hello/SKILL.md"
"$CODEX" plugin marketplace add "$MK" >/dev/null
"$CODEX" plugin list | grep -q 'hello@termux-test *not installed' || fail "plugin list: expected 'not installed'"
"$CODEX" plugin add hello@termux-test >/dev/null
"$CODEX" plugin list | grep -q 'hello@termux-test *installed, enabled' || fail "plugin add did not install it"
[ -d "$CODEX_HOME/plugins/cache/termux-test/hello" ] || fail "no plugin cache directory"
"$CODEX" plugin remove hello@termux-test >/dev/null
"$CODEX" plugin marketplace remove termux-test >/dev/null
"$CODEX" plugin marketplace list | grep -q 'termux-test' && fail "marketplace remove left it behind"

echo "== sessions: resume, archive, unarchive, delete, migrate-rollouts"
SESSION="$(basename "$(ls -t "$CODEX_HOME"/sessions/*/*/*/rollout-*.jsonl | head -1)" .jsonl | sed 's/^rollout-[0-9T-]*-//')"
[ -n "$SESSION" ] || fail "no session was recorded"
timeout 60 "$CODEX" exec --skip-git-repo-check -C "$W/cwd" resume --last "continue" </dev/null >/dev/null 2>&1 || fail "exec resume --last failed"
"$CODEX" archive "$SESSION" | grep -q "Archived session $SESSION" || fail "archive"
"$CODEX" unarchive "$SESSION" | grep -q "Unarchived session $SESSION" || fail "unarchive"
"$CODEX" delete --force "$SESSION" | grep -q "Deleted session $SESSION" || fail "delete"
"$CODEX" migrate-rollouts | grep -q 'Scan complete' || fail "migrate-rollouts"

echo "== features"
"$CODEX" features enable memories | grep -q 'Enabled feature' || fail "features enable"
"$CODEX" features list | grep -q '^memories .*true' || fail "feature not enabled"
"$CODEX" features disable memories | grep -q 'Disabled feature' || fail "features disable"

echo "subcommands test: OK"
