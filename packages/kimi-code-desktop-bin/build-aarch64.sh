#!/usr/bin/env bash
# Build kimi-code-desktop-bin for aarch64 on a NATIVE arm64 runner.
#
# The vendor publishes no Linux arm64 build, but its Linux x86_64 payload is
# just app code plus a Chromium runtime. This script swaps that runtime for the
# official Electron arm64 build and rebuilds the only native module (node-pty),
# which is the same approach macOS-Terminal/deepseek-harness-desktop-linux uses
# for its macOS payload. Verified end to end: the assembled tree reports
# electron 45.1.0 / arch arm64 and node-pty spawns a pty.
set -euo pipefail

PKGNAME="kimi-code-desktop-bin"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
WORK="$(pwd)/.kimi-build"
ARCH="aarch64"

# bsdtar, unzip and the node-gyp toolchain are not installed on the bare image.
if ! command -v bsdtar >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq libarchive-tools unzip build-essential python3
fi

# --------------------------------------------------------------------------- #
# Resolve the newest version from the vendor's update feed
# --------------------------------------------------------------------------- #
if [ -z "${KIMI_VERSION:-}" ]; then
    if ! RESOLVED=$(python3 tools/update_package.py resolve "packages/${PKGNAME}"); then
        echo "::error::could not resolve the upstream version; see the error above" >&2
        exit 1
    fi
    KIMI_VERSION=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["pkgver"])')
    KIMI_DEB_URL=$(printf '%s' "$RESOLVED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next(a["url"] for a in d["assets"] if a["name"].endswith("-linux-amd64.deb")))
')
    KIMI_DEB_DIGEST=$(printf '%s' "$RESOLVED" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(next(a["digest"] for a in d["assets"] if a["name"].endswith("-linux-amd64.deb")))
')
fi

VERSION="$KIMI_VERSION"
echo "==> building ${PKGNAME} ${VERSION} for ${ARCH}"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT_DIR"

# --------------------------------------------------------------------------- #
# Fetch and verify the vendor .deb (the x86_64 one carries the app payload)
# --------------------------------------------------------------------------- #
DEB="$WORK/kimi_${VERSION}_amd64.deb"
curl -fsSL --retry 3 -o "$DEB" "$KIMI_DEB_URL"

ALGO="${KIMI_DEB_DIGEST%%:*}"
WANT="${KIMI_DEB_DIGEST#*:}"
GOT=$("${ALGO}sum" "$DEB" | cut -d' ' -f1)
if [ "$GOT" != "$WANT" ]; then
    echo "::error::${ALGO} mismatch for ${KIMI_DEB_URL}: ${GOT} != ${WANT}" >&2
    exit 1
fi

mkdir -p "$WORK/deb" "$WORK/vendor"
bsdtar -xf "$DEB" -C "$WORK/deb"
bsdtar -xf "$WORK/deb/"data.tar.* -C "$WORK/vendor"

APPDIR="$WORK/vendor/opt/Kimi Code"

# --------------------------------------------------------------------------- #
# Fetch the matching official Electron arm64 runtime
# --------------------------------------------------------------------------- #
ELECTRON_VER=$(grep -a -o 'Electron/[0-9][0-9.]*' "$APPDIR/kimi-code" | head -1 | cut -d/ -f2)
[ -n "$ELECTRON_VER" ] || { echo "::error::could not read the Electron version from kimi-code" >&2; exit 1; }
echo "==> vendor payload uses Electron ${ELECTRON_VER}"

curl -fsSL --retry 3 -o "$WORK/electron.zip" \
    "https://github.com/electron/electron/releases/download/v${ELECTRON_VER}/electron-v${ELECTRON_VER}-linux-arm64.zip"
mkdir -p "$WORK/electron"
unzip -q "$WORK/electron.zip" -d "$WORK/electron"

# --------------------------------------------------------------------------- #
# Assemble the arm64 tree: vendor app payload + Electron arm64 runtime
# --------------------------------------------------------------------------- #
ROOT="$WORK/root"
mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/licenses/${PKGNAME}"
cp -a "$APPDIR" "$ROOT/opt/"

# The vendor payload's own resources (app.asar, app-update.yml, icons, ...) stay;
# every file the Electron zip provides (the binary, libs, locales, pak files,
# snapshots) is replaced by its arm64 counterpart.
cp -a "$WORK/electron/." "$ROOT/opt/Kimi Code/"
mv "$ROOT/opt/Kimi Code/electron" "$ROOT/opt/Kimi Code/kimi-code"
chmod 0755 "$ROOT/opt/Kimi Code/kimi-code"

if ! file "$ROOT/opt/Kimi Code/kimi-code" | grep -q 'ARM aarch64'; then
    echo "::error::Kimi Code binary is not aarch64 after the runtime swap" >&2
    file "$ROOT/opt/Kimi Code/kimi-code" >&2
    exit 1
fi

cp -a "$WORK/vendor/usr/share/." "$ROOT/usr/share/"

# --------------------------------------------------------------------------- #
# Rebuild node-pty against the Electron arm64 ABI
# --------------------------------------------------------------------------- #
# The packaged app ships only the compiled node-pty (no binding.gyp or src/),
# so build a fresh copy from the published tarball. The version is the one the
# vendor bundled.
PTY_VER=$(printf '%s' "$(python3 - "$ROOT/opt/Kimi Code/resources/app.asar.unpacked/node_modules/node-pty/package.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)")
echo "==> rebuilding node-pty ${PTY_VER} for Electron ${ELECTRON_VER} arm64"

mkdir -p "$WORK/ptybuild"
cd "$WORK/ptybuild"
npm init -y >/dev/null
npm install "node-pty@${PTY_VER}" --ignore-scripts --no-audit --no-fund
cd node_modules/node-pty
npx --yes node-gyp rebuild --arch=arm64 --target="$ELECTRON_VER" \
    --dist-url=https://electronjs.org/headers

PTY_DEST="$ROOT/opt/Kimi Code/resources/app.asar.unpacked/node_modules/node-pty/build/Release/pty.node"
mkdir -p "$(dirname "$PTY_DEST")"
cp build/Release/pty.node "$PTY_DEST"
file "$PTY_DEST" | grep -q 'ARM aarch64' || { echo "::error::pty.node is not aarch64" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Smoke test the assembled runtime
# --------------------------------------------------------------------------- #
export ELECTRON_RUN_AS_NODE=1
"$ROOT/opt/Kimi Code/kimi-code" -e '
  console.log("runtime:", process.versions.electron, process.arch, process.versions.node);
  if (process.arch !== "arm64") process.exit(1);
'
PTY_MODULE="$ROOT/opt/Kimi Code/resources/app.asar.unpacked/node_modules/node-pty" \
"$ROOT/opt/Kimi Code/kimi-code" -e '
  const pty = require(process.env.PTY_MODULE);
  const p = pty.spawn("/bin/sh", ["-c", "printf pty-ok"], { cols: 80, rows: 24 });
  let out = "";
  p.onData(d => { out += d; });
  p.onExit(() => {
    if (out !== "pty-ok") { console.error("unexpected pty output:", JSON.stringify(out)); process.exit(1); }
    process.exit(0);
  });
  setTimeout(() => { console.error("pty timeout:", JSON.stringify(out)); process.exit(1); }, 10000);
'
echo "==> runtime smoke test passed"

# --------------------------------------------------------------------------- #
# Launcher, license links and pacman package
# --------------------------------------------------------------------------- #
ln -s "/opt/Kimi Code/kimi-code" "$ROOT/usr/bin/kimi-code"
# Electron refuses to start unless the sandbox helper is root-owned setuid when
# user namespaces are unavailable; the bit is simply unused where they work.
chmod 4755 "$ROOT/opt/Kimi Code/chrome-sandbox"
ln -s "/opt/Kimi Code/LICENSE.electron.txt" \
    "$ROOT/usr/share/licenses/${PKGNAME}/LICENSE.electron.txt"
ln -s "/opt/Kimi Code/LICENSES.chromium.html" \
    "$ROOT/usr/share/licenses/${PKGNAME}/LICENSES.chromium.html"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Kimi Code Desktop - GUI client for the Kimi Code agent (prebuilt binary, arm64 runtime rebuilt from the official payload)"
    echo "url = https://kimi.com/code"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb "$ROOT" | cut -f1)"
    echo "arch = ${ARCH}"
    echo "license = LicenseRef-proprietary"
    for d in gtk3 libnotify nss libxss libxtst libsecret at-spi2-core xdg-utils; do
        echo "depend = $d"
    done
    echo "optdepend = libappindicator-gtk3: tray icon"
} > "$ROOT/.PKGINFO"

ASSET="${PKGNAME}-${VERSION}-1-${ARCH}.pkg.tar.zst"
bsdtar --zstd -C "$ROOT" -cf "$OUT_DIR/${ASSET}" .PKGINFO opt usr
sha256sum "$OUT_DIR/${ASSET}" | sed "s| .*/| |" > "$OUT_DIR/${ASSET}.sha256"

echo "==> built ${ASSET}"
ls -la "$OUT_DIR"
