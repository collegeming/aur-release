#!/usr/bin/env bash
# Build mark-shot for aarch64 against Arch Linux ARM on a NATIVE arm64 runner.
#
# The ALARM rootfs is imported as a container image and the build runs inside a
# container from it. Docker supplies working DNS, /proc, /dev and a writable
# /tmp; a hand-rolled chroot needed each of those bolted on and the container
# avoids the failure modes (resolv.conf symlink, root-owned /root, bind mounts).
# Since the runner is arm64, the container runs natively: minutes, not the hours
# the QEMU path took (it exceeded GitHub's 6-hour job limit).
#
# The upstream aarch64 asset cannot be used instead: it is linked against
# Ubuntu's FFmpeg 6 (libavcodec.so.60) and ALARM ships FFmpeg 9 (.so.63), so
# pacman refuses to install it. See jswysnemc/mark-shot#155.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
WORK="$(pwd)/.arm-build"
IMAGE_TAG="mark-shot-alarm-build:latest"
ROOTFS_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"

# --------------------------------------------------------------------------- #
# Resolve the newest stable upstream tag
# --------------------------------------------------------------------------- #
if [ -z "${MARK_SHOT_TAG:-}" ]; then
    if ! RESOLVED=$(python3 - "$UPSTREAM_REPO" <<'PY'
import json, os, sys, urllib.request
repo = sys.argv[1]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases?per_page=30",
    headers={"User-Agent": "aur-release", "Accept": "application/vnd.github+json"})
tok = os.environ.get("GITHUB_TOKEN")
if tok:
    req.add_header("Authorization", f"Bearer {tok}")
print(f"resolve: repo={repo} token={'set' if tok else 'UNSET'}", file=sys.stderr)
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        status = resp.status
        body = resp.read().decode()
except urllib.error.HTTPError as e:
    print(f"resolve: HTTP {e.code}: {e.read().decode()[:200]}", file=sys.stderr); sys.exit(1)
except Exception as e:
    print(f"resolve: network error: {e}", file=sys.stderr); sys.exit(1)
rels = json.loads(body)
print(f"resolve: HTTP {status}, got {len(rels)} releases, first: {[x['tag_name'] for x in rels[:5]]}",
      file=sys.stderr)
tag = None
for r in rels:
    if not r.get("draft") and not r.get("prerelease"):
        tag = r["tag_name"]; break
if not tag:
    print(f"resolve: NO STABLE RELEASE among {len(rels)}; cannot build", file=sys.stderr); sys.exit(1)
print(tag)
PY
    ); then
        echo "::error::could not resolve the upstream version; see the error above" >&2
        exit 1
    fi
    # resolve prints the bare tag (diagnostics go to stderr) -- no JSON here.
    MARK_SHOT_TAG="$RESOLVED"
fi

TAG="$MARK_SHOT_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for aarch64 (native arm64 runner + ALARM container)"

mkdir -p "$WORK" "$OUT_DIR"

# --------------------------------------------------------------------------- #
# 1. Turn the ALARM rootfs into an arm64 container image
# --------------------------------------------------------------------------- #
# Must run as root: the tarball carries root-owned entries, setuid helpers and
# capability xattrs that a non-root extraction cannot create.
if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "==> fetching Arch Linux ARM rootfs"
    curl -fsSL --retry 3 -o "$WORK/alarm.tar.gz" "$ROOTFS_URL"
    ls -la "$WORK/alarm.tar.gz"

    sudo rm -rf "$WORK/rootfs"
    sudo mkdir -p "$WORK/rootfs"
    sudo tar --numeric-owner -xzf "$WORK/alarm.tar.gz" -C "$WORK/rootfs" \
        || { echo "::error::rootfs extraction failed" >&2; exit 1; }
    [ -x "$WORK/rootfs/usr/bin/pacman" ] \
        || { echo "::error::rootfs incomplete: pacman missing" >&2; exit 1; }

    # Write the tar as a file rather than piping: `sudo tar | docker import`
    # needs root on one side and the runner user on the other, and the pipe
    # silently yields nothing useful if either end lacks permission.
    sudo tar --numeric-owner -C "$WORK/rootfs" -cf "$WORK/rootfs.tar" .
    docker import -c 'CMD ["/bin/bash"]' "$WORK/rootfs.tar" "$IMAGE_TAG"
    sudo rm -f "$WORK/rootfs.tar"
    echo "==> image ready: $IMAGE_TAG"
fi

# --------------------------------------------------------------------------- #
# 2. Clone upstream at the tag
# --------------------------------------------------------------------------- #
echo "==> cloning upstream ${TAG}"
rm -rf "$WORK/src"
git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" "$WORK/src"

# --------------------------------------------------------------------------- #
# 3. Build inside the ALARM container
# --------------------------------------------------------------------------- #
cat > "$WORK/in-container.sh" <<'INNER'
set -euo pipefail
export HOME=/root

# Values injected by the caller (single-quoted heredoc: no shell expansion above).
PKGNAME="${PKGNAME:?}"
VERSION="${VERSION:?}"
UPSTREAM_REPO="${UPSTREAM_REPO:?}"

# pacman 7+ sandboxes downloads with Landlock and drops to the 'alpm' user.
# GitHub's runner kernel has no Landlock, so every sync aborts with
# "restricting filesystem access failed". Disable the sandbox for this
# throwaway build container.
#
# DisableSandbox is an [options] directive. Appending it to the end of the file
# puts it in whatever section is last (here [aur]), where pacman warns
# "directive 'DisableSandbox' in section 'aur' not recognized" and ignores it,
# so insert it directly after the [options] header instead. Plain awk: the ALARM
# base rootfs has no python3 yet at this point.
awk '
  /^\[options\][[:space:]]*$/ && !done { print; print "DisableSandbox"; done=1; next }
  /^[[:space:]]*DisableSandbox[[:space:]]*$/ { next }
  { print }
' /etc/pacman.conf > /etc/pacman.conf.new && mv /etc/pacman.conf.new /etc/pacman.conf
export PACMAN_DISABLE_SANDBOX=1

# Belt and braces: some pacman builds try to drop to the 'alpm' user even with
# the sandbox disabled. Create it so that path cannot abort the sync.
id alpm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/bin/nologin alpm 2>/dev/null || true

pacman-key --init
pacman-key --populate archlinuxarm
# Refresh the keyring first: a stale keyring makes -Syu fail on signature checks.
pacman -Sy --noconfirm archlinuxarm-keyring || true
pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git libarchive zstd \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland layer-shell-qt rust

# /src is mounted read-only so the checkout stays pristine; build out-of-tree in
# a writable directory, otherwise cmake fails creating /src/build/CMakeFiles.
cmake -S /src -B /build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON \
    -DMARK_SHOT_REQUIRE_LAYER_SHELL=ON
cmake --build /build --parallel
rm -rf /stage
cmake --install /build --prefix /stage/usr

# Files upstream's install step does not place.
mkdir -p /stage/usr/share/licenses/"$PKGNAME"
[ -f /src/LICENSE ] && install -m644 /src/LICENSE /stage/usr/share/licenses/"$PKGNAME"/LICENSE || true
if [ -f /src/README.md ]; then
    mkdir -p /stage/usr/share/doc/"$PKGNAME"
    install -m644 /src/README.md /stage/usr/share/doc/"$PKGNAME"/README.md
fi

# The optional layer-shell plugin must be there: upstream's own aarch64 build
# silently skipped it, and the package declares the runtime dependency.
[ -f /stage/usr/lib/mark-shot/libmark-shot-layer-shell.so ] \
    || { echo "::error::layer-shell plugin was not built" >&2; exit 1; }

# Soname-pinned FFmpeg deps, derived from the binaries actually produced, so
# pacman refuses the package on an FFmpeg generation mismatch instead of
# letting it break at runtime. The main binary does not link FFmpeg itself --
# the recording backend plugin does, so both have to be inspected.
SONAMES=$( { ldd /stage/usr/bin/mark-shot
             for so in /stage/usr/lib/mark-shot/recording/*.so; do ldd "$so"; done
           } 2>/dev/null | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u || true)
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
    for d in qt6-base qt6-svg qt6-wayland layer-shell-qt pipewire grim wl-clipboard hicolor-icon-theme python; do
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

echo "==> building inside the ALARM container (native arm64)"
docker run --rm \
    -e PKGNAME="$PKGNAME" \
    -e VERSION="$VERSION" \
    -e UPSTREAM_REPO="$UPSTREAM_REPO" \
    -v "$WORK/src:/src:ro" \
    -v "$WORK/in-container.sh:/in-container.sh:ro" \
    -v "$OUT_DIR:/out" \
    --entrypoint /bin/bash \
    "$IMAGE_TAG" /in-container.sh

# --------------------------------------------------------------------------- #
# 4. Verify and checksum the package
# --------------------------------------------------------------------------- #
ASSET="${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
if [ ! -f "$OUT_DIR/$ASSET" ]; then
    echo "::error::expected package was not produced: $ASSET" >&2
    ls -la "$OUT_DIR" >&2
    exit 1
fi

sha256sum "$OUT_DIR/$ASSET" | sed "s| .*/| |" > "$OUT_DIR/$ASSET.sha256"
echo "==> built $ASSET"
ls -la "$OUT_DIR"
