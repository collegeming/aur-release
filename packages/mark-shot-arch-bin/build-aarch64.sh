#!/usr/bin/env bash
# Build mark-shot for aarch64 against Arch Linux ARM, on an x86_64 runner.
#
# Why not use upstream's aarch64 asset: it is linked against Ubuntu's FFmpeg 6
# (libavcodec.so.60). Arch Linux ARM ships FFmpeg 9 (.so.63), so pacman refuses
# to install it. Building against ALARM itself produces matching sonames, which
# is the entire point of this package.
#
# How: GitHub's free ARM runners are public-repo-only and this repository is
# private, so the build runs as an arm64 container under QEMU emulation. Letting
# Docker handle the emulation (--platform linux/arm64) avoids depending on
# distro qemu packaging or on a hand-placed static emulator.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${OUT_DIR:-$(pwd)/dist}"
WORK="$(pwd)/.arm-build"
ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

if [ -z "${MARK_SHOT_TAG:-}" ]; then
    MARK_SHOT_TAG=$(python3 tools/update_package.py resolve "packages/${PKGNAME}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
fi

TAG="$MARK_SHOT_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for aarch64 (emulated arm64 container)"

mkdir -p "$WORK/rootfs" "$OUT_DIR"

# --------------------------------------------------------------------------- #
# 1. arm64 emulation
# --------------------------------------------------------------------------- #
if ! docker run --rm --platform linux/arm64 alpine uname -m 2>/dev/null | grep -q aarch64; then
    echo "==> registering arm64 binfmt"
    docker run --rm --privileged tonistiigi/binfmt --install arm64
fi
docker run --rm --platform linux/arm64 alpine uname -m

# --------------------------------------------------------------------------- #
# 2. Arch Linux ARM userspace
# --------------------------------------------------------------------------- #
# ALARM publishes a rootfs tarball, not an OCI image, so unpack it and hand it
# to a privileged arm64 container as the chroot target. Docker provides the
# qemu plumbing inside that container, so no static emulator juggling is needed.
if [ ! -x "$WORK/rootfs/usr/bin/pacman" ]; then
    echo "==> fetching Arch Linux ARM rootfs (~830MB)"
    curl -fsSL --retry 3 -o "$WORK/alarm.tar.gz" "$ROOTFS_URL"
    tar -xzf "$WORK/alarm.tar.gz" -C "$WORK/rootfs"
fi

cat > "$WORK/build-in-container.sh" <<'INNER'
set -euo pipefail
export HOME=/root
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland rust

cd /root/src
cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON
cmake --build build --parallel
rm -rf /root/stage
cmake --install build --prefix /root/stage/usr

# License/doc that the install step does not handle.
mkdir -p /root/stage/usr/share/licenses/PKGNAME
install -m644 LICENSE /root/stage/usr/share/licenses/PKGNAME/LICENSE || true
if [ -f README.md ]; then
    mkdir -p /root/stage/usr/share/doc/PKGNAME
    install -m644 README.md /root/stage/usr/share/doc/PKGNAME/README.md
fi
INNER
sed -i "s/PKGNAME/${PKGNAME}/g" "$WORK/build-in-container.sh"
chmod +x "$WORK/build-in-container.sh"

echo "==> cloning upstream ${TAG}"
rm -rf "$WORK/src"
git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/src"

echo "==> building inside emulated Arch Linux ARM (this takes a while)"
docker run --rm --privileged --platform linux/arm64 \
    -v "$WORK/rootfs:/arch" \
    -v "$WORK/src:/root/src:ro" \
    -v "$WORK/build-in-container.sh:/build.sh:ro" \
    alpine chroot /arch /bin/bash /build.sh

# --------------------------------------------------------------------------- #
# 3. Package it
# --------------------------------------------------------------------------- #
STAGE="$WORK/rootfs/root/stage"
if [ ! -x "$STAGE/usr/bin/mark-shot" ]; then
    echo "::error::build produced no mark-shot binary at $STAGE/usr/bin/mark-shot" >&2
    exit 1
fi

SONAMES=$(docker run --rm --privileged --platform linux/arm64 \
    -v "$WORK/rootfs:/arch" alpine chroot /arch /bin/bash -c \
    "ldd /root/stage/usr/bin/mark-shot 2>/dev/null | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u" || true)
echo "==> linked ffmpeg sonames: ${SONAMES:-none}"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Qt 6 Wayland screenshot selection and annotation tool (built against Arch Linux ARM aarch64)"
    echo "url = https://github.com/${UPSTREAM_REPO}"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb "$STAGE/usr" | cut -f1)"
    echo "arch = aarch64"
    echo "license = MIT"
    for d in qt6-base qt6-svg qt6-wayland pipewire grim wl-clipboard hicolor-icon-theme python; do
        echo "depend = $d"
    done
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        # "libavcodec.so.63" -> "libavcodec.so=63-64" (pacman wants name+soname)
        echo "depend = ${so%.so.*}.so=${so##*.}-64"
    done <<< "$SONAMES"
    echo "provides = mark-shot"
    echo "conflicts = mark-shot mark-shot-bin"
} > "$STAGE/.PKGINFO"

ASSET="${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
sudo rm -f "$OUT_DIR/$ASSET" 2>/dev/null || rm -f "$OUT_DIR/$ASSET" 2>/dev/null || true
bsdtar --zstd -C "$STAGE" -cf "$OUT_DIR/$ASSET" .PKGINFO usr
sha256sum "$OUT_DIR/$ASSET" | sed "s| .*/| |" > "$OUT_DIR/$ASSET.sha256"

echo "==> built $ASSET"
ls -la "$OUT_DIR"
