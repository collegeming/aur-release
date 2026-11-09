#!/usr/bin/env bash
# Build mark-shot for x86_64 inside an Arch Linux container and emit a pacman
# package under $OUT_DIR.
#
# The container runs as root, and both cmake and makepkg behave badly under
# root, so all building happens as an unprivileged "builder" user.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${OUT_DIR:-$(pwd)/dist}"

if [ -z "${MARK_SHOT_TAG:-}" ]; then
    # Capture resolve's output first: piping straight into a JSON parser turns a
    # clean "HTTP 403" from the updater into an unreadable JSONDecodeError.
    if ! RESOLVED=$(python3 tools/update_package.py resolve "packages/${PKGNAME}"); then
        echo "::error::could not resolve the upstream version; see the error above" >&2
        exit 1
    fi
    MARK_SHOT_TAG=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
    echo "==> resolved upstream tag: ${MARK_SHOT_TAG}"
fi

TAG="$MARK_SHOT_TAG"
VERSION="${TAG#v}"
echo "==> building ${PKGNAME} ${VERSION} for x86_64"

# pacman 7+ sandboxes downloads with Landlock and drops to the 'alpm' user.
# The runner kernel lacks Landlock support, which aborts every database sync
# with "restricting filesystem access failed". This container is disposable and
# already root, so disable the sandbox. DisableSandbox is an [options]
# directive -- appending it to the file would land in whatever section is last,
# where pacman ignores it.
awk '
  /^\[options\][[:space:]]*$/ && !done { print; print "DisableSandbox"; done=1; next }
  /^[[:space:]]*DisableSandbox[[:space:]]*$/ { next }
  { print }
' /etc/pacman.conf > /etc/pacman.conf.new && mv /etc/pacman.conf.new /etc/pacman.conf
export PACMAN_DISABLE_SANDBOX=1
id alpm >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/bin/nologin alpm 2>/dev/null || true

pacman -Syu --noconfirm --needed \
    base-devel cmake ninja pkgconf git curl python \
    pipewire ffmpeg qt6-base qt6-svg qt6-wayland layer-shell-qt rust

id builder >/dev/null 2>&1 || useradd -m builder

WORK=$(mktemp -d)
chmod 777 "$WORK"
cd "$WORK"

run_as_builder() {
    # HOME is set explicitly: `su` without `-` keeps the parent's environment,
    # and rust/cargo/cmake all read HOME for their caches.
    su builder -s /bin/bash -c "cd '$WORK' && HOME=/home/builder $1"
}

git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" src
chown -R builder:builder "$WORK"

STAGE="$WORK/stage"

run_as_builder '
cmake -S src -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON
cmake --build build --parallel
cmake --install build --prefix stage/usr
'
mkdir -p "$STAGE/usr/share/licenses/${PKGNAME}"
install -m644 "$WORK/src/LICENSE" "$STAGE/usr/share/licenses/${PKGNAME}/LICENSE"
[ -f "$WORK/src/README.md" ] && install -Dm644 "$WORK/src/README.md" "$STAGE/usr/share/doc/${PKGNAME}/README.md"

# Soname-pinned FFmpeg deps: pacman then refuses to install on a system whose
# FFmpeg generation differs, instead of failing later at runtime.
mapfile -t SONAMES < <(ldd "$STAGE/usr/bin/mark-shot" 2>/dev/null \
    | grep -oE 'lib(av|sw)[a-z]+\.so\.[0-9]+' | sort -u || true)
echo "==> linked ffmpeg sonames: ${SONAMES[*]:-none}"

{
    echo "pkgname = ${PKGNAME}"
    echo "pkgver = ${VERSION}-1"
    echo "pkgdesc = Qt 6 Wayland screenshot selection and annotation tool (built against Arch Linux x86_64)"
    echo "url = https://github.com/${UPSTREAM_REPO}"
    echo "builddate = $(date +%s)"
    echo "packager = aur-release <noreply@github.com>"
    echo "size = $(du -sb "$STAGE/usr" | cut -f1)"
    echo "arch = x86_64"
    echo "license = MIT"
    for d in qt6-base qt6-svg qt6-wayland layer-shell-qt pipewire grim wl-clipboard hicolor-icon-theme python; do
        echo "depend = $d"
    done
    for so in "${SONAMES[@]:-}"; do
        [ -n "$so" ] || continue
        # "libavcodec.so.63" -> "libavcodec.so=63-64": pacman wants the library
        # name (minus the numeric suffix) plus the exact soname version.
        base="${so%.so.*}"
        ver="${so##*.}"
        echo "depend = ${base}.so=${ver}-64"
    done
    echo "provides = mark-shot"
    echo "conflicts = mark-shot mark-shot-bin"
} > "$STAGE/.PKGINFO"

mkdir -p "$OUT_DIR"
ASSET="${PKGNAME}-${VERSION}-1-x86_64.pkg.tar.zst"
bsdtar --zstd -C "$STAGE" -cf "${OUT_DIR}/${ASSET}" .PKGINFO usr
sha256sum "${OUT_DIR}/${ASSET}" | sed "s| .*/| |" > "${OUT_DIR}/${ASSET}.sha256"

echo "==> built ${ASSET}"
ls -la "$OUT_DIR"
