#!/usr/bin/env bash
# Install the prebuilt Bionic AArch64 Codex from GitHub Releases.
set -euo pipefail

REPO="${CODEX_TERMUX_REPO:-wmdhs12138/codex-termux}"
VERSION="${VERSION:-latest}"
DEST="${CODEX_TERMUX_INSTALL_DIR:-${PREFIX:-}/bin}"
ASSET="codex-termux-aarch64.tar.gz"

if [ "${CODEX_TERMUX_ALLOW_UNSUPPORTED:-0}" != "1" ]; then
  [ "$(uname -m)" = "aarch64" ] || { echo "install: AArch64 only (found $(uname -m))" >&2; exit 1; }
  case "${PREFIX:-}" in
    */com.termux/files/usr) ;;
    *) echo "install: run this inside Termux" >&2; exit 1 ;;
  esac
  if [ -x /system/bin/getprop ]; then
    sdk="$(/system/bin/getprop ro.build.version.sdk 2>/dev/null || true)"
    case "$sdk" in
      ''|*[!0-9]*) ;;
      *) [ "$sdk" -ge 28 ] || { echo "install: Android API $sdk is unsupported; API 28+ required" >&2; exit 1; } ;;
    esac
  fi
fi

if [ -n "${CODEX_TERMUX_BASE_URL:-}" ]; then
  BASE="$CODEX_TERMUX_BASE_URL"   # for tests: a directory (file://...) laid out like a release
elif [ "$VERSION" = "latest" ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  V="${VERSION#v}"
  [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$ ]] || { echo "install: bad version '$VERSION'" >&2; exit 2; }
  BASE="https://github.com/$REPO/releases/download/v$V"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A 64-hex string value from the build manifest. Pipelines here must not end in a reader that
# quits early (grep -q, head): under `set -o pipefail` the writer then dies of SIGPIPE and the
# whole pipeline reads as failed. The second grep consumes all of its input.
json_field() {   # json_field <file> <key>
  grep -m1 -o "\"$2\": *\"[0-9a-f]\{64\}\"" "$1" | grep -o '[0-9a-f]\{64\}' || true
}
hash_of() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || true; }

# `codex update` re-runs this script. Skip everything when what is installed is what the
# release ships; compare hashes, not versions, so a re-cut (vX.Y.Z-rN) is picked up. Done
# before touching packages so an up-to-date run stays quiet.
if [ "${CODEX_TERMUX_FORCE:-0}" != "1" ] && [ -x "$DEST/codex" ] \
   && curl -fsSL "$BASE/build-manifest.json" -o "$TMP/build-manifest.json" 2>/dev/null; then
  want="$(json_field "$TMP/build-manifest.json" binary_sha256)"
  want_host="$(json_field "$TMP/build-manifest.json" host_sha256)"
  if [ -n "$want" ] && [ "$want" = "$(hash_of "$DEST/codex")" ] \
     && { [ -z "$want_host" ] || [ "$want_host" = "$(hash_of "$DEST/codex-code-mode-host")" ]; }; then
    echo "install: already up to date ($("$DEST/codex" --version))"
    exit 0
  fi
fi

# The binaries link the Termux OpenSSL and liblzma runtimes.
if [ "${CODEX_TERMUX_SKIP_DEPS:-0}" != "1" ] && command -v pkg >/dev/null 2>&1; then
  pkg install -y openssl liblzma >/dev/null
fi

echo "install: downloading $ASSET ($VERSION)"
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE/$ASSET.sha256" -o "$TMP/$ASSET.sha256"
(cd "$TMP" && sha256sum -c "$ASSET.sha256")

mkdir -p "$DEST"
# Same-directory rename is atomic, so a running codex is never half-replaced.
install_one() {   # install_one <name>
  install -m755 "$TMP/$1" "$DEST/.$1.new.$$"
  mv -f "$DEST/.$1.new.$$" "$DEST/$1"
}

tar -xzf "$TMP/$ASSET" -C "$TMP" codex
# The code-mode host is the JavaScript engine behind `exec`; codex finds it next to itself.
# Older releases have none, and a leftover host from a newer release must not be paired
# with an older codex.
members="$(tar -tzf "$TMP/$ASSET")"   # captured first: `tar -t | grep -q` dies of SIGPIPE
case $'\n'"$members"$'\n' in
  *$'\ncodex-code-mode-host\n'*) has_host=1 ;;
  *) has_host=0 ;;
esac
if [ "$has_host" = 1 ]; then
  tar -xzf "$TMP/$ASSET" -C "$TMP" codex-code-mode-host
  install_one codex-code-mode-host
else
  rm -f "$DEST/codex-code-mode-host"
fi
install_one codex

echo "install: installed $DEST/codex"
"$DEST/codex" --version

# The shared background server (`codex app-server daemon`) keeps running the binary it was
# started from, and new clients would attach to that old server. Restart it onto the release
# that was just installed. Work in progress on it is interrupted, so only a running one.
if [ "${CODEX_TERMUX_SKIP_DAEMON_RESTART:-0}" != "1" ]; then
  home="${CODEX_HOME:-${HOME:-}/.codex}"
  if [ -e "$home/app-server-daemon/daemon.pid" ]; then
    state="$(CODEX_HOME="$home" "$DEST/codex" app-server daemon version 2>/dev/null || true)"
    case "$state" in
      *'"status":"running"'*)
        echo "install: restarting the shared background server on the new release"
        if ! why="$(CODEX_HOME="$home" "$DEST/codex" app-server daemon restart 2>&1)"; then
          echo "install: could not restart it; run: codex app-server daemon restart" >&2
          printf '%s\n' "$why" | tail -3 >&2
        fi ;;
    esac
  fi
fi
