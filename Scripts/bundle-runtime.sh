#!/usr/bin/env bash
#
# Fetches a universal (arm64 + x86_64) Node.js runtime and installs the
# `matter-server` npm package into ./Runtime, ready to be embedded in the app.
#
# Output layout:
#   Runtime/node/bin/node        universal Node.js binary (+ npm, lib, ...)
#   Runtime/server/              npm prefix containing node_modules/matter-server
#   Runtime/server/.entry        path (relative to Runtime/server) of the bin JS
#
# Env overrides:
#   NODE_VERSION   e.g. v24.9.0  (default: latest v24.x from nodejs.org)
#   UNIVERSAL=1    build a universal (arm64+x86_64) Node binary
#                  (default: host architecture only, ~half the size)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"
DIST="https://nodejs.org/dist"

echo "==> Resolving Node.js version"
if [[ -z "${NODE_VERSION:-}" ]]; then
  NODE_VERSION="$(curl -fsSL "$DIST/index.json" \
    | python3 -c 'import json,sys; print(next(r["version"] for r in json.load(sys.stdin) if r["version"].startswith("v24.")))')"
fi
echo "    Using Node.js $NODE_VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

download_arch() {
  local arch="$1"
  local tarball="node-${NODE_VERSION}-darwin-${arch}.tar.gz"
  echo "==> Downloading $tarball"
  curl -fsSL "$DIST/${NODE_VERSION}/${tarball}" -o "$WORK/$tarball"
  tar -xzf "$WORK/$tarball" -C "$WORK"
}

case "$(uname -m)" in
  arm64) HOST_ARCH=arm64 ;;
  *)     HOST_ARCH=x64 ;;
esac

download_arch "$HOST_ARCH"

echo "==> Assembling Node runtime"
rm -rf "$RUNTIME/node"
mkdir -p "$RUNTIME"
cp -R "$WORK/node-${NODE_VERSION}-darwin-${HOST_ARCH}" "$RUNTIME/node"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  OTHER_ARCH=$([[ "$HOST_ARCH" == "arm64" ]] && echo x64 || echo arm64)
  download_arch "$OTHER_ARCH"
  lipo -create \
    "$WORK/node-${NODE_VERSION}-darwin-arm64/bin/node" \
    "$WORK/node-${NODE_VERSION}-darwin-x64/bin/node" \
    -output "$RUNTIME/node/bin/node"
fi
echo "    node binary: $(lipo -archs "$RUNTIME/node/bin/node")"

NODE="$RUNTIME/node/bin/node"
NPM_CLI="$RUNTIME/node/lib/node_modules/npm/bin/npm-cli.js"

echo "==> Installing matter-server (production deps only)"
rm -rf "$RUNTIME/server"
mkdir -p "$RUNTIME/server"
"$NODE" "$NPM_CLI" install matter-server --omit=dev --prefix "$RUNTIME/server" --no-audit --no-fund

echo "==> Recording server entry point"
# matter-server ships no `bin`; the runnable entry is its `main` (MatterServer.js,
# which parses CLI args via cli.js). Prefer bin if a future version adds one.
"$NODE" -e '
  const path = require("path");
  const prefix = process.argv[1];
  const pkgPath = path.join(prefix, "node_modules/matter-server/package.json");
  const pkg = require(pkgPath);
  let entry = pkg.bin;
  if (entry && typeof entry === "object") entry = entry["matter-server"] || Object.values(entry)[0];
  if (!entry) entry = pkg.main;
  if (!entry) throw new Error("matter-server package.json has neither bin nor main");
  process.stdout.write(path.join("node_modules/matter-server", entry));
' "$RUNTIME/server" > "$RUNTIME/server/.entry"
echo "    entry: $(cat "$RUNTIME/server/.entry")"

echo "==> Slimming runtime (removing build-time-only files)"
# npm/corepack and C headers are only needed at build time; the app launches
# `node` directly on the server entry.
rm -rf "$RUNTIME/node/include" "$RUNTIME/node/share" \
       "$RUNTIME/node/lib/node_modules/npm" "$RUNTIME/node/lib/node_modules/corepack" \
       "$RUNTIME/node/CHANGELOG.md" "$RUNTIME/node/README.md"
rm -f "$RUNTIME/node/bin/npm" "$RUNTIME/node/bin/npx" "$RUNTIME/node/bin/corepack"
# Source maps and TypeScript declarations are not used at runtime.
find "$RUNTIME/server/node_modules" -type f \
  \( -name '*.map' -o -name '*.d.ts' -o -name '*.d.ts.map' -o -name '*.ts' \) -delete 2>/dev/null || true

echo "==> Done. Runtime is at $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
