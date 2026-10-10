#!/usr/bin/env bash
# The update prompt offers a re-cut (vX.Y.Z-rN) of the running version (patch 0018).
#
#   tests/test_update_prompt.sh /path/to/codex
#
# A re-cut keeps the upstream version, so the TUI tells it apart by binary hash: the background
# update check stores the latest release's hashes and the running binaries' size, mtime and
# hash in $CODEX_HOME/termux-build.json, and the next start offers "X.Y.Z (new build <sha>)"
# when they differ. The cases below need no network: a fresh version.json keeps the background
# check from running, and termux-build.json is written by hand from the real binaries.
#
# Then one check from scratch against github.com: when the latest release is the running version
# it must record the running binaries. Without the network the check cannot run, so that case
# only reports.
set -Eeuo pipefail

CODEX="$(readlink -f "$1")"
HOST="$(dirname "$CODEX")/codex-code-mode-host"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="${UPDATE_PROMPT_DIR:-$ROOT/work/update-prompt}"
rm -rf "$W"; mkdir -p "$W"
VERSION="$("$CODEX" --version | awk '{print $2}')"
fail() { echo "update prompt test: $*" >&2; exit 1; }
cleanup() {
  for home in "$W"/*/home; do CODEX_HOME="$home" "$CODEX" app-server daemon stop >/dev/null 2>&1 || true; done
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || echo "FAILED: $0 line $LINENO: $BASH_COMMAND (exit $rc)" >&2' EXIT

# cache <name> <latest build sha256> [stale] [dismissed label]: a CODEX_HOME whose update check
# just ran and found <sha256> as the latest build of the running version. `stale` records the
# running codex with another mtime, as if it had been replaced since the check.
cache() {
  local home="$W/$1/home"
  mkdir -p "$home"
  python3 - "$home" "$CODEX" "$HOST" "$VERSION" "$2" "${3:-}" "${4:-}" <<'PY'
import datetime, hashlib, json, os, sys
home, codex, host, version, latest, stale, dismissed = sys.argv[1:]
def running(path):
    st = os.stat(path)
    with open(path, "rb") as f:
        sha = hashlib.file_digest(f, "sha256").hexdigest()
    return {"size": st.st_size, "modified_ns": st.st_mtime_ns, "sha256": sha}
state = {"version": version, "binary_sha256": latest, "host_sha256": None,
         "codex": running(codex), "host": running(host) if os.path.exists(host) else None}
if state["host"]:
    state["host_sha256"] = state["host"]["sha256"]
if stale:
    state["codex"]["modified_ns"] -= 1
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
with open(os.path.join(home, "version.json"), "w") as f:
    json.dump({"latest_version": version, "last_checked_at": now,
               "dismissed_version": dismissed or None}, f)
with open(os.path.join(home, "termux-build.json"), "w") as f:
    json.dump(state, f)
PY
}

# run_tui <name> <screen> [--linger S]: the TUI on a pty (tests/tui_capture.py answers the
# terminal queries it waits for) until <screen> is drawn: the update prompt, or onboarding
# ("Welcome"), which comes after it. $W/<name>/tui.txt is what it drew, whitespace removed.
# Not under $PREFIX/tmp: Codex refuses to create its helper binaries in a temp dir.
run_tui() {
  local name="$1" screen="$2"; shift 2
  export CODEX_HOME="$W/$name/home"
  mkdir -p "$CODEX_HOME"
  python3 "$ROOT/tests/tui_capture.py" 30 "$W/$name/tui.txt" --until "$screen" "$@" -- "$CODEX"
  grep -qF "${screen// /}" "$W/$name/tui.txt" \
    || fail "$name: never reached '$screen'; it drew: $(head -c 600 "$W/$name/tui.txt")"
}
PROMPT="Update now (runs"
prompted() { grep -qF "${PROMPT// /}" "$W/$1/tui.txt"; }
offers() { grep -qF "(newbuild${2:0:12})" "$W/$1/tui.txt"; }

CODEX_SHA="$(sha256sum "$CODEX" | cut -d' ' -f1)"
OTHER="$(printf 'f%.0s' $(seq 64))"
echo "codex $VERSION $CODEX_SHA"

echo "== another build of the running version is offered"
cache recut "$OTHER"
run_tui recut "$PROMPT"
offers recut "$OTHER" || fail "recut: the prompt does not name the new build"

echo "== the running build is not"
cache same "$CODEX_SHA"
run_tui same Welcome
! prompted same || fail "same: prompted for the build that is running"
! offers same "$CODEX_SHA" || fail "same: offered the build that is running"

echo "== a binary replaced since the check is not compared against stale hashes"
cache stale "$OTHER" stale
run_tui stale Welcome
! prompted stale || fail "stale: prompted from hashes of a binary that is no longer running"

echo "== dismissing a build dismisses only that build"
cache dismissed "$OTHER" "" "$VERSION (new build ${OTHER:0:12})"
run_tui dismissed Welcome
! prompted dismissed || fail "dismissed: prompted for a dismissed build"
NEXT="$(printf 'e%.0s' $(seq 64))"
cache next "$NEXT" "" "$VERSION (new build ${OTHER:0:12})"
run_tui next "$PROMPT"
offers next "$NEXT" || fail "next: the prompt does not name the new build"

echo "== a check from scratch (needs github.com; reports only when nothing was recorded)"
# Onboarding shows up at once; the check runs beside it, so give it a few seconds.
run_tui fresh Welcome --linger 10
if [ -f "$CODEX_HOME/termux-build.json" ]; then
  python3 - "$CODEX_HOME" "$CODEX_SHA" "$VERSION" <<'PY' || fail "fresh: termux-build.json does not describe the running codex"
import json, os, sys
home, codex_sha, version = sys.argv[1:]
state = json.load(open(os.path.join(home, "termux-build.json")))
latest = json.load(open(os.path.join(home, "version.json")))["latest_version"]
print(f"recorded: latest {state['version']} build {state['binary_sha256'][:12]}, running {state['codex']['sha256'][:12]}")
assert state["version"] == version == latest, (state["version"], version, latest)
assert state["codex"]["sha256"] == codex_sha
PY
elif [ -f "$CODEX_HOME/version.json" ]; then
  LATEST="$(jq -r .latest_version "$CODEX_HOME/version.json")"
  # The version check reached the release, so the build check had the network too.
  [ "$LATEST" != "$VERSION" ] || fail "fresh: the latest release is the running version, but no build was recorded"
  echo "not recorded: the latest release is $LATEST, this is $VERSION"
else
  echo "not recorded: the update check did not complete (network?)"
fi

echo "update prompt test: OK"
