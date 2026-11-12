#!/usr/bin/env bash
# Build mark-shot for x86_64 inside the Arch Linux container and emit a pacman
# package under dist/.
#
# Runs as root; cmake/makepkg misbehave under root, so building happens as an
# unprivileged "builder" user.
set -euo pipefail

PKGNAME="mark-shot-arch-bin"
UPSTREAM_REPO="jswysnemc/mark-shot"
OUT_DIR="${GITHUB_WORKSPACE:-$(pwd)}/dist"

# --------------------------------------------------------------------------- #
# Resolve the newest stable upstream tag
# --------------------------------------------------------------------------- #
if [ -z "${MARK_SHOT_TAG:-}" ]; then
    if ! RESOLVED=$(python3 - "$UPSTREAM_REPO" <<'PY'
import json, os, sys, urllib.error, urllib.request
repo = sys.argv[1]
req = urllib.request.Request(
    f"https://api.github.com/repos/{repo}/releases?per_page=30",
    headers={"User-Agent": "aur-release", "Accept": "application/vnd.github+json"})
tok = os.environ.get("GITHUB_TOKEN")
print(f"resolve: repo={repo} token={'set' if tok else 'UNSET'}", file=sys.stderr)
if tok:
    req.add_header("Authorization", f"Bearer {tok}")
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
echo "==> building ${PKGNAME} ${VERSION} for x86_64"

# --------------------------------------------------------------------------- #
# pacman 7+ sandboxes downloads with Landlock and drops to an 'alpm' user. The
# runner kernel has no Landlock, so every sync aborts. DisableSandbox is an
# [options] directive; appending it to the file would land in the last section
# ([aur]) where pacman ignores it, so insert after the [options] header.
# --------------------------------------------------------------------------- #
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
    # HOME set explicitly: su without - keeps the parent env, and rust/cargo
    # resolve their caches through HOME.
    su builder -s /bin/bash -c "cd '$WORK' && HOME=/home/builder $1"
}

git clone --depth 1 --branch "$TAG" "https://github.com/${UPSTREAM_REPO}.git" src
chown -R builder:builder "$WORK"

run_as_builder '
cmake -S src -B build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DMARK_SHOT_REQUIRE_FFMPEG=ON \
    -DMARK_SHOT_REQUIRE_LAYER_SHELL=ON
cmake --build build --parallel
cmake --install build --prefix stage/usr
'

STAGE="$WORK/stage"
mkdir -p "$STAGE/usr/share/licenses/${PKGNAME}"
install -m644 "$WORK/src/LICENSE" "$STAGE/usr/share/licenses/${PKGNAME}/LICENSE"
[ -f "$WORK/src/README.md" ] && install -Dm644 "$WORK/src/README.md" "$STAGE/usr/share/doc/${PKGNAME}/README.md" || true

# Soname-pinned FFmpeg deps: pacman then refuses to install on a system whose
# FFmpeg generation differs, instead of failing later at runtime. The main
# binary does not link FFmpeg itself -- the recording backend plugin does, so
# both have to be inspected.
mapfile -t SONAMES < <( { ldd "$STAGE/usr/bin/mark-shot"
                          for so in "$STAGE"/usr/lib/mark-shot/recording/*.so; do ldd "$so"; done
                        } 2>/dev/null \
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
        # "libavcodec.so.63" -> "libavcodec.so=63-64"
        echo "depend = ${so%.so.*}.so=${so##*.}-64"
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
