#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux-docker (see .github/workflows/build.yml).
set -euo pipefail

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

# A code-mode-only model must still be given usable tools. Android has no V8, so
# codex-code-mode-host is not built and, unpatched, upstream sends `tools: []`:
# the model cannot run a single command. Point exec at a local fake Responses
# API (no network, no account) and read the tool list it actually sends.
MOCK="$ROOT/work/mock"; rm -rf "$MOCK"; mkdir -p "$MOCK"
python3 "$ROOT/tests/mock_responses.py" "$MOCK/out" "$MOCK/port" &
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$MOCK/port" ] && break; sleep 0.2; done
MOCK_PORT="$(cat "$MOCK/port")"
rm -rf "$CODEX_HOME"; mkdir -p "$CODEX_HOME"
set +e
MOCK_KEY=x timeout 60 "$CODEX" exec --skip-git-repo-check --enable code_mode_only \
  -c 'model_provider="mock"' -c 'model_providers.mock.name="mock"' \
  -c "model_providers.mock.base_url=\"http://127.0.0.1:$MOCK_PORT/v1\"" \
  -c 'model_providers.mock.wire_api="responses"' -c 'model_providers.mock.env_key="MOCK_KEY"' \
  -c 'model_providers.mock.supports_websockets=false' \
  "say hi" </dev/null >work/mock-exec.txt 2>&1
set -e
kill "$MOCK_PID" 2>/dev/null || true
wait "$MOCK_PID" 2>/dev/null || true
tail -5 work/mock-exec.txt
# Tools may be declared in the top-level `tools` array or, for "responses lite"
# models such as gpt-6.x, inside an `additional_tools` input item.
TOOLS="$(python3 "$ROOT/tests/tool_names.py" "$MOCK/out/request-1.json")"
echo "tools sent to the model: $TOOLS"
printf '%s' "$TOOLS" | python3 -c '
import json, sys
names = json.load(sys.stdin)
assert "exec_command" in names, "code-mode-only model was given no shell tool: %s" % names
'

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
