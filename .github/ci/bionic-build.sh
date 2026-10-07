#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux-docker (see .github/workflows/build.yml).
set -Eeuo pipefail
# Report the failing command (a bare `set -e` exit leaves no trace in the CI log).
# EXIT, not ERR: ERR also fires for commands that are expected to exit non-zero.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
# termux-docker does not reliably hand `docker run -e` variables to the command, so the
# workflow also writes the version into the mounted workspace; prefer the file.
VERSION="$(cat work/codex-version 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="${CODEX_VERSION_INPUT:-}"
echo "bionic-build: requested version='$VERSION' (env='${CODEX_VERSION_INPUT:-<unset>}')"
[ -n "$VERSION" ] || { echo "bionic-build: no version was passed in" >&2; exit 1; }

echo "::group::Install Termux build dependencies"
# The image's default mirror (repository.su) lags: it served rust 1.97.1 while the
# official repository has 1.99.0, and std needs rustc >= 1.98 for File::lock on
# Android. Pin the official repository instead of whatever the image picked.
echo 'deb https://packages.termux.dev/apt/termux-main stable main' > "$PREFIX/etc/apt/sources.list"
# Without this, every `pkg update/upgrade/install` reruns mirror selection (the image has
# no chosen_mirrors) and rewrites sources.list with a random mirror, repository.su included.
export TERMUX_PKG_NO_MIRROR_SELECT=1
pkg update -y
# sed, not python: python is not installed yet at this point.
RUST_MIN="$(sed -n 's/.*"rust_min": *"\([^"]*\)".*/\1/p' versions.json)"
[ -n "$RUST_MIN" ] || { echo "bionic-build: rust_min missing from versions.json" >&2; exit 1; }
RUST_CAND="$(apt-cache policy rust | awk '/Candidate:/{print $2}')"
echo "rust candidate: $RUST_CAND (need >= $RUST_MIN)"
SORTED_RUST="$(printf '%s\n%s\n' "$RUST_MIN" "${RUST_CAND%%-*}" | sort -V)"
if [ "${SORTED_RUST%%$'\n'*}" != "$RUST_MIN" ]; then
  echo "bionic-build: repository only offers rust $RUST_CAND, need >= $RUST_MIN" >&2
  exit 1
fi
apt_options=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg upgrade -y "${apt_options[@]}"
# The mirror occasionally serves mismatched package versions (e.g. file vs libmagic);
# retry after a fresh index instead of failing the whole build.
for attempt in 1 2 3; do
  if pkg install -y "${apt_options[@]}" \
       rust clang cmake make binutils coreutils curl git jq openssl liblzma pkg-config \
       protobuf python tar sed gawk util-linux; then
    break
  fi
  [ "$attempt" = 3 ] && { echo "pkg install failed after $attempt attempts" >&2; exit 1; }
  echo "pkg install failed (attempt $attempt); refreshing indexes and retrying"
  sleep 20
  pkg update -y
done
echo "::endgroup::"

cd "$ROOT"
mkdir -p work
VERSION="$VERSION" scripts/build.sh

ACTUAL="$(python3 -c 'import json; print(json.load(open("dist/build-manifest.json"))["codex"])')"
[ "$ACTUAL" = "$VERSION" ] || { echo "bionic-build: manifest says '$ACTUAL' but '$VERSION' was requested" >&2; exit 1; }

echo "::group::Conformance: upstream's code-mode runtime tests on QuickJS"
# The V8 runtime ships ~70 behaviour tests that go through the service API. Run them against
# the QuickJS replacement. Three are expected to differ and are skipped by name:
#   - the two ICU tests format a date in French, but only en-US has locale data here (the Intl
#     overlay falls back to en-US, as the specification prescribes for unsupported locales);
#   - the circular-JSON test pins V8's wording ("Converting circular structure to JSON").
(
  export WORK="$ROOT/work"
  # shellcheck source=../../scripts/cargo-env.sh
  source "$ROOT/scripts/cargo-env.sh"
  cd "$WORK/codex/codex-rs"
  cargo test --release -p codex-code-mode-runtime --message-format short -- \
    --skip date_locale_string_formats_with_icu_data \
    --skip intl_date_time_format_formats_with_icu_data \
    --skip text_helper_surfaces_stringify_errors
)
echo "::endgroup::"

echo "::group::Smoke tests (Bionic, real binary)"
CODEX="$ROOT/dist/codex"
"$CODEX" --version | tee work/version.txt
grep -F "$VERSION" work/version.txt >/dev/null

"$CODEX" --help >/dev/null

# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
export CODEX_HOME="$ROOT/work/codex-home"
rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"

# A fresh CODEX_HOME must start cleanly and report "not logged in" instead of
# crashing on locks, paths or the credential store.
set +e
"$CODEX" login status >work/login-status.txt 2>&1
rc=$?
set -e
cat work/login-status.txt
if [ "$rc" -gt 1 ]; then
  echo "smoke: 'codex login status' exited $rc" >&2
  exit 1
fi
grep -q 'Not logged in' work/login-status.txt

# Credentials must round-trip through the file store.
FAKE_KEY='sk-fake-not-a-real-key-0000000000000000'
printf '%s' "$FAKE_KEY" | "$CODEX" login --with-api-key >/dev/null
"$CODEX" login status >work/login-status2.txt 2>&1
grep -q 'Logged in' work/login-status2.txt
test -s "$CODEX_HOME/auth.json"

# `codex exec` has to get through app-server startup, the state databases and
# the rollout writer lock before it needs the network (this is where upstream
# fails on Android with "lock() not supported"). The fake key stops it at the
# server with a 401, long after those steps. Network-independent on purpose:
# only local side effects are asserted.
set +e
# </dev/null: exec waits for EOF on stdin when it is not a terminal.
timeout 60 "$CODEX" exec --skip-git-repo-check "say hi" </dev/null >work/exec-smoke.txt 2>&1
set -e
head -40 work/exec-smoke.txt
if grep -q -i 'not supported' work/exec-smoke.txt; then
  echo "smoke: exec hit an unsupported-operation error" >&2
  exit 1
fi
grep -q 'OpenAI Codex v' work/exec-smoke.txt
compgen -G "$CODEX_HOME/state_*.sqlite" >/dev/null
test -e "$CODEX_HOME/thread-writer-locks/.coordination.lock"
"$CODEX" logout >/dev/null
test ! -e "$CODEX_HOME/auth.json"

# The interactive TUI with default settings must reach its first screen. As in upstream it
# auto-starts the shared daemon, which aborts with "no complete local package" unless it runs
# from an official package layout; on Android the daemon links its own package (patch 0013).
# Run it on a pty and check the first screen: it must enter the alternate screen instead of
# printing the error. (tests/test_daemon_tui.sh covers the daemon side in detail.)
rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"
set +e
timeout -s KILL 10 script -qfec "$CODEX" work/tui-smoke.raw </dev/null >/dev/null 2>&1
set -e
strings -n 4 work/tui-smoke.raw > work/tui-smoke.txt
if grep -q 'no complete local package' work/tui-smoke.txt; then
  echo "smoke: the TUI could not use the shared daemon" >&2
  exit 1
fi
grep -q '?1049h' work/tui-smoke.txt
# The smoke run left the daemon it started behind; the tests below remove CODEX_HOME.
"$CODEX" app-server daemon stop >/dev/null 2>&1 || true

# --- Tests against a fake Responses API (no network, no account) -----------------
# Codex is pointed at tests/mock_responses.py through a custom provider, so we can
# read the requests it sends and script what the "model" answers.
mock_start() {            # $1 = work dir, $2 = optional script.json
  rm -rf "$1"; mkdir -p "$1"
  python3 "$ROOT/tests/mock_responses.py" "$1/out" "$1/port" ${2:+"$2"} &
  MOCK_PID=$!
  for _ in $(seq 1 50); do [ -s "$1/port" ] && break; sleep 0.2; done
  MOCK_PORT="$(cat "$1/port")"
}
mock_stop() { kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; }
mock_exec() {             # codex exec options..., prompt last
  rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"
  set +e
  MOCK_KEY=x timeout 90 "${MOCK_CODEX:-$CODEX}" exec --skip-git-repo-check \
    -c 'model_provider="mock"' -c 'model_providers.mock.name="mock"' \
    -c "model_providers.mock.base_url=\"http://127.0.0.1:$MOCK_PORT/v1\"" \
    -c 'model_providers.mock.wire_api="responses"' -c 'model_providers.mock.env_key="MOCK_KEY"' \
    -c 'model_providers.mock.supports_websockets=false' \
    "$@" </dev/null
  set -e
}

# 1. Tools offered to a code-mode-only model. With the host next to codex (the normal
# install) the model gets Code Mode's `exec`, like upstream, and no direct shell tool. Without
# the host (an older release, or a damaged install) patch 0005 must fall back to direct tools
# instead of leaving the model unable to run a single command. Tools may be declared in the
# top-level `tools` array or, for "responses lite" models such as gpt-6.x, inside an
# `additional_tools` input item; tests/tool_names.py reads both.
tool_names_for() {        # prints the tool names sent to the model; MOCK_CODEX selects the binary
  mock_start "$ROOT/work/mock-tools"
  mock_exec --enable code_mode_only "say hi" >work/mock-exec.txt 2>&1
  mock_stop
  python3 "$ROOT/tests/tool_names.py" "$ROOT/work/mock-tools/out/request-1.json"
}
TOOLS="$(tool_names_for)"
echo "with the code-mode host:    $TOOLS"
printf '%s' "$TOOLS" | python3 -c '
import json, sys
names = json.load(sys.stdin)
assert "exec" in names and "wait" in names, "Code Mode was not offered although the host is installed: %s" % names
assert "exec_command" not in names, "a code-mode-only model got a direct shell tool next to exec: %s" % names
'
NOHOST="$ROOT/work/nohost"; rm -rf "$NOHOST"; mkdir -p "$NOHOST"; cp "$CODEX" "$NOHOST/codex"
TOOLS="$(MOCK_CODEX="$NOHOST/codex" tool_names_for)"
echo "without the code-mode host: $TOOLS"
printf '%s' "$TOOLS" | python3 -c '
import json, sys
names = json.load(sys.stdin)
assert "exec_command" in names, "code-mode-only model was given no shell tool without the host: %s" % names
'

# 2. apply_patch must work inside the workspace. There is no platform sandbox on
# Android, and upstream only auto-approves a patch when one is available, so with
# approval "never" every patch was rejected ("writing outside of the project"),
# even for a relative path in the working directory. Script the fake model to call
# apply_patch and check that the file really appears.
E2E="$ROOT/work/e2e-patch"; rm -rf "$E2E"; mkdir -p "$E2E/cwd"
cat > "$E2E/script.json" <<'JSON'
[[{"type":"custom_tool_call","id":"ctc_1","status":"completed","call_id":"call_patch1","name":"apply_patch","input":"*** Begin Patch\n*** Add File: patched.txt\n+hello from apply_patch\n*** End Patch\n"}]]
JSON
mock_start "$ROOT/work/mock-patch" "$E2E/script.json"
mock_exec -C "$E2E/cwd" -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"' \
  -c 'model="gpt-5.5"' "create a file" >work/patch-exec.txt 2>&1
mock_stop
tail -6 work/patch-exec.txt
cat "$E2E/cwd/patched.txt"
grep -q 'hello from apply_patch' "$E2E/cwd/patched.txt"

# 2b. ...and the path check must still hold. Patches 0006/0008 let in-workspace patches
# through without a platform sandbox; a patch that targets a path outside the workspace
# has to keep being rejected, otherwise those patches silently removed the only guard.
OUTSIDE="$ROOT/work/outside-guard.txt"; rm -f "$OUTSIDE"
python3 - "$OUTSIDE" > "$E2E/script-outside.json" <<'PY'
import json, sys
patch = "*** Begin Patch\n*** Add File: %s\n+must not be written\n*** End Patch\n" % sys.argv[1]
print(json.dumps([[{"type": "custom_tool_call", "id": "ctc_2", "status": "completed",
                    "call_id": "call_out", "name": "apply_patch", "input": patch}]]))
PY
mock_start "$ROOT/work/mock-outside" "$E2E/script-outside.json"
mock_exec -C "$E2E/cwd" -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"' \
  -c 'model="gpt-5.5"' "write outside the workspace" >work/outside-exec.txt 2>&1
mock_stop
grep -q 'patch rejected' work/outside-exec.txt
[ ! -e "$OUTSIDE" ]

# 3. Web search must default to live. Upstream defaults to cached, which cannot serve
# real-time queries (finance, weather, sports) and only upgrades to live under full
# access; on Android there is no sandbox to protect, so patch 0007 defaults to live.
# An explicit `web_search = "cached"` must still win.
check_web_search() {      # $1 = expected external_web_access (True/False), rest = codex exec options
  EXPECT="$1"; shift
  mock_start "$ROOT/work/mock-web"
  mock_exec -c 'model="gpt-5.5"' "$@" "hi" >work/mock-web.txt 2>&1
  mock_stop
  python3 - "$ROOT/work/mock-web/out/request-1.json" "$EXPECT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
tools = [t for t in d.get("tools", []) if t.get("type") == "web_search"]
assert tools, "no web_search tool was offered: %s" % [t.get("type") for t in d.get("tools", [])]
got = tools[0].get("external_web_access")
print("web_search external_web_access =", got)
assert str(got) == sys.argv[2], "expected %s, got %s" % (sys.argv[2], got)
PY
}
check_web_search True
check_web_search False -c 'web_search="cached"'

# 4. `codex update` must run this project's installer. Upstream does not recognise this
# install (InstallMethod::Other) and bails with "Could not detect the Codex installation
# method"; its standalone action would also fetch the official musl build. Put a fake
# `bash` first on PATH so the command is recorded instead of executed.
FAKEBIN="$ROOT/work/fakebin"; rm -rf "$FAKEBIN"; mkdir -p "$FAKEBIN"
printf '#!%s/bin/sh\necho "FAKE-BASH $*"\n' "$PREFIX" > "$FAKEBIN/bash"; chmod +x "$FAKEBIN/bash"
set +e
PATH="$FAKEBIN:$PATH" "$CODEX" update </dev/null >work/update.txt 2>&1
set -e
cat work/update.txt
grep -q 'wmdhs12138/codex-termux/main/install.sh' work/update.txt
grep -q 'Update ran successfully' work/update.txt

# 5. Code Mode end to end. The QuickJS host runs real scripts: the fake model makes nine `exec`
# calls (text, a nested tool call, store/load across calls, exit(), timers, a runtime error,
# nested apply_patch, Intl) and the checker looks at exactly what the model is sent back for each.
E2E_CM="$ROOT/work/e2e-code-mode"; rm -rf "$E2E_CM"; mkdir -p "$E2E_CM/cwd"
OUTSIDE_NESTED="$ROOT/work/outside-nested.txt"; rm -f "$OUTSIDE_NESTED"
python3 "$ROOT/tests/code_mode_script.py" "$OUTSIDE_NESTED" > "$E2E_CM/script.json"
mock_start "$ROOT/work/mock-code-mode" "$E2E_CM/script.json"
mock_exec -C "$E2E_CM/cwd" -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"' \
  --enable code_mode_only "run the scripts" >work/code-mode-exec.txt 2>&1
mock_stop
tail -4 work/code-mode-exec.txt
LAST="$(ls "$ROOT/work/mock-code-mode/out" | sort -V | tail -1)"
python3 "$ROOT/tests/check_code_mode.py" "$ROOT/work/mock-code-mode/out/$LAST"
# ...and on disk: the patch inside the workspace wrote its file, the one outside did not.
[ "$(cat "$E2E_CM/cwd/nested.txt")" = "nested ok" ]
[ ! -e "$OUTSIDE_NESTED" ]

# 5b. A script that outlives its yield time: `exec` hands back what it has so far with a cell id,
# and `wait` collects the rest. This is the path that crosses the host process and the session
# state the most, and the one real long-running scripts depend on.
E2E_WAIT="$ROOT/work/e2e-code-mode-wait"; rm -rf "$E2E_WAIT"; mkdir -p "$E2E_WAIT/cwd"
python3 "$ROOT/tests/code_mode_wait_script.py" > "$E2E_WAIT/script.json"
mock_start "$ROOT/work/mock-code-mode-wait" "$E2E_WAIT/script.json"
mock_exec -C "$E2E_WAIT/cwd" -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"' \
  --enable code_mode_only "run a long script" >work/code-mode-wait-exec.txt 2>&1
mock_stop
LAST="$(ls "$ROOT/work/mock-code-mode-wait/out" | sort -V | tail -1)"
python3 "$ROOT/tests/check_code_mode_wait.py" "$ROOT/work/mock-code-mode-wait/out/$LAST"

# The shared background server: rendezvous socket under the Termux prefix, /proc identity,
# start / reuse / restart / stop (patches 0011 to 0014).
echo "::group::Shared background server lifecycle"
bash "$ROOT/tests/test_daemon.sh" "$CODEX"
echo "::endgroup::"

# ...and the real thing: a client attaches to the control socket like the TUI does and runs a
# Code Mode turn on the daemon's app-server (QuickJS host found next to codex, nested tools).
echo "::group::Code Mode through the shared background server"
bash "$ROOT/tests/test_daemon_session.sh" "$CODEX"
echo "::endgroup::"

# The TUI itself: it starts the daemon and attaches instead of embedding (the upstream default),
# and the two ways to opt out.
echo "::group::TUI with the shared background server"
bash "$ROOT/tests/test_daemon_tui.sh" "$CODEX"
echo "::endgroup::"

# Subcommands that need no network or account: an MCP server over stdio called through Code
# Mode, plugins from a local marketplace, the session commands, features, completion.
echo "::group::Subcommands"
bash "$ROOT/tests/test_subcommands.sh" "$CODEX"
echo "::endgroup::"

# termux-exec's SELinux context reaches every child (patch 0017). This host has no SELinux, so
# here it checks that nothing is exported; on a phone it checks the real value.
echo "::group::SELinux context for termux-exec"
bash "$ROOT/tests/test_se_context.sh" "$CODEX"
echo "::endgroup::"

# Informational: DNS + TLS + HTTP upgrade against the real endpoint. Not
# asserted, because a datacenter IP may be rate limited or blocked.
"$CODEX" doctor >work/doctor.txt 2>&1 || true
sed -n '/Connectivity/,/Background Server/p' work/doctor.txt | head -30 || true   # informational only

# Dynamic dependencies must stay within what a stock Termux provides.
for binary in "$CODEX" "$ROOT/dist/codex-code-mode-host"; do
  echo "$(basename "$binary"):"
  readelf -d "$binary" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | sort > work/needed.txt
  sed 's/^/  /' work/needed.txt
if grep -v -x -E 'libc\.so|libm\.so|libdl\.so|liblog\.so|libssl\.so\.[0-9.]+|libcrypto\.so\.[0-9.]+|liblzma\.so\.[0-9.]+' work/needed.txt; then
  echo "smoke: unexpected shared library dependency in $(basename "$binary") (listed above)" >&2
  exit 1
fi
done
echo "::endgroup::"

python3 - <<'PY'
import json, os, platform
with open("dist/build-manifest.json") as f:
    doc = json.load(f)
doc["ci_acceptance"] = {
    "runtime": "termux-docker/bionic",
    "termux_docker": os.environ.get("TERMUX_DOCKER_IMAGE", "unknown"),
    "architecture": platform.machine(),
    "version_probe": "pass",
    "smoke": "pass",
}
with open("dist/build-manifest.json", "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

{
  printf 'codex=%s\n' "$ACTUAL"
  printf 'target=android-aarch64\n'
  printf 'runtime=bionic\n'
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'termux_docker=%s\n' "${TERMUX_DOCKER_IMAGE:-unknown}"
  printf 'rustc=%s\n' "$(rustc --version)"
  printf 'android_api=%s\n' "$(getprop ro.build.version.sdk 2>/dev/null || printf unknown)"
} > work/bionic-ci.txt

printf 'bionic-build: OK: Codex %s built and executed in Termux Bionic\n' "$ACTUAL"
