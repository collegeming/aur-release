#!/usr/bin/env bash
# Build genoffice for x86_64 inside the Arch container.
#
# Upstream already ships an x86_64 .deb, but building both arches here keeps the
# two packages identical (same layout, same runtime deps) and means the AUR
# package never depends on a foreign distribution's packaging conventions.
set -euo pipefail

PKGNAME="genoffice-arch-bin"
UPSTREAM_REPO="genspark-ai/genoffice"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
WORK="$(pwd)/.genoffice-build"
ARCH="x86_64"

# The job bootstraps git/nodejs/python; npm and the Rust toolchain are ours.
# electron-builder needs base-devel's make/gcc for any native npm module and
# cargo for the xlsx-sidecar.
# libxcrypt-compat: electron-builder's bundled fpm (ruby) needs libcrypt.so.1,
# which Arch only provides through this compatibility package.
pacman -S --noconfirm --needed npm rust base-devel libxcrypt-compat

# --------------------------------------------------------------------------- #
# Resolve the newest stable upstream tag
# --------------------------------------------------------------------------- #
if [ -z "${GENOFFICE_TAG:-}" ]; then
    if ! RESOLVED=$(python3 tools/update_package.py resolve "packages/${PKGNAME}"); then
        echo "::error::could not resolve the upstream version; see the error above" >&2
        exit 1
    fi
    GENOFFICE_TAG=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
fi

TAG="$GENOFFICE_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for ${ARCH} (Arch container)"

mkdir -p "$WORK" "$OUT_DIR"
rm -rf "$WORK/src"
git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/src"

# --------------------------------------------------------------------------- #
# Build the app (Vite bundle + Rust xlsx-sidecar) and package a .deb
# --------------------------------------------------------------------------- #
cd "$WORK/src"
npm ci --no-audit --no-fund
npm run notices
npm run build:all

cd apps/shell
# -c.extraMetadata.version makes the packaged app report the release version
# instead of the workspace version pinned in package.json.
npx electron-builder --linux deb \
    -c.extraMetadata.version="$VERSION"

DEB=$(find "$WORK/src/apps/shell/release" -maxdepth 1 -name 'genoffice_*_amd64.deb' | head -1)
[ -n "$DEB" ] || { echo "::error::electron-builder produced no amd64 deb" >&2; ls -la "$WORK/src/apps/shell/release" >&2; exit 1; }
echo "==> built deb: $DEB"

# --------------------------------------------------------------------------- #
# Turn the .deb payload into a pacman package
# --------------------------------------------------------------------------- #
STAGE="$WORK/stage"
ROOT="$STAGE/root"
rm -rf "$STAGE"
mkdir -p "$ROOT"
cd "$STAGE"
bsdtar -xf "$DEB" data.tar.*
bsdtar -xf data.tar.* -C "$ROOT"

# Convenience wrapper, matching what the official deb's desktop entry expects.
mkdir -p "$ROOT/usr/bin"
ln -s /opt/GenOffice/genoffice "$ROOT/usr/bin/genoffice"

# The .deb ships no license text.
install -Dm644 "$WORK/src/LICENSE" "$ROOT/usr/share/licenses/${PKGNAME}/LICENSE"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Free, open-source AI office suite: docs, sheets, slides, PDF and markdown editors (built from source)"
    echo "url = https://genoffice.ai/"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb "$ROOT" | cut -f1)"
    echo "arch = ${ARCH}"
    echo "license = Apache-2.0"
    for d in alsa-lib at-spi2-core gtk3 libcups libnotify libsecret libxss libxtst nss util-linux-libs xdg-utils; do
        echo "depend = $d"
    done
    echo "optdepend = libappindicator: tray icon support"
    echo "provides = genoffice"
    # pacman's .PKGINFO key is singular "conflict".
    echo "conflict = genoffice"
    echo "conflict = genoffice-bin"
} > "$ROOT/.PKGINFO"

ASSET="${PKGNAME}-${VERSION}-1-${ARCH}.pkg.tar.zst"
bsdtar --zstd -C "$ROOT" -cf "$OUT_DIR/${ASSET}" .PKGINFO opt usr
sha256sum "$OUT_DIR/${ASSET}" | sed "s| .*/| |" > "$OUT_DIR/${ASSET}.sha256"

echo "==> built ${ASSET}"
ls -la "$OUT_DIR"
