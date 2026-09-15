#!/usr/bin/env python3
"""aur-release: track upstream GitHub releases and update AUR packages.

Two modes:

  render PACKAGE_DIR       Produce PKGBUILD + .SRCINFO locally (for the
                           one-time AUR web submission and local review).
  update PACKAGE_DIR       Full automation: clone the AUR git repo, compare
                           the latest upstream release against the published
                           pkgver, regenerate PKGBUILD/.SRCINFO and push.

Designed to run inside an `archlinux` container so `makepkg` and `vercmp`
are available. `render` also ships a small pure-Python fallback for `.SRCINFO`
so it works on non-Arch hosts for bootstrap/review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from functools import cmp_to_key
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # pragma: no cover - older interpreters
    tomllib = None  # type: ignore[assignment]

GITHUB_API = "https://api.github.com"
USER_AGENT = "aur-release/1.0"
AUR_GIT = "ssh://aur@aur.archlinux.org/{pkgbase}.git"


class UpdateError(Exception):
    pass


# --------------------------------------------------------------------------- #
# Manifest handling
# --------------------------------------------------------------------------- #
def load_manifest(pkg_dir: Path) -> dict:
    if tomllib is None:
        raise UpdateError("metadata.toml needs Python 3.11+")
    meta_path = pkg_dir / "metadata.toml"
    if not meta_path.is_file():
        raise UpdateError(f"missing manifest: {meta_path}")
    with meta_path.open("rb") as fh:
        meta = tomllib.load(fh)
    return meta


def read_template(pkg_dir: Path) -> str:
    tpl = pkg_dir / "PKGBUILD.template"
    if not tpl.is_file():
        raise UpdateError(f"missing template: {tpl}")
    return tpl.read_text(encoding="utf-8")


# --------------------------------------------------------------------------- #
# GitHub release lookup
# --------------------------------------------------------------------------- #
def api_get(url: str, token: str | None) -> dict:
    req = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"},
    )
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise UpdateError(f"HTTP {exc.code} for {url}") from exc
    except urllib.error.URLError as exc:
        raise UpdateError(f"network error for {url}: {exc.reason}") from exc


def latest_release(owner: str, repo: str, token: str | None) -> dict:
    url = f"{GITHUB_API}/repos/{owner}/{repo}/releases/latest"
    return api_get(url, token)


def resolve_release(meta: dict, token: str | None) -> dict | None:
    """Return the upstream release to package, or None if none is usable.

    Scans the full release list (drafts and prereleases skipped unless
    configured) and picks the release with the *highest version* among those
    that carry every configured asset. Relying on GitHub's `/releases/latest`
    is not safe: it orders by `created_at` (not `published_at`), which ties
    for releases the upstream automation pre-creates, and it happily returns
    a release whose binaries were never uploaded. Returning None lets the
    caller decide whether to wait (update mode) or fail loudly (render mode).

    When `[upstream] prerelease = true`, prereleases are considered too --
    necessary when Linux builds only ship in a prerelease series.
    """
    upstream = meta["upstream"]
    include_prerelease = bool(upstream.get("prerelease"))
    url = (
        f"{GITHUB_API}/repos/{upstream['owner']}/{upstream['repo']}"
        "/releases?per_page=100"
    )
    releases = api_get(url, token)
    if not isinstance(releases, list) or not releases:
        raise UpdateError("no releases returned")

    asset_specs = list((meta.get("assets") or {}).values())

    def usable(release: dict) -> bool:
        if release.get("draft"):
            return False
        if not include_prerelease and release.get("prerelease"):
            return False
        if not release.get("assets"):
            return False
        pkgver = compute_pkgver(meta, release["tag_name"])
        names = {a["name"] for a in release["assets"]}
        return all(
            spec["name"].replace("{pkgver}", pkgver) in names
            for spec in asset_specs
        )

    candidates = [r for r in releases if usable(r)]
    if not candidates:
        return None
    return max(
        candidates,
        key=cmp_to_key(
            lambda a, b: vercmp(
                compute_pkgver(meta, a["tag_name"]),
                compute_pkgver(meta, b["tag_name"]),
            )
        ),
    )


# --------------------------------------------------------------------------- #
# Checksum helpers
# --------------------------------------------------------------------------- #
def sha256_of_url(url: str, token: str | None) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    digest = hashlib.sha256()
    with urllib.request.urlopen(req, timeout=600) as resp:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def asset_digest(asset: dict) -> str | None:
    """Return the sha256 hex digest if GitHub has precomputed one."""
    raw = asset.get("digest") or ""
    if raw.startswith("sha256:"):
        return raw[len("sha256:"):]
    return None


# --------------------------------------------------------------------------- #
# Version handling
# --------------------------------------------------------------------------- #
def tag_to_pkgver(tag: str, strip_prefix: str | None) -> str:
    if strip_prefix and tag.startswith(strip_prefix):
        return tag[len(strip_prefix):]
    return tag


def compute_pkgver(meta: dict, tag: str) -> str:
    """Strip the configured prefix, then sanitize into a valid pkgver.

    AUR pkgver strings must not contain hyphens. The optional `tag.sanitize`
    pair `[pattern, replacement]` (regex, repl) also collapses prerelease
    suffixes like `-beta.3` / `-alpha.5` to `beta3` / `alpha5`, which vercmp
    sorts older than the final release (`1.0alpha < 1.0beta < ... < 1.0rc < 1.0`),
    so a prerelease-tracked package upgrades cleanly once stable ships.
    """
    tag_cfg = meta.get("tag") or {}
    ver = tag_to_pkgver(tag, tag_cfg.get("strip_prefix"))
    sanitize = tag_cfg.get("sanitize")
    if sanitize:
        if not (isinstance(sanitize, list) and len(sanitize) == 2):
            raise UpdateError("tag.sanitize must be [pattern, replacement]")
        ver = re.sub(sanitize[0], sanitize[1], ver)
    return ver


def vercmp(a: str, b: str) -> int:
    """Return -1/0/1 as `a` is older/equal/newer than `b`.

    Uses pacman's vercmp when available (CI container), otherwise a pragmatic
    numeric comparison for bootstrap/review on non-Arch hosts.
    """
    if shutil.which("vercmp"):
        proc = subprocess.run(
            ["vercmp", a, b],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        # pacman's vercmp prints 0 (equal), 1 (a > b), or -1 (a < b) to stdout
        # and always exits 0 -- do NOT check the exit code.
        try:
            return int(proc.stdout.strip())
        except (ValueError, TypeError):
            raise UpdateError(f"vercmp output not parseable: {proc.stdout!r}")

    def key(v: str):
        parts = re.split(r"([0-9]+)", v)
        out = []
        for p in parts:
            if p == "":
                continue
            out.append((1, int(p)) if p.isdigit() else (0, p))
        return out

    ka, kb = key(a), key(b)
    return (ka > kb) - (ka < kb)


def read_pkgver_from_pkgbuild(text: str) -> tuple[str, str] | None:
    """Extract (pkgver, pkgrel) from a PKGBUILD string."""
    pkgver = re.search(r"^\s*pkgver\s*=\s*['\"]?([^'\"\s]+)", text, re.M)
    pkgrel = re.search(r"^\s*pkgrel\s*=\s*([0-9]+)", text, re.M)
    if not pkgver:
        return None
    return pkgver.group(1), (pkgrel.group(1) if pkgrel else "1")


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def render_pkgbuild(template: str, context: dict[str, str]) -> str:
    out = template
    for key, value in context.items():
        out = out.replace("{{" + key + "}}", value)
    # Any leftover placeholder means the template references a variable we
    # did not supply; fail loudly instead of publishing broken metadata.
    leftover = re.findall(r"\{\{(\w+)\}\}", out)
    if leftover:
        raise UpdateError(f"unresolved template placeholders: {leftover}")
    return out


# --------------------------------------------------------------------------- #
# .SRCINFO generation
# --------------------------------------------------------------------------- #
def _is_root() -> bool:
    return os.name == "posix" and getattr(os, "geteuid", lambda: -1)() == 0


def _uid_of(user: str) -> int | None:
    try:
        import pwd
        return pwd.getpwnam(user).pw_uid
    except (ImportError, KeyError):
        return None


def srcinfo_via_makepkg(pkgbuild_path: Path) -> str:
    if not shutil.which("makepkg"):
        raise UpdateError("makepkg not found (needed to generate .SRCINFO)")
    # makepkg's EUID check fires before the --printsrcinfo branch, so it will
    # never run as root. GitHub Action `archlinux` containers run as root, so
    # drop privileges to an unprivileged account for this one invocation:
    # prefer the `builder` user created by the workflow (runuser), then
    # setpriv/nobody, then fakeroot as a last resort (modern fakeroot >= 1.26
    # no-ops when the real user is root — do not rely on it first).
    cmd = ["makepkg", "--printsrcinfo"]
    if _is_root():
        if shutil.which("runuser") and _uid_of("builder") is not None:
            cmd = ["runuser", "-u", "builder", "--", *cmd]
        elif shutil.which("setpriv"):
            cmd = [
                "setpriv", "--reuid=65534", "--regid=65534",
                "--clear-groups", *cmd,
            ]
        elif shutil.which("fakeroot"):
            cmd = ["fakeroot", *cmd]
        else:
            raise UpdateError(
                "running as root and no privilege-dropping tool available "
                "(create a `builder` user or install setpriv)"
            )
    proc = subprocess.run(
        cmd,
        cwd=pkgbuild_path.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise UpdateError(
            f"makepkg --printsrcinfo failed:\n{proc.stderr.strip()}"
        )
    return proc.stdout


def srcinfo_python_fallback(pkgbuild_text: str) -> str:
    """Minimal .SRCINFO emitter for simple prebuilt-binary PKGBUILDs.

    Only used for local bootstrap/review; the CI pipeline always uses
    `srcinfo_via_makepkg` for canonical output.
    """
    fields = {
        "pkgbase": _bash_val(r"^\s*pkgname\s*=\s*([^#\s]+)", pkgbuild_text),
        "pkgdesc": _bash_val(r"^\s*pkgdesc\s*='([^']*)'", pkgbuild_text),
        "pkgver": _bash_val(r"^\s*pkgver\s*=\s*([^#\s]+)", pkgbuild_text),
        "pkgrel": _bash_val(r"^\s*pkgrel\s*=\s*([^#\s]+)", pkgbuild_text),
        "url": _bash_val(r"^\s*url\s*='([^']*)'", pkgbuild_text),
    }
    for key in ("arch", "license", "depends", "provides", "conflicts", "options"):
        values = _bash_arr(key, pkgbuild_text)
        if values is not None:
            fields[key] = values

    src_fields = _bash_arr("source_x86_64", pkgbuild_text, fallback_name="source")
    sums_x86 = _bash_arr("sha256sums_x86_64", pkgbuild_text, fallback_name="sha256sums")
    src_arm = _bash_arr("source_aarch64", pkgbuild_text)
    sums_arm = _bash_arr("sha256sums_aarch64", pkgbuild_text)

    # makepkg --printsrcinfo expands ${pkgver} in source/checksum lines; the
    # pure-Python fallback must do the same so bootstrap output matches CI.
    pkgver = fields.get("pkgver")
    if pkgver:
        def expand(vals):
            return [
                re.sub(r"\$\{pkgver\}", pkgver, v)
                if isinstance(v, str) else v
                for v in (vals or [])
            ]
        src_fields = expand(src_fields)
        src_arm = expand(src_arm)
        sums_x86 = [v for v in (sums_x86 or [])]
        sums_arm = [v for v in (sums_arm or [])]

    lines: list[str] = []
    ordered = [
        "pkgbase", "pkgdesc", "pkgver", "pkgrel", "url",
        "arch", "license", "depends", "provides", "conflicts", "options",
    ]
    pkgbase = fields.pop("pkgbase", None)
    if pkgbase:
        lines.append(f"pkgbase = {pkgbase}")
        for key in ordered:
            if key == "pkgbase" or key not in fields:
                continue
            val = fields[key]
            vals = val if isinstance(val, list) else [val]
            for v in vals:
                lines.append(f"\t{key} = {v}")

    for label, vals in (
        ("source_x86_64", src_fields),
        ("sha256sums_x86_64", sums_x86),
        ("source_aarch64", src_arm),
        ("sha256sums_aarch64", sums_arm),
    ):
        if vals:
            for v in vals:
                lines.append(f"\t{label} = {v}")

    if pkgbase:
        lines.append("")
        lines.append(f"pkgname = {pkgbase}")
    return "\n".join(lines) + "\n"


def _bash_val(pattern: str, text: str) -> str | None:
    m = re.search(pattern, text, re.M)
    return m.group(1) if m else None


def _bash_arr(name: str, text: str, fallback_name: str | None = None) -> list[str] | None:
    m = re.search(rf"^\s*{name}\s*=\s*\((.*?)\)", text, re.M | re.S)
    if not m and fallback_name:
        m = re.search(rf"^\s*{fallback_name}\s*=\s*\((.*?)\)", text, re.M | re.S)
    if not m:
        return None
    return [
        v.strip().strip("'\"")
        for v in m.group(1).split()
        if v.strip() and not v.strip().startswith("#")
    ]


# --------------------------------------------------------------------------- #
# Actions
# --------------------------------------------------------------------------- #
def do_render(pkg_dir: Path, out_dir: Path, token: str | None, tag: str | None) -> None:
    meta = load_manifest(pkg_dir)
    template = read_template(pkg_dir)
    release = resolve_release(meta, token)
    if release is None:
        raise UpdateError(
            "no release with all configured assets (upstream may have "
            "published a tag without binaries yet)"
        )

    if tag is None:
        tag = release["tag_name"]
    pkgver = compute_pkgver(meta, tag)

    # Verify the requested tag actually exists if we fetched latest instead.
    assets_by_name = {a["name"]: a for a in release.get("assets", [])}

    context = {
        "pkgver": pkgver,
        "pkgrel": "1",
        "maintainer": meta.get("maintainer", "You <you@example.com>"),
        "tag": tag,
    }

    sha_arch: dict[str, str] = {}
    for arch, spec in (meta.get("assets") or {}).items():
        name = spec["name"].replace("{pkgver}", pkgver)
        asset = assets_by_name.get(name)
        if asset is None:
            raise UpdateError(f"release asset '{name}' not found for arch {arch}")
        digest = asset_digest(asset)
        checksum = digest or sha256_of_url(asset["browser_download_url"], token)
        sha_arch[arch] = checksum

    context["sha256_x86_64"] = sha_arch.get("x86_64", "")
    context["sha256_aarch64"] = sha_arch.get("aarch64", "")

    pkgbuild = render_pkgbuild(template, context)
    out_dir.mkdir(parents=True, exist_ok=True)
    pkgbuild_path = out_dir / "PKGBUILD"
    pkgbuild_path.write_text(pkgbuild, encoding="utf-8")

    if shutil.which("makepkg"):
        srcinfo = srcinfo_via_makepkg(pkgbuild_path)
    else:
        srcinfo = srcinfo_python_fallback(pkgbuild)
    (out_dir / ".SRCINFO").write_text(srcinfo, encoding="utf-8")

    print(f"rendered {pkgver}-1 -> {out_dir}")


def do_update(
    pkg_dir: Path,
    token: str | None,
    quiet: bool,
    git_env: dict[str, str] | None = None,
) -> int:
    """Update a single AUR package.

    Returns 0 if a new version was pushed, or 2 if the package is already
    current / upstream is older (an idempotent, non-error skip). A genuine
    failure raises UpdateError, which main() reports as exit 1 -- kept
    distinct from 2 so the CI workflow can tell "nothing to do" (green) apart
    from a real error (red).
    """
    meta = load_manifest(pkg_dir)
    template = read_template(pkg_dir)
    pkgbase = meta["pkgname"]
    maintainer = meta.get("maintainer", "You <you@example.com>")

    release = resolve_release(meta, token)
    if release is None:
        print(
            f"{pkgbase}: no upstream release has all configured assets "
            "(upstream published a tag without binaries?); waiting"
        )
        return 2
    tag = release["tag_name"]
    newver = compute_pkgver(meta, tag)

    # --- clone current AUR state ------------------------------------------ #
    repo_url = AUR_GIT.format(pkgbase=pkgbase)
    workdir = Path(tempfile.mkdtemp(prefix=f"aur-{pkgbase}-"))
    env = dict(_base_env(pkg_dir), **(git_env or {}))
    _run_git(["clone", "--depth", "1", repo_url, str(workdir)], env, quiet)

    current_pkgbuild = workdir / "PKGBUILD"
    published: tuple[str, str] | None = None
    if current_pkgbuild.is_file():
        published = read_pkgver_from_pkgbuild(current_pkgbuild.read_text(encoding="utf-8"))

    # --- decide whether a new version must be built ----------------------- #
    if published is not None:
        oldver, oldrel = published
        cmp = vercmp(newver, oldver)
        if cmp == 0:
            print(f"{pkgbase}: already at {oldver}-{oldrel}; nothing to do")
            shutil.rmtree(workdir, ignore_errors=True)
            return 2
        if cmp < 0:
            print(
                f"{pkgbase}: upstream {newver} is older than published "
                f"{oldver}; skipping (manual intervention?)"
            )
            shutil.rmtree(workdir, ignore_errors=True)
            return 2
        newrel = "1"
    else:
        newrel = "1"

    # --- render fresh PKGBUILD + .SRCINFO --------------------------------- #
    assets_by_name = {a["name"]: a for a in release.get("assets", [])}
    context = {
        "pkgver": newver,
        "pkgrel": newrel,
        "maintainer": maintainer,
        "tag": tag,
    }
    for arch, spec in (meta.get("assets") or {}).items():
        name = spec["name"].replace("{pkgver}", newver)
        asset = assets_by_name.get(name)
        if asset is None:
            raise UpdateError(f"release asset '{name}' not found for arch {arch}")
        digest = asset_digest(asset)
        checksum = digest or sha256_of_url(asset["browser_download_url"], token)
        context[f"sha256_{arch}"] = checksum

    pkgbuild_text = render_pkgbuild(template, context)
    (workdir / "PKGBUILD").write_text(pkgbuild_text, encoding="utf-8")
    # The workdir is owned by root (mkdtemp); makepkg runs as an unprivileged
    # user and pre-checks that $BUILDDIR (the cwd) is writable, so open it up.
    # Ephemeral CI container, so 0777 is acceptable.
    os.chmod(workdir, 0o777)
    (workdir / "PKGBUILD").chmod(0o644)
    srcinfo = srcinfo_via_makepkg(workdir / "PKGBUILD")
    (workdir / ".SRCINFO").write_text(srcinfo, encoding="utf-8")

    # --- commit + push ---------------------------------------------------- #
    msg = (
        "Initial import"
        if published is None
        else f"upgpkg: {pkgbase} {newver}-{newrel}\n"
    )
    _run_git(["add", "PKGBUILD", ".SRCINFO"], env, quiet, cwd=workdir)
    _run_git(
        ["-c", "user.name=aur-release bot",
         "-c", "user.email=aur-release@localhost",
         "commit", "-m", msg],
        env,
        quiet,
        cwd=workdir,
    )
    _run_git(["push", "origin", "HEAD:master"], env, quiet, cwd=workdir)

    print(f"{pkgbase}: pushed {newver}-{newrel}")
    shutil.rmtree(workdir, ignore_errors=True)
    return 0


def _base_env(pkg_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    # Identity and host-key checking: the CI workflow places the key and
    # known_hosts under ~/.ssh (overridable for machines that keep them
    # elsewhere). Fall back to the checked-in AUR host keys.
    key = os.environ.get("AUR_SSH_KEY") or os.path.expanduser("~/.ssh/aur_ed25519")
    if not os.path.isfile(key):
        raise UpdateError(
            f"SSH key not found at {key} (set AUR_SSH_KEY); "
            "did the workflow create it?"
        )
    kh = os.environ.get("AUR_KNOWN_HOSTS_FILE") or os.path.expanduser(
        "~/.ssh/known_hosts"
    )
    if not os.path.isfile(kh):
        kh = pkg_dir.parent.parent / "tools" / "known_hosts"
    ssh_opts = ["ssh", "-o IdentitiesOnly=yes", "-o StrictHostKeyChecking=yes"]
    ssh_opts.append(f"-o IdentityFile='{key}'")
    if os.path.isfile(kh):
        ssh_opts.append(f"-o UserKnownHostsFile='{kh}'")
    env["GIT_SSH_COMMAND"] = " ".join(ssh_opts)
    return env


def _run_git(
    args: list[str],
    env: dict[str, str],
    quiet: bool,
    cwd: Path | None = None,
) -> None:
    cmd = ["git", *args]
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE if quiet else None,
        stderr=subprocess.PIPE if quiet else None,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise UpdateError(f"git {' '.join(args)} failed: {detail}")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_render = sub.add_parser("render", help="render files locally for review")
    p_render.add_argument("pkg_dir", type=Path)
    p_render.add_argument("--out", type=Path, default=Path("_render"))
    p_render.add_argument("--tag", help="pin a specific upstream tag")

    p_update = sub.add_parser("update", help="detect, regenerate, and push")
    p_update.add_argument("pkg_dir", type=Path)
    p_update.add_argument("--quiet", action="store_true")

    args = parser.parse_args()
    token = (
        __import__("os").environ.get("GITHUB_TOKEN")
        or __import__("os").environ.get("GH_TOKEN")
    )

    try:
        if args.cmd == "render":
            do_render(args.pkg_dir.resolve(), args.out.resolve(), token, args.tag)
        else:
            return do_update(args.pkg_dir.resolve(), token, args.quiet)
        return 0
    except UpdateError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())