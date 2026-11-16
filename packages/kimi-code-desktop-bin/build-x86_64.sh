#!/usr/bin/env bash
# Build kimi-code-desktop-bin for x86_64 inside the Arch container.
#
# The vendor ships Linux only for x86_64 (the update feed has no arm64 entry),
# so this artifact is a faithful repack of the official .deb: unpack the
# payload, add the Arch launcher and license links, emit a pacman package.
# The aarch64 script does the harder part (swap in the official Electron arm64
# runtime and rebuild node-pty).
set -euo pipefail

PKGNAME="kimi-code-desktop-bin"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
WORK="$(pwd)/.kimi-build"
ARCH="x86_64"

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
# Fetch and verify the vendor .deb
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

# --------------------------------------------------------------------------- #
# Stage the payload in the layout the packaged app expects
# --------------------------------------------------------------------------- #
ROOT="$WORK/root"
mkdir -p "$ROOT/opt" "$ROOT/usr/bin" "$ROOT/usr/share/licenses/${PKGNAME}"
cp -a "$WORK/vendor/opt/Kimi Code" "$ROOT/opt/"
cp -a "$WORK/vendor/usr/share/." "$ROOT/usr/share/"

# "/opt/Kimi Code" (space included) is where the bundled Electron looks for its
# resources.
ln -s "/opt/Kimi Code/kimi-code" "$ROOT/usr/bin/kimi-code"

# Electron refuses to start unless the sandbox helper is root-owned setuid when
# user namespaces are unavailable; the bit is simply unused where they work.
chmod 4755 "$ROOT/opt/Kimi Code/chrome-sandbox"

# The Electron/Chromium notices ship inside the app directory; link them rather
# than duplicating them under /usr/share/licenses.
ln -s "/opt/Kimi Code/LICENSE.electron.txt" \
    "$ROOT/usr/share/licenses/${PKGNAME}/LICENSE.electron.txt"
ln -s "/opt/Kimi Code/LICENSES.chromium.html" \
    "$ROOT/usr/share/licenses/${PKGNAME}/LICENSES.chromium.html"

# --------------------------------------------------------------------------- #
# Emit the pacman package
# --------------------------------------------------------------------------- #
{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Kimi Code Desktop - GUI client for the Kimi Code agent (prebuilt binary)"
    echo "url = https://kimi.com/code"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb "$ROOT" | cut -f1)"
    echo "arch = ${ARCH}"
    echo "license = LicenseRef-proprietary"
    # The vendor's Debian Depends/Recommends, translated to Arch names. libuuid1
    # maps to util-linux, which is in base, so it is left out.
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
