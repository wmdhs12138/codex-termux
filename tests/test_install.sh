#!/usr/bin/env bash
# Offline tests for install.sh. Needs only bash, tar, sha256sum and python3, so it runs on any
# CI runner as well as on a device. Releases are small stand-ins laid out like the real ones.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REAL_TAR="$(command -v tar)"
mkdir -p "$T/bin"

fail() { echo "FAIL: $*" >&2; exit 1; }

mk_release() {   # mk_release <dir> <with_host:0|1> <label>
  local dir="$1" with_host="$2" label="$3" stage="$T/stage"
  rm -rf "$stage"; mkdir -p "$dir" "$stage"
  # Also plays the shared background server's CLI: STUB_DAEMON is what `daemon version`
  # reports, STUB_LOG collects the restarts.
  cat > "$stage/codex" <<STUB
#!/bin/sh
case "\$*" in
  "app-server daemon version") echo "{\"status\":\"\${STUB_DAEMON:-notRunning}\"}"; exit 0 ;;
  "app-server daemon restart") [ -n "\${STUB_RESTART_FAILS:-}" ] && { echo "boom: \$STUB_RESTART_FAILS" >&2; exit 1; }; echo "restart $label" >> "\${STUB_LOG:-/dev/null}"; exit 0 ;;
esac
echo "codex-cli 0.160.0 ($label)"
STUB
  chmod +x "$stage/codex"
  local members="codex"
  if [ "$with_host" = 1 ]; then
    printf '#!/bin/sh\necho "host %s"\n' "$label" > "$stage/codex-code-mode-host"
    chmod +x "$stage/codex-code-mode-host"
    members="codex codex-code-mode-host"
  fi
  echo LICENSE > "$stage/LICENSE"; echo NOTICE > "$stage/NOTICE"; echo THIRD_PARTY > "$stage/THIRD_PARTY.md"
  # shellcheck disable=SC2086
  "$REAL_TAR" -C "$stage" -czf "$dir/codex-termux-aarch64.tar.gz" $members LICENSE NOTICE THIRD_PARTY.md
  (cd "$dir" && sha256sum codex-termux-aarch64.tar.gz > codex-termux-aarch64.tar.gz.sha256)
  python3 - "$stage" "$dir" "$with_host" <<'PY'
import hashlib, json, pathlib, sys
stage, out, with_host = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3] == "1"
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = {"codex": "0.160.0", "binary_sha256": sha(stage / "codex")}
if with_host:
    manifest["host_sha256"] = sha(stage / "codex-code-mode-host")
(out / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
}

run_install() {  # run_install <release dir> [PATH prefix]; prints the installer's output
  CODEX_TERMUX_ALLOW_UNSUPPORTED=1 CODEX_TERMUX_SKIP_DEPS=1 \
  CODEX_TERMUX_BASE_URL="file://$1" CODEX_TERMUX_INSTALL_DIR="$T/bin" \
  PATH="${2:+$2:}$PATH" bash "$ROOT/install.sh" 2>&1
}

expect_files() { [ "$(ls "$T/bin" | tr '\n' ' ')" = "$1 " ] || fail "$2: expected [$1], found [$(ls "$T/bin" | tr '\n' ' ')]"; }

mk_release "$T/new" 1 new
mk_release "$T/old" 0 old

echo "1) fresh install of a release with the host"
run_install "$T/new" >/dev/null
expect_files "codex codex-code-mode-host" "fresh install"
"$T/bin/codex" | grep -q '(new)' || fail "fresh install: wrong codex"

echo "2) nothing changed: quiet no-op, no download"
out="$(run_install "$T/new")"
echo "$out" | grep -q 'already up to date' || fail "second run was not a no-op: $out"
echo "$out" | grep -q 'downloading' && fail "second run downloaded again"

echo "3) host missing: reinstalled"
rm "$T/bin/codex-code-mode-host"
run_install "$T/new" >/dev/null
expect_files "codex codex-code-mode-host" "host restore"

echo "4) host modified: replaced"
echo tamper >> "$T/bin/codex-code-mode-host"
run_install "$T/new" >/dev/null
[ "$("$T/bin/codex-code-mode-host")" = "host new" ] || fail "tampered host was not replaced"

echo "5) an older release without a host: the stale host is removed"
run_install "$T/old" >/dev/null
expect_files "codex" "downgrade"

echo "6) regression: a slow 'tar -t' must not make the host look absent"
# The real tarball starts with a ~300 MB binary, so listing its members is slow. With
# `set -o pipefail`, `tar -t | grep -q` then fails with SIGPIPE once grep has matched and
# exited while tar is still writing, and the installer deleted the host instead of
# installing it. Emulate the slowness deterministically with a tar that lists lazily.
mkdir -p "$T/shim"
cat > "$T/shim/tar" <<SHIM
#!/usr/bin/env bash
case " \$* " in
  *" -tzf "*) "$REAL_TAR" "\$@" | while IFS= read -r line; do printf '%s\n' "\$line"; sleep 0.3; done ;;
  *) exec "$REAL_TAR" "\$@" ;;
esac
SHIM
chmod +x "$T/shim/tar"
echo "stale-host" > "$T/bin/codex-code-mode-host"
run_install "$T/new" "$T/shim" >/dev/null
[ "$("$T/bin/codex-code-mode-host")" = "host new" ] || fail "slow tar listing: the host was dropped or not updated"

echo "7) a running shared server is restarted onto the new release"
export STUB_LOG="$T/daemon.log"; : > "$STUB_LOG"
export CODEX_HOME="$T/home"; mkdir -p "$CODEX_HOME/app-server-daemon"; : > "$CODEX_HOME/app-server-daemon/daemon.pid"
STUB_DAEMON=running run_install "$T/old" >/dev/null
[ "$(cat "$STUB_LOG")" = "restart old" ] || fail "running server: expected one restart by the new codex, got [$(cat "$STUB_LOG")]"

echo "8) nothing changed: the running server is left alone"
STUB_DAEMON=running run_install "$T/old" >/dev/null
[ "$(cat "$STUB_LOG")" = "restart old" ] || fail "no-op install restarted the server"

echo "9) a stale pid file (server not running): no restart"
: > "$STUB_LOG"
STUB_DAEMON=notRunning run_install "$T/new" >/dev/null
[ ! -s "$STUB_LOG" ] || fail "restarted a server that is not running"

echo "10) no server state at all: the server is never queried"
rm -rf "$CODEX_HOME/app-server-daemon"
STUB_DAEMON=running run_install "$T/old" >/dev/null
[ ! -s "$STUB_LOG" ] || fail "restarted without any server state"

echo "11) CODEX_TERMUX_SKIP_DAEMON_RESTART=1 opts out"
mkdir -p "$CODEX_HOME/app-server-daemon"; : > "$CODEX_HOME/app-server-daemon/daemon.pid"
CODEX_TERMUX_SKIP_DAEMON_RESTART=1 STUB_DAEMON=running run_install "$T/new" >/dev/null
[ ! -s "$STUB_LOG" ] || fail "opt-out ignored"

echo "12) a failed restart is reported with its reason, and does not fail the install"
mkdir -p "$CODEX_HOME/app-server-daemon"; : > "$CODEX_HOME/app-server-daemon/daemon.pid"
out="$(STUB_RESTART_FAILS=because STUB_DAEMON=running run_install "$T/old")" || fail "a failed restart failed the install"
echo "$out" | grep -q 'could not restart it' || fail "no warning for the failed restart: $out"
echo "$out" | grep -q 'boom: because' || fail "the reason was swallowed: $out"
[ "$("$T/bin/codex")" = "codex-cli 0.160.0 (old)" ] || fail "the release was not installed"

echo "install.sh: all scenarios passed"
