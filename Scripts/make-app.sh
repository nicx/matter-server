#!/usr/bin/env bash
#
# Builds MatterServer.app: compiles the Swift executable in release mode and
# assembles a proper .app bundle including the embedded Node.js runtime.
#
# Prerequisite: run Scripts/bundle-runtime.sh first so ./Runtime exists.
#
# Env overrides:
#   CODESIGN_IDENTITY   Developer ID identity for distribution signing.
#                       Defaults to ad-hoc ("-") for local use.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"
APP="$ROOT/dist/MatterServer.app"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ ! -d "$RUNTIME/node" ]]; then
  echo "error: $RUNTIME/node not found — run Scripts/bundle-runtime.sh first." >&2
  exit 1
fi

echo "==> Building release executable"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/MatterServer"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/MatterServer"
cp -R "$RUNTIME" "$APP/Contents/Resources/Runtime"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

echo "==> Code signing (identity: $IDENTITY)"
ENTITLEMENTS="$ROOT/Resources/MatterServer.entitlements"
# Sign nested executables first (inside-out), then the bundle.
# The Node binary MUST carry the JIT entitlements, otherwise the hardened
# runtime forbids V8's executable memory and Node aborts at startup with
# "Failed to reserve virtual memory for CodeRange".
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  -s "$IDENTITY" "$APP/Contents/Resources/Runtime/node/bin/node"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  -s "$IDENTITY" "$APP/Contents/MacOS/MatterServer"
codesign --force --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" \
  -s "$IDENTITY" "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" || true

echo "==> Done: $APP"
echo "    Run with: open \"$APP\"   (look for the icon in the menu bar)"
