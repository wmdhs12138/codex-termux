#!/data/data/com.termux/files/usr/bin/bash
# Runs inside termux-docker (see .github/workflows/build.yml).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${CODEX_VERSION_INPUT:-}"

echo "::group::Install Termux build dependencies"
pkg update -y
apt_options=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
pkg upgrade -y "${apt_options[@]}"
pkg install -y "${apt_options[@]}" \
  rust clang cmake make binutils coreutils curl file git jq openssl liblzma pkg-config \
  protobuf python tar sed gawk util-linux
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
