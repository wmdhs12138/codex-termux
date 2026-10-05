#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux-docker (see .github/workflows/build.yml).
set -Eeuo pipefail
# Say which command failed: a bare `set -e` exit leaves no trace in the CI log.
trap 'echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $?)" >&2' ERR

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
VERSION="${CODEX_VERSION_INPUT:-}"

echo "::group::Install Termux build dependencies"
# The image's default mirror (repository.su) lags: it served rust 1.97.1 while the
# official repository has 1.99.0, and std needs rustc >= 1.98 for File::lock on
# Android. Pin the official repository instead of whatever the image picked.
echo 'deb https://packages.termux.dev/apt/termux-main stable main' > "$PREFIX/etc/apt/sources.list"
pkg update -y
# sed, not python: python is not installed yet at this point.
RUST_MIN="$(sed -n 's/.*"rust_min": *"\([^"]*\)".*/\1/p' versions.json)"
[ -n "$RUST_MIN" ] || { echo "bionic-build: rust_min missing from versions.json" >&2; exit 1; }
RUST_CAND="$(apt-cache policy rust | awk '/Candidate:/{print $2}')"
echo "rust candidate: $RUST_CAND (need >= $RUST_MIN)"
if [ "$(printf '%s\n%s\n' "$RUST_MIN" "${RUST_CAND%%-*}" | sort -V | head -1)" != "$RUST_MIN" ]; then
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
test "$ACTUAL" = "$VERSION"

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

# The interactive TUI must start without the shared daemon. Upstream auto-starts
# it, which needs the official package layout and aborts with "no complete local
# package"; patch 0004 turns that off on Android. Run it on a pty and check the
# first screen: it must enter the alternate screen instead of printing the error.
rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"
set +e
timeout -s KILL 10 script -qfec "$CODEX" work/tui-smoke.raw </dev/null >/dev/null 2>&1
set -e
strings -n 4 work/tui-smoke.raw > work/tui-smoke.txt
if grep -q 'no complete local package' work/tui-smoke.txt; then
  echo "smoke: TUI tried to use the shared daemon" >&2
  exit 1
fi
grep -q '?1049h' work/tui-smoke.txt

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
  MOCK_KEY=x timeout 90 "$CODEX" exec --skip-git-repo-check \
    -c 'model_provider="mock"' -c 'model_providers.mock.name="mock"' \
    -c "model_providers.mock.base_url=\"http://127.0.0.1:$MOCK_PORT/v1\"" \
    -c 'model_providers.mock.wire_api="responses"' -c 'model_providers.mock.env_key="MOCK_KEY"' \
    -c 'model_providers.mock.supports_websockets=false' \
    "$@" </dev/null
  set -e
}

# 1. A code-mode-only model must still be given usable tools. Android has no V8, so
# codex-code-mode-host is not built and, unpatched, the model only sees `exec` (the
# JS entry point) and cannot run a single command. Tools may be declared in the
# top-level `tools` array or, for "responses lite" models such as gpt-6.x, inside an
# `additional_tools` input item; tests/tool_names.py reads both.
mock_start "$ROOT/work/mock-tools"
mock_exec --enable code_mode_only "say hi" >work/mock-exec.txt 2>&1
mock_stop
tail -5 work/mock-exec.txt
TOOLS="$(python3 "$ROOT/tests/tool_names.py" "$ROOT/work/mock-tools/out/request-1.json")"
echo "tools sent to the model: $TOOLS"
printf '%s' "$TOOLS" | python3 -c '
import json, sys
names = json.load(sys.stdin)
assert "exec_command" in names, "code-mode-only model was given no shell tool: %s" % names
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

# Informational: DNS + TLS + HTTP upgrade against the real endpoint. Not
# asserted, because a datacenter IP may be rate limited or blocked.
"$CODEX" doctor >work/doctor.txt 2>&1 || true
sed -n '/Connectivity/,/Background Server/p' work/doctor.txt | head -30

# Dynamic dependencies must stay within what a stock Termux provides.
readelf -d "$CODEX" | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | sort > work/needed.txt
cat work/needed.txt
if grep -v -x -E 'libc\.so|libm\.so|libdl\.so|liblog\.so|libssl\.so\.[0-9.]+|libcrypto\.so\.[0-9.]+|liblzma\.so\.[0-9.]+' work/needed.txt; then
  echo "smoke: unexpected shared library dependency (listed above)" >&2
  exit 1
fi
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
