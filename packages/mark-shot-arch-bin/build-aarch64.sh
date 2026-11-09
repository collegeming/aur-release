#!/usr/bin/env bash
# Build mark-shot for aarch64 against Arch Linux ARM, on an x86_64 runner.
#
# Why not use upstream's aarch64 asset: it links against Ubuntu's FFmpeg 6
# (libavcodec.so.60). Arch Linux ARM ships FFmpeg 9 (.so.63), so pacman refuses
# to install it. Building against ALARM itself produces matching sonames.
#
# How: GitHub's ubuntu runners have no aarch64 binfmt handlers by default and no
# free ARM runners for private repos, so this runs the build inside an emulated
# arm64 container. Rather than chroot-ing into a rootfs (which requires the
# static qemu binary to exist *inside* the rootfs for the kernel to find it),
# import the ALARM rootfs as a container image: Docker then supplies the
# emulator at the container level, where binfmt actually resolves it.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${OUT_DIR:-$(pwd)/dist}"
WORK="$(pwd)/.arm-build"
IMAGE_TAG="mark-shot-alarm-build:latest"
ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

if [ -z "${MARK_SHOT_TAG:-}" ]; then
    if ! RESOLVED=$(python3 tools/update_package.py resolve "packages/${PKGNAME}"); then
        echo "::error::could not resolve the upstream version; see the error above" >&2
        exit 1
    fi
    MARK_SHOT_TAG=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
fi

TAG="$MARK_SHOT_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for aarch64 (emulated arm64 container)"

mkdir -p "$WORK" "$OUT_DIR"

# --------------------------------------------------------------------------- #
# 1. arm64 emulation
# --------------------------------------------------------------------------- #
# Runners ship no aarch64 handlers; without this any arm64 exec dies with
# "exec format error". Register unconditionally (idempotent).
echo "==> registering arm64 binfmt"
docker run --rm --privileged tonistiigi/binfmt --install arm64

if ! docker run --rm --platform linux/arm64 alpine uname -m; then
    echo "::error::arm64 emulation unavailable on this runner" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# 2. Turn the ALARM rootfs into an arm64 container image
# --------------------------------------------------------------------------- #
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "==> fetching Arch Linux ARM rootfs (~830MB)"
    curl -fsSL --retry 3 -o "$WORK/alarm.tar.gz" "$ROOTFS_URL"
    ls -la "$WORK/alarm.tar.gz"

    # Unpack as root: the tarball carries root-owned entries, setuid helpers and
    # capability xattrs. The ALARM rootfs already contains /bin/sh and pacman.
    sudo rm -rf "$WORK/rootfs"
    sudo mkdir -p "$WORK/rootfs"
    sudo tar --numeric-owner -xzf "$WORK/alarm.tar.gz" -C "$WORK/rootfs" \
        || { echo "::error::rootfs extraction failed" >&2; exit 1; }

    if [ ! -x "$WORK/rootfs/usr/bin/pacman" ]; then
        echo "::error::rootfs incomplete: pacman missing" >&2
        sudo ls "$WORK/rootfs" >&2
        exit 1
    fi

    echo "==> importing rootfs as an arm64 image"
    # The rootfs has no /proc or /dev; create the mount points the import expects.
    sudo mkdir -p "$WORK/rootfs/proc" "$WORK/rootfs/dev" "$WORK/rootfs/sys" \
                  "$WORK/rootfs/root/src" "$WORK/rootfs/root/stage"

    # Write the tar as a file rather than piping: `sudo tar | docker import`
    # needs root on one side and the runner user on the other, and the pipe
    # silently yields nothing useful if either end lacks permission.
    sudo tar --numeric-owner -C "$WORK/rootfs" -cf "$WORK/rootfs.tar" .
    docker import --platform linux/arm64 -c 'CMD ["/bin/bash"]' \
        "$WORK/rootfs.tar" "$IMAGE_TAG"
    rm -f "$WORK/rootfs.tar"
    echo "==> image ready: $IMAGE_TAG"
fi

# --------------------------------------------------------------------------- #
# 3. Build inside the arm64 image
# --------------------------------------------------------------------------- #
echo "==> cloning upstream ${TAG}"
rm -rf "$WORK/src"
git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/src"

cat > "$WORK/in-container.sh" <<'INNER'
set -euo pipefail
export HOME=/root

# Values injected by the caller (quoted heredoc: no shell expansion above).
PKGNAME="${PKGNAME:?}"
VERSION="${VERSION:?}"
UPSTREAM_REPO="${UPSTREAM_REPO:?}"

pacman-key --init
pacman-key --populate archlinuxarm

# pacman 7+ sandboxes downloads with Landlock and drops to the 'alpm' user.
# GitHub's runner kernel has no Landlock, so every sync aborts with
# "restricting filesystem access failed" and "switching to sandbox user 'alpm'
# failed". Disable the sandbox for this throwaway build container.
#
# DisableSandbox is an [options] directive. Appending it to the end of the file
# puts it in whatever section is last (here [aur]), where pacman warns
# "directive 'DisableSandbox' in section 'aur' not recognized" and ignores it,
# so insert it directly after the [options] header instead.
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("/etc/pacman.conf")
text = p.read_text()
text = re.sub(r"(?m)^\s*DisableSandbox\s*$", "", text)
text = re.sub(r"(?m)^\[options\]\s*$", "[options]\nDisableSandbox", text, count=1)
p.write_text(text)
PY
export PACMAN_DISABLE_SANDBOX=1
awk '/^\[options\]/{f=1} f{print; c++} c>3{exit}' /etc/pacman.conf

# Belt and braces: some pacman builds try to drop to the 'alpm' user even with
# the sandbox disabled. Create it so that path cannot abort the sync.
id alpm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/bin/nologin alpm 2>/dev/null || true

# Refresh the keyring first: a stale keyring makes -Syu fail on signature checks.
pacman -Sy --noconfirm archlinuxarm-keyring || true
pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git libarchive zstd \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland rust

cd /src
cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON
cmake --build build --parallel
rm -rf /stage
cmake --install build --prefix /stage/usr

# Files upstream's install step does not place.
mkdir -p /stage/usr/share/licenses/"$PKGNAME"
[ -f LICENSE ] && install -m644 LICENSE /stage/usr/share/licenses/"$PKGNAME"/LICENSE || true
if [ -f README.md ]; then
    mkdir -p /stage/usr/share/doc/"$PKGNAME"
    install -m644 README.md /stage/usr/share/doc/"$PKGNAME"/README.md
fi

# Soname-pinned FFmpeg deps, derived from the binary actually produced, so
# pacman refuses the package on an FFmpeg generation mismatch instead of
# letting it break at runtime.
SONAMES=$(ldd /stage/usr/bin/mark-shot 2>/dev/null | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u || true)
echo "==> linked ffmpeg sonames: ${SONAMES:-none}"

{
    echo "pkgname = $PKGNAME"
    echo "pkgver = $VERSION-1"
    echo "pkgdesc = Qt 6 Wayland screenshot selection and annotation tool (built against Arch Linux ARM aarch64)"
    echo "url = https://github.com/$UPSTREAM_REPO"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb /stage/usr | cut -f1)"
    echo "arch = aarch64"
    echo "license = MIT"
    for d in qt6-base qt6-svg qt6-wayland pipewire grim wl-clipboard hicolor-icon-theme python; do
        echo "depend = $d"
    done
    while IFS= read -r so; do
        [ -n "$so" ] || continue
        # "libavcodec.so.63" -> "libavcodec.so=63-64"
        echo "depend = ${so%.so.*}.so=${so##*.}-64"
    done <<< "$SONAMES"
    echo "provides = mark-shot"
    echo "conflicts = mark-shot mark-shot-bin"
} > /stage/.PKGINFO

bsdtar --zstd -C /stage -cf "/out/${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst" .PKGINFO usr
chmod 666 "/out/${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
echo "==> packaged $PKGNAME-$VERSION-1-aarch64.pkg.tar.zst"
INNER

echo "==> building inside emulated Arch Linux ARM (slow: Qt6 + Rust under QEMU)"
docker run --rm --privileged --platform linux/arm64 \
    -e PKGNAME="$PKGNAME" \
    -e VERSION="$VERSION" \
    -e UPSTREAM_REPO="$UPSTREAM_REPO" \
    -v "$WORK/src:/src:ro" \
    -v "$WORK/in-container.sh:/in-container.sh:ro" \
    -v "$OUT_DIR:/out" \
    --entrypoint /bin/bash \
    "$IMAGE_TAG" /in-container.sh

ASSET="${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
if [ ! -f "$OUT_DIR/$ASSET" ]; then
    echo "::error::expected package was not produced: $ASSET" >&2
    ls -la "$OUT_DIR" >&2
    exit 1
fi

sha256sum "$OUT_DIR/$ASSET" | sed "s| .*/| |" > "$OUT_DIR/$ASSET.sha256"
echo "==> built $ASSET"
ls -la "$OUT_DIR"
