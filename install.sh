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

if [ "$VERSION" = "latest" ]; then
  BASE="https://github.com/$REPO/releases/latest/download"
else
  V="${VERSION#v}"
  [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$ ]] || { echo "install: bad version '$VERSION'" >&2; exit 2; }
  BASE="https://github.com/$REPO/releases/download/v$V"
fi

# The binary links the Termux OpenSSL and liblzma runtimes.
if [ "${CODEX_TERMUX_SKIP_DEPS:-0}" != "1" ] && command -v pkg >/dev/null 2>&1; then
  pkg install -y openssl liblzma >/dev/null
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "install: downloading $ASSET ($VERSION)"
curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET"
curl -fsSL "$BASE/$ASSET.sha256" -o "$TMP/$ASSET.sha256"
(cd "$TMP" && sha256sum -c "$ASSET.sha256")

tar -xzf "$TMP/$ASSET" -C "$TMP" codex
mkdir -p "$DEST"
# Same-directory rename is atomic, so a running codex is never half-replaced.
install -m755 "$TMP/codex" "$DEST/.codex.new.$$"
mv -f "$DEST/.codex.new.$$" "$DEST/codex"

echo "install: installed $DEST/codex"
"$DEST/codex" --version
