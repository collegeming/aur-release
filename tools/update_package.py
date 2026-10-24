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
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
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
# Upstream lookup
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


def http_get_text(url: str, token: str | None = None) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        raise UpdateError(f"HTTP {exc.code} for {url}") from exc
    except urllib.error.URLError as exc:
        raise UpdateError(f"network error for {url}: {exc.reason}") from exc


# --------------------------------------------------------------------------- #
# electron-builder update feeds (used by upstreams with no GitHub releases)
# --------------------------------------------------------------------------- #
def parse_update_feed(text: str) -> dict:
    """Parse the parts of an electron-builder `latest-linux.yml` we need.

    Hand-rolled on purpose: the file is machine-generated with a fixed, flat
    shape, and a YAML dependency would be the only third-party import in this
    script. Anything unexpected raises rather than yielding a bogus version.
    """
    version = _bash_val(r"^version:\s*'?\"?([^'\"\s]+)", text)
    if not version:
        raise UpdateError("update feed has no top-level `version`")
    files: list[dict[str, str]] = []
    current: dict[str, str] = {}
    in_files = False
    for line in text.splitlines():
        if re.match(r"^files:\s*$", line):
            in_files = True
            continue
        if not in_files:
            continue
        if re.match(r"^\S", line):
            # Back at the top level (`path:`, `releaseDate:`, ...): list ended.
            break
        item = line.strip()
        if item.startswith("- "):
            current = {}
            files.append(current)
            item = item[2:]
        if ":" in item:
            key, _, value = item.partition(":")
            if key.strip() in ("url", "sha256", "sha512", "size"):
                current[key.strip()] = value.strip().strip("'\"")
    if not files:
        raise UpdateError("update feed lists no files")
    return {"version": version, "files": files}


def resolve_feed_release(meta: dict, token: str | None) -> dict:
    """Turn an electron-builder feed into the release dict the rest expects.

    Some upstreams publish no GitHub release at all: Kimi Code Desktop only
    exists as vendor-hosted installers, and the sole machine-readable statement
    of "a new version is out" is the feed its own auto-updater reads (named in
    the app's `resources/app-update.yml`). The feed carries the version plus a
    base64 checksum per artifact and version-stamped URLs, so one tiny request
    replaces downloading a 110 MB installer just to see what version it is.
    """
    feed = meta["upstream"].get("feed")
    if not feed:
        raise UpdateError('kind = "electron-updater" needs an [upstream] feed')
    data = parse_update_feed(http_get_text(feed, token))
    version = data["version"]

    assets: list[dict] = []
    for entry in data["files"]:
        rel = entry.get("url")
        if not rel:
            continue
        digest = None
        for algo in ("sha512", "sha256"):
            if entry.get(algo):
                # The feed stores the digest base64-encoded; PKGBUILDs want hex.
                digest = f"{algo}:{base64.b64decode(entry[algo]).hex()}"
                break
        assets.append({
            "name": rel.rsplit("/", 1)[-1],
            "browser_download_url": urllib.parse.urljoin(feed, rel),
            "digest": digest,
        })

    found = {a["name"] for a in assets}
    unresolved = [
        arch
        for arch, spec in (meta.get("assets") or {}).items()
        if not any(name in found for name in asset_candidates(spec, version))
    ]
    if unresolved:
        # A feed always describes exactly one release, so a configured asset
        # being absent means upstream renamed or dropped it -- a hard breakage,
        # not "the release is not out yet".
        raise UpdateError(
            f"feed {feed} has no asset for {', '.join(unresolved)}; "
            f"it lists {sorted(found)}"
        )
    return {
        "tag_name": version,
        "draft": False,
        "prerelease": False,
        "assets": assets,
    }


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

    Releases whose tag the manifest cannot turn into a valid pkgver are not
    candidates (upstreams keep stale odd tags around, e.g. SniShaper's
    `v1.2.4-stable`); they are logged, and only become an error if they leave
    nothing publishable at all.

    Which source is consulted depends on `[upstream] kind` (default
    `github-releases`); `electron-updater` reads a vendor update feed instead,
    for upstreams that never publish GitHub releases at all.
    """
    upstream = meta["upstream"]
    kind = upstream.get("kind", "github-releases")
    if kind == "electron-updater":
        return resolve_feed_release(meta, token)
    if kind != "github-releases":
        raise UpdateError(f"unknown [upstream] kind {kind!r}")
    include_prerelease = bool(upstream.get("prerelease"))
    url = (
        f"{GITHUB_API}/repos/{upstream['owner']}/{upstream['repo']}"
        "/releases?per_page=100"
    )
    releases = api_get(url, token)
    if not isinstance(releases, list) or not releases:
        raise UpdateError("no releases returned")

    asset_specs = list((meta.get("assets") or {}).values())
    rejected: list[str] = []

    def asset_names(arch_spec: dict, pkgver: str) -> list[str]:
        """All acceptable asset names for one arch, newest-first order kept."""
        raw = arch_spec.get("names") or [arch_spec["name"]]
        return [n.replace("{pkgver}", pkgver) for n in raw]

    def match_asset(arch_spec: dict, pkgver: str, available: set[str]) -> str | None:
        for candidate in asset_names(arch_spec, pkgver):
            if candidate in available:
                return candidate
        return None

    def usable(release: dict) -> bool:
        if release.get("draft"):
            return False
        if not include_prerelease and release.get("prerelease"):
            return False
        if not release.get("assets"):
            return False
        try:
            pkgver = compute_pkgver(meta, release["tag_name"])
        except UpdateError:
            rejected.append(release["tag_name"])
            return False
        names = {a["name"] for a in release["assets"]}
        return all(
            match_asset(spec, pkgver, names) is not None
            for spec in asset_specs
        )

    candidates = [r for r in releases if usable(r)]
    if not candidates:
        if rejected:
            raise UpdateError(
                "no release has a usable pkgver; rejected tags: "
                f"{', '.join(sorted(set(rejected))[:5])} "
                "(check [tag] strip_prefix/sanitize)"
            )
        return None
    if rejected:
        # Non-fatal, but must be visible: if upstream ever switches tag format,
        # "ignoring releases" is the only line in the log that says so, and the
        # package would otherwise appear to be up to date.
        print(
            "warning: ignoring release(s) with unusable tags: "
            + ", ".join(sorted(set(rejected))[:5])
        )
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
def checksum_algorithm(meta: dict) -> str:
    """Which checksum the PKGBUILD carries (`[checksum] algorithm`).

    GitHub exposes a sha256 digest per asset; electron-builder feeds expose
    sha512. Declaring it keeps the template's `{{sha512_x86_64}}` placeholder,
    the `sha512sums_x86_64` array and the download fallback in step.
    """
    algo = (meta.get("checksum") or {}).get("algorithm", "sha256")
    if algo not in ("sha256", "sha512"):
        raise UpdateError(f"unsupported [checksum] algorithm {algo!r}")
    return algo


def digest_of_url(url: str, token: str | None, algo: str = "sha256",
                  attempts: int = 4) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            digest = hashlib.new(algo)
            with urllib.request.urlopen(req, timeout=600) as resp:
                while True:
                    chunk = resp.read(1024 * 1024)
                    if not chunk:
                        break
                    digest.update(chunk)
            return digest.hexdigest()
        except Exception as exc:  # noqa: BLE001 - retried below
            last = exc
            if attempt < attempts - 1:
                time.sleep(2 * (attempt + 1))
    raise UpdateError(f"download failed after {attempts} attempts: {url}: {last}")


def asset_digest(asset: dict, algo: str = "sha256") -> str | None:
    """Return the asset's hex digest if it carries one in `algo`.

    Both GitHub and electron-builder tag the digest with its algorithm, so a
    sha512-only source simply reports nothing here for a sha256 request and the
    caller falls back to hashing the download.
    """
    prefix, _, value = (asset.get("digest") or "").partition(":")
    if prefix != algo or not value:
        return None
    return value


# --------------------------------------------------------------------------- #
# Version handling
# --------------------------------------------------------------------------- #
def tag_to_pkgver(tag: str, strip_prefix: str | None) -> str:
    if strip_prefix and tag.startswith(strip_prefix):
        return tag[len(strip_prefix):]
    return tag


# AUR pkgver allows alphanumerics, '.', '_' and '+'; no whitespace, '/', ':' or '-'.
PKGVER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+]*$")


def compute_pkgver(meta: dict, tag: str) -> str:
    """Strip the configured prefix, then sanitize into a valid pkgver.

    AUR pkgver strings must not contain hyphens. The optional `tag.sanitize`
    pair `[pattern, replacement]` (regex, repl) also collapses prerelease
    suffixes like `-beta.3` / `-alpha.5` to `beta3` / `alpha5`, which vercmp
    sorts older than the final release (`1.0alpha < 1.0beta < ... < 1.0rc < 1.0`),
    so a prerelease-tracked package upgrades cleanly once stable ships.

    The result is validated: a tag whose shape drifts (upstream switching from
    `v1.2.3` to `1.2.3`, or to an npm-style `@scope/pkg@1.2.3`) would otherwise
    be pushed to AUR as a nonsense pkgver, since nobody reviews the automated
    commits. A stale non-version tag (`v1.2.4-stable`) is rejected too.
    """
    tag_cfg = meta.get("tag") or {}
    prefix = tag_cfg.get("strip_prefix")
    if prefix and not tag.startswith(prefix):
        # Every tag of a tracked repo conforms to its configured prefix today,
        # so a mismatch means upstream changed its tag format.
        raise UpdateError(
            f"tag {tag!r} does not start with the configured strip_prefix "
            f"{prefix!r}; upstream tag format changed?"
        )
    ver = tag_to_pkgver(tag, prefix)
    sanitize = tag_cfg.get("sanitize")
    if sanitize:
        if not (isinstance(sanitize, list) and len(sanitize) == 2):
            raise UpdateError("tag.sanitize must be [pattern, replacement]")
        ver = re.sub(sanitize[0], sanitize[1], ver)
    if not PKGVER_RE.match(ver):
        raise UpdateError(
            f"tag {tag!r} produced invalid pkgver {ver!r}; "
            "check [tag] strip_prefix/sanitize"
        )
    return ver


def tag_to_url_path(tag: str) -> str:
    """Percent-encode a tag for use as a path in a release download URL.

    Tags may contain characters that are legal but ambiguous in a URL path:
    MoonshotAI/kimi-code uses npm-style tags (`@moonshot-ai/kimi-code@2.1.1`),
    where a bare `@` reads as curl's userinfo separator and a bare `/` would
    split the tag across path segments. GitHub advertises exactly this encoded
    form in each asset's `browser_download_url`, so mirror it -- `/` stays a
    path separator, everything else that needs it is escaped.
    """
    return urllib.parse.quote(tag, safe="/")


def tag_to_ref_path(tag: str) -> str:
    """Fully percent-encode a tag for use as a raw.githubusercontent ref.

    Unlike a release download URL, the ref there is a single path segment, so
    `/` must be escaped too (`@moonshot-ai%2Fkimi-code%402.1.1`), otherwise the
    server would read only the part before the slash as the ref.
    """
    return urllib.parse.quote(tag, safe="")


def extra_sources_context(meta: dict, tag: str, pkgver: str,
                          token: str | None) -> dict[str, str]:
    """Download each configured `[extras.<key>]` file and hash it.

    Templates reference them as `{{url_extra_<key>}}` / `{{sha256_extra_<key>}}`.
    Hashing here (rather than pinning a literal in the template) means an
    upstream edit to the file is picked up automatically instead of breaking
    the build with a stale checksum.
    """
    extras = meta.get("extras") or {}
    out: dict[str, str] = {}
    for key, spec in extras.items():
        url = spec["url"]
        for placeholder, value in (
            ("{{tag}}", tag),
            ("{{tag_url}}", tag_to_url_path(tag)),
            ("{{tag_ref}}", tag_to_ref_path(tag)),
            ("{pkgver}", pkgver),
        ):
            url = url.replace(placeholder, value)
        out[f"url_extra_{key}"] = url
        try:
            out[f"sha256_extra_{key}"] = digest_of_url(url, token)
        except Exception as exc:  # noqa: BLE001 - surface a clear message
            raise UpdateError(f"extra source '{key}' ({url}) failed: {exc}")
    return out


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


def _normalize_pkgrel(text: str) -> str:
    """Blank out the pkgrel line so PKGBUILD comparisons ignore the bump."""
    return re.sub(r"(?m)^\s*pkgrel\s*=.*$", "pkgrel=<N>", text)


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


def srcinfo_python_fallback(pkgbuild_text: str, algo: str = "sha256") -> str:
    """Minimal .SRCINFO emitter for simple prebuilt-binary PKGBUILDs.

    Only used for local bootstrap/review; the CI pipeline always uses
    `srcinfo_via_makepkg` for canonical output. `algo` names the checksum
    arrays to look for (`sha256sums` / `sha512sums`).
    """
    fields = {
        "pkgbase": _bash_val(r"^\s*pkgname\s*=\s*([^#\s]+)", pkgbuild_text),
        "pkgdesc": _bash_val(r"^\s*pkgdesc\s*='([^']*)'", pkgbuild_text),
        "pkgver": _bash_val(r"^\s*pkgver\s*=\s*([^#\s]+)", pkgbuild_text),
        "pkgrel": _bash_val(r"^\s*pkgrel\s*=\s*([^#\s]+)", pkgbuild_text),
        "url": _bash_val(r"^\s*url\s*='([^']*)'", pkgbuild_text),
    }
    for key in ("arch", "license", "depends", "optdepends", "provides",
                "conflicts", "noextract", "options"):
        values = _bash_arr(key, pkgbuild_text)
        if values is not None:
            fields[key] = values

    sums_name = f"{algo}sums"
    src_fields = _bash_arr("source_x86_64", pkgbuild_text, fallback_name="source")
    sums_x86 = _bash_arr(f"{sums_name}_x86_64", pkgbuild_text,
                         fallback_name=sums_name)
    src_arm = _bash_arr("source_aarch64", pkgbuild_text)
    sums_arm = _bash_arr(f"{sums_name}_aarch64", pkgbuild_text)

    # makepkg --printsrcinfo expands ${pkgver} in source/checksum/noextract
    # lines; the pure-Python fallback must do the same so bootstrap output
    # matches CI.
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
        if fields.get("noextract"):
            fields["noextract"] = expand(fields["noextract"])
        sums_x86 = [v for v in (sums_x86 or [])]
        sums_arm = [v for v in (sums_arm or [])]

    lines: list[str] = []
    ordered = [
        "pkgbase", "pkgdesc", "pkgver", "pkgrel", "url",
        "arch", "license", "depends", "optdepends", "provides", "conflicts",
        "noextract", "options",
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
        (f"{sums_name}_x86_64", sums_x86),
        ("source_aarch64", src_arm),
        (f"{sums_name}_aarch64", sums_arm),
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
    # Split on whitespace *outside* quotes: an entry such as
    # 'libappindicator-gtk3: tray icon' is one element, not three.
    tokens = re.findall(r"'[^']*'|\"[^\"]*\"|\S+", m.group(1))
    return [
        t.strip().strip("'\"")
        for t in tokens
        if t.strip() and not t.strip().startswith("#")
    ]


def asset_candidates(arch_spec: dict, pkgver: str) -> list[str]:
    """Acceptable asset names for one arch, preference order preserved.

    `names` (a list) allows aliases for upstreams that renamed an asset without
    changing its role -- e.g. SniShaper's `snishaper-linux-amd64.tar.gz`
    became `snishaper-linux-x64.tar.gz` in v1.29.1. Plain `name` is the
    single-name form.
    """
    raw = arch_spec.get("names") or [arch_spec["name"]]
    return [n.replace("{pkgver}", pkgver) for n in raw]


def resolve_assets(meta: dict, release: dict, pkgver: str,
                   token: str | None) -> dict[str, str]:
    """Match each configured arch to a release asset and hash it.

    Returns template context entries: `asset_<arch>` (the asset's real
    filename, so templates stop hardcoding it), `url_asset_<arch>` (its
    download URL) and `<algo>_<arch>` (its checksum, with `<algo>` chosen by
    `[checksum] algorithm`). The checksum comes from the source's precomputed
    digest when present, so no multi-hundred-MB download is needed.
    """
    algo = checksum_algorithm(meta)
    by_name = {a["name"]: a for a in release.get("assets", [])}
    out: dict[str, str] = {}
    for arch, spec in (meta.get("assets") or {}).items():
        matched = next(
            (n for n in asset_candidates(spec, pkgver) if n in by_name), None
        )
        if matched is None:
            tried = ", ".join(asset_candidates(spec, pkgver))
            raise UpdateError(
                f"release {release['tag_name']} has no asset for {arch} "
                f"(tried: {tried})"
            )
        asset = by_name[matched]
        out[f"asset_{arch}"] = matched
        out[f"url_asset_{arch}"] = asset["browser_download_url"]
        out[f"{algo}_{arch}"] = (
            asset_digest(asset, algo)
            or digest_of_url(asset["browser_download_url"], token, algo)
        )
    return out


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

    context = {
        "pkgver": pkgver,
        "pkgrel": "1",
        "maintainer": meta.get("maintainer", "You <you@example.com>"),
        "tag": tag,
        "tag_url": tag_to_url_path(tag),
    }
    context.update(resolve_assets(meta, release, pkgver, token))
    context.update(extra_sources_context(meta, tag, pkgver, token))

    pkgbuild = render_pkgbuild(template, context)
    out_dir.mkdir(parents=True, exist_ok=True)
    pkgbuild_path = out_dir / "PKGBUILD"
    pkgbuild_path.write_text(pkgbuild, encoding="utf-8")

    if shutil.which("makepkg"):
        srcinfo = srcinfo_via_makepkg(pkgbuild_path)
    else:
        srcinfo = srcinfo_python_fallback(pkgbuild, checksum_algorithm(meta))
    (out_dir / ".SRCINFO").write_text(srcinfo, encoding="utf-8")

    print(f"rendered {pkgver}-1 -> {out_dir}")


def do_update(
    pkg_dir: Path,
    token: str | None,
    quiet: bool,
    git_env: dict[str, str] | None = None,
) -> int:
    """Update a single AUR package.

    Returns 0 if a commit was pushed, or 2 if there was nothing to do (the
    package is already current AND its PKGBUILD matches the template, or
    upstream is older) -- an idempotent, non-error skip. A genuine failure
    raises UpdateError, which main() reports as exit 1 -- kept distinct from
    2 so the CI workflow can tell "nothing to do" (green) apart from a real
    error (red).

    Besides version bumps, a same-version republish (pkgrel + 1) happens
    when the rendered PKGBUILD differs from the published one: template
    fixes, or upstream swapping an asset under the same tag.
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
    aur_pkgbuild_text: str | None = None
    version_changed = True
    oldrel = "0"
    if published is not None:
        oldver, oldrel = published
        aur_pkgbuild_text = current_pkgbuild.read_text(encoding="utf-8")
        cmp = vercmp(newver, oldver)
        if cmp < 0:
            print(
                f"{pkgbase}: upstream {newver} is older than published "
                f"{oldver}; skipping (manual intervention?)"
            )
            shutil.rmtree(workdir, ignore_errors=True)
            return 2
        version_changed = cmp > 0

    # --- resolve assets and render ---------------------------------------- #
    context = {
        "pkgver": newver,
        "maintainer": maintainer,
        "tag": tag,
        "tag_url": tag_to_url_path(tag),
    }
    context.update(resolve_assets(meta, release, newver, token))
    context.update(extra_sources_context(meta, tag, newver, token))

    if version_changed:
        newrel = "1"
    else:
        # Same version: republish only when the rendered PKGBUILD actually
        # differs from the published one (template fixes, or upstream
        # replacing an asset under the same tag). pkgrel is normalized away
        # so the bump itself never counts as a change.
        probe = render_pkgbuild(template, {**context, "pkgrel": oldrel})
        if _normalize_pkgrel(probe) == _normalize_pkgrel(aur_pkgbuild_text or ""):
            print(f"{pkgbase}: already at {oldver}-{oldrel}; nothing to do")
            shutil.rmtree(workdir, ignore_errors=True)
            return 2
        newrel = str(int(oldrel) + 1)
        print(
            f"{pkgbase}: {oldver} needs republish (PKGBUILD changed: "
            f"template fix or upstream asset swap) -> pkgrel {newrel}"
        )

    context["pkgrel"] = newrel
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