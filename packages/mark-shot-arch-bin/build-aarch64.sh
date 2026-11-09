#!/usr/bin/env bash
# Build mark-shot for aarch64 against Arch Linux ARM, on an x86_64 runner.
#
# GitHub's free ARM runners are limited to public repositories, so this builds
# inside an Arch Linux ARM aarch64 rootfs running under QEMU user-mode
# emulation. Emulating the compile is slow (Qt6 + Rust), but it produces a
# package whose FFmpeg sonames match ALARM -- which is the entire point, since
# upstream's own aarch64 asset links against Ubuntu's FFmpeg 6 and cannot be
# installed on ALARM.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${OUT_DIR:-$(pwd)/dist}"
ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
ROOTDIR="${ROOTDIR:-/arch-arm}"

if [ -z "${MARK_SHOT_TAG:-}" ]; then
    MARK_SHOT_TAG=$(python3 tools/update_package.py resolve "packages/${PKGNAME}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
fi

TAG="$MARK_SHOT_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for aarch64 (QEMU + Arch Linux ARM)"

# binfmt_misc lets the kernel transparently run aarch64 ELF binaries.
sudo apt-get update -qq
sudo apt-get install -y -qq qemu-user-static binfmt-support

sudo mkdir -p "$ROOTDIR"
echo "==> fetching ALARM rootfs (this is ~800MB)"
curl -fsSL --retry 3 -o /tmp/alarm.tar.gz "$ROOTFS_URL"
sudo tar -xzf /tmp/alarm.tar.gz -C "$ROOTDIR"

# Bind mounts so pacman and cmake work inside the chroot.
sudo mount --bind /proc "$ROOTDIR/proc" 2>/dev/null || true
sudo mount --bind /dev  "$ROOTDIR/dev"  2>/dev/null || true
sudo mount --bind /sys  "$ROOTDIR/sys"  2>/dev/null || true
sudo cp /etc/resolv.conf "$ROOTDIR/etc/resolv.conf"

SRC_COPY="$ROOTDIR/root/src"
sudo mkdir -p "$SRC_COPY"
sudo git clone --depth 1 --branch "$TAG" \
    "https://github.com/${UPSTREAM_REPO}.git" "$SRC_COPY"

# Everything below runs inside the aarch64 rootfs (through QEMU).
sudo chroot "$ROOTDIR" /bin/bash -c '
set -euo pipefail
export HOME=/root
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git curl \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland layer-shell-qt rust

cd /root/src
cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON
cmake --build build --parallel "$(nproc)"
rm -rf /root/stage
cmake --install build --prefix /root/stage/usr
'

STAGE_HOST="$ROOTDIR/root/stage"
sudo mkdir -p "$STAGE_HOST/usr/share/licenses/${PKGNAME}"
sudo install -m644 "$ROOTDIR/root/src/LICENSE" "$STAGE_HOST/usr/share/licenses/${PKGNAME}/LICENSE" || true
if [ -f "$ROOTDIR/root/src/README.md" ]; then
    sudo mkdir -p "$STAGE_HOST/usr/share/doc/${PKGNAME}"
    sudo install -m644 "$ROOTDIR/root/src/README.md" "$STAGE_HOST/usr/share/doc/${PKGNAME}/README.md"
fi

# Read sonames from inside the rootfs: the host has no aarch64 loader, so ldd
# must run under QEMU in the chroot.
SONAMES=$(sudo chroot "$ROOTDIR" /bin/bash -c \
    "ldd /root/stage/usr/bin/mark-shot 2>/dev/null | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u" || true)
echo "==> linked ffmpeg sonames: ${SONAMES:-none}"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Qt 6 Wayland screenshot selection and annotation tool (built against Arch Linux ARM aarch64)"
    echo "url = https://github.com/${UPSTREAM_REPO}"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(sudo du -sb "$STAGE_HOST/usr" | cut -f1)"
    echo "arch = aarch64"
    echo "license = MIT"
    for d in qt6-base qt6-svg qt6-wayland pipewire grim wl-clipboard hicolor-icon-theme python; do
        echo "depend = $d"
    done
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        # "libavcodec.so.63" -> "libavcodec.so=63-64" (see build-x86_64.sh)
        base="${so%.so.*}"
        echo "depend = ${base}.so=${so##*.}-64"
    done <<< "$SONAMES"
    echo "provides = mark-shot"
    echo "conflicts = mark-shot mark-shot-bin"
} | sudo tee "$STAGE_HOST/.PKGINFO" >/dev/null

mkdir -p "$OUT_DIR"
ASSET="${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
sudo bsdtar --zstd -C "$STAGE_HOST" -cf "${OUT_DIR}/${ASSET}" .PKGINFO usr
sudo chown "$(id -u):$(id -g)" "${OUT_DIR}/${ASSET}"
sha256sum "${OUT_DIR}/${ASSET}" | sed "s| .*/| |" > "${OUT_DIR}/${ASSET}.sha256"

echo "==> built ${ASSET}"
ls -la "$OUT_DIR"
