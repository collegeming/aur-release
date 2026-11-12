#!/usr/bin/env bash
# Build mark-shot for aarch64 against Arch Linux ARM.
#
# Runs on a NATIVE arm64 GitHub runner (ubuntu-24.04-arm), so no emulation is
# needed: the ALARM rootfs is entered with plain chroot and everything compiles
# natively. This is minutes, not the hours the QEMU path took (it exceeded
# GitHub's 6-hour job limit on an x86_64 runner).
#
# The upstream aarch64 asset cannot be used instead: it is linked against
# Ubuntu's FFmpeg 6 (libavcodec.so.60) and ALARM ships FFmpeg 9 (.so.63), so
# pacman refuses to install it. See jswysnemc/mark-shot#155.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"
ROOTDIR="$(pwd)/alarm-rootfs"
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
echo "==> building ${PKGNAME} ${VERSION} for aarch64 (native ARM runner + ALARM chroot)"

# --------------------------------------------------------------------------- #
# Fetch and unpack the Arch Linux ARM rootfs
# --------------------------------------------------------------------------- #
# Must run as root: the tarball carries root-owned entries, setuid helpers and
# capability xattrs that a non-root extraction cannot create.
sudo mkdir -p "$ROOTDIR"
curl -fsSL --retry 3 -o /tmp/alarm.tar.gz "$ROOTFS_URL"
ls -la /tmp/alarm.tar.gz
sudo tar --numeric-owner -xzf /tmp/alarm.tar.gz -C "$ROOTDIR" \
    || { echo "::error::rootfs extraction failed" >&2; exit 1; }
[ -x "$ROOTDIR/usr/bin/pacman" ] \
    || { echo "::error::rootfs incomplete: pacman missing" >&2; exit 1; }
echo "==> rootfs ready"

# --------------------------------------------------------------------------- #
# Stage sources + inner build script, then chroot in
# --------------------------------------------------------------------------- #
rm -rf "$ROOTDIR/root/src" "$ROOTDIR/root/stage" "$ROOTDIR/out"
sudo mkdir -p "$ROOTDIR/root/src" "$ROOTDIR/root/stage" "$ROOTDIR/out"
sudo git clone --depth 1 --branch "$TAG" \
    "https://github.com/${UPSTREAM_REPO}.git" "$ROOTDIR/root/src"

# Values are baked in here; the inner script never needs them passed in.
sudo tee "$ROOTDIR/root/inner.sh" >/dev/null <<INNER
set -euo pipefail
export HOME=/root

# pacman 7+ Landlock sandbox is unavailable on the runner kernel; same fix as
# the x86_64 side.
awk '
  /^\[options\][[:space:]]*\$/ && !done { print; print "DisableSandbox"; done=1; next }
  /^[[:space:]]*DisableSandbox[[:space:]]*\$/ { next }
  { print }
' /etc/pacman.conf > /etc/pacman.conf.new && mv /etc/pacman.conf.new /etc/pacman.conf
export PACMAN_DISABLE_SANDBOX=1
id alpm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/bin/nologin alpm 2>/dev/null || true

pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git curl \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland layer-shell-qt rust

cd /root/src
cmake -S . -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON \
    -DMARK_SHOT_REQUIRE_LAYER_SHELL=ON
cmake --build build --parallel
cmake --install build --prefix /root/stage/usr

mkdir -p /root/stage/usr/share/licenses/${PKGNAME}
install -m644 /root/src/LICENSE /root/stage/usr/share/licenses/${PKGNAME}/LICENSE
if [ -f /root/src/README.md ]; then
    mkdir -p /root/stage/usr/share/doc/${PKGNAME}
    install -m644 /root/src/README.md /root/stage/usr/share/doc/${PKGNAME}/README.md
fi

# Soname-pinned FFmpeg deps, read from the binary actually produced.
SONAMES=\$(ldd /root/stage/usr/bin/mark-shot 2>/dev/null | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u || true)
echo "==> linked ffmpeg sonames: \${SONAMES:-none}"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Qt 6 Wayland screenshot selection and annotation tool (built against Arch Linux ARM aarch64)"
    echo "url = https://github.com/${UPSTREAM_REPO}"
    echo "builddate = \$(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = \$(du -sb /root/stage/usr | cut -f1)"
    echo "arch = aarch64"
    echo "license = MIT"
    for d in qt6-base qt6-svg qt6-wayland layer-shell-qt pipewire grim wl-clipboard hicolor-icon-theme python; do
        echo "depend = \$d"
    done
    while IFS= read -r so; do
        [ -n "\$so" ] || continue
        # "libavcodec.so.63" -> "libavcodec.so=63-64"
        echo "depend = \${so%.so.*}.so=\${so##*.}-64"
    done <<< "\$SONAMES"
    echo "provides = mark-shot"
    echo "conflicts = mark-shot mark-shot-bin"
} > /root/stage/.PKGINFO

bsdtar --zstd -C /root/stage -cf /out/${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst .PKGINFO usr
chmod 666 /out/${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst
echo "==> packaged ${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
INNER

echo "==> building inside ALARM chroot (native arm64, minutes not hours)"
for d in proc dev sys; do
    sudo mount --bind "/$d" "$ROOTDIR/$d"
done
sudo cp /etc/resolv.conf "$ROOTDIR/etc/resolv.conf"

# `|| RC=$?` keeps set -e from exiting before the bind mounts are undone.
RC=0
sudo chroot "$ROOTDIR" /bin/bash /root/inner.sh || RC=$?

for d in sys dev proc; do
    sudo umount "$ROOTDIR/$d" 2>/dev/null || true
done
[ "$RC" -eq 0 ] || exit "$RC"

# --------------------------------------------------------------------------- #
# Collect the finished package
# --------------------------------------------------------------------------- #
ASSET="${PKGNAME}-${VERSION}-1-aarch64.pkg.tar.zst"
[ -f "$ROOTDIR/out/$ASSET" ] \
    || { echo "::error::expected $ASSET was not produced" >&2; exit 1; }
sudo cp "$ROOTDIR/out/$ASSET" "$OUT_DIR/"
sudo chown "$(id -u):$(id -g)" "$OUT_DIR/$ASSET"
sha256sum "$OUT_DIR/$ASSET" | sed "s| .*/| |" > "$OUT_DIR/$ASSET.sha256"

echo "==> built $ASSET"
ls -la "$OUT_DIR"
