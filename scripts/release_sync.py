#!/usr/bin/env python3
"""Render a draft tap transition from a SHA-256-pinned UNITARES release asset."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[1]
FORMULA = ROOT / "Formula/unitares.rb"
LEASE_FORMULA = ROOT / "Formula/unitares-lease-plane.rb"
SOURCES = ROOT / "SOURCES.json"
REPOSITORY = "cirwel/unitares"
REQUIRED_NATIVE_FILES = {
    "scripts/install/homebrew_update.py": "class NativeUpdater",
    "scripts/install/homebrew_services.py": "class Homebrew",
    "scripts/install/launch.sh": "",
    "scripts/install/setup.py": "",
    "scripts/unitares": "update --homebrew",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def version_tuple(version: str) -> tuple[int, int, int]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("version must be a three-part numeric release")
    return tuple(int(part) for part in version.split("."))  # type: ignore[return-value]


def validate_release(
    source_root: Path,
    release_repo: Path,
    version: str,
    tag: str,
    commit: str,
    archive_url: str,
    archive_sha256: str,
    release_floor_commit: str,
) -> None:
    version_tuple(version)
    if tag != f"v{version}":
        raise ValueError("tag must be vVERSION")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a full lowercase Git commit")
    expected_url = (
        f"https://github.com/{REPOSITORY}/releases/download/"
        f"{tag}/unitares-{version}.tar.gz"
    )
    if archive_url != expected_url:
        raise ValueError(f"archive URL must be {expected_url}")
    if not re.fullmatch(r"[0-9a-f]{64}", archive_sha256):
        raise ValueError("archive SHA-256 must be lowercase hexadecimal")
    if not re.fullmatch(r"[0-9a-f]{40}", release_floor_commit):
        raise ValueError("resolved release-floor commit must be a full commit")
    if release_floor_commit != commit:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(release_repo),
                "merge-base",
                "--is-ancestor",
                release_floor_commit,
                commit,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode:
            raise ValueError(
                "release commit does not contain the complete reviewed backport floor"
            )
    for relative, marker in REQUIRED_NATIVE_FILES.items():
        path = source_root / relative
        if not path.is_file():
            raise ValueError(f"release is missing required native file: {relative}")
        if marker and marker not in path.read_text():
            raise ValueError(f"release file lacks required marker: {relative}")


def _render_formula_release(
    formula: str,
    version: str,
    archive_url: str,
    archive_sha256: str,
) -> str:
    url_match = re.search(r'^  url "(?P<url>[^"]+)"$', formula, re.M)
    if not url_match:
        raise ValueError("formula release URL was not recognized")
    current_match = re.search(
        r"(?:/v|/unitares-)([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$",
        url_match.group("url"),
    )
    if not current_match:
        raise ValueError("formula release version was not recognized")
    current = current_match.group(1)
    advancing = version_tuple(version) > version_tuple(current)
    if version_tuple(version) < version_tuple(current):
        raise ValueError(f"release {version} would downgrade formula {current}")
    if not advancing and re.search(r"^  revision [0-9]+$", formula, re.M):
        raise ValueError(
            f"release {version} equals a revised formula and would lower its package version"
        )
    rendered = re.sub(r'^  url ".*"$', f'  url "{archive_url}"', formula, count=1, flags=re.M)
    rendered = re.sub(
        r'^  sha256 "[0-9a-f]{64}"$',
        f'  sha256 "{archive_sha256}"',
        rendered,
        count=1,
        flags=re.M,
    )
    if advancing:
        rendered = re.sub(r"^  revision [0-9]+\n", "", rendered, count=1, flags=re.M)
        rendered = re.sub(r"\n  bottle do\n(?:    .*\n)+?  end\n", "\n", rendered, count=1)
        if "\n  bottle do\n" in rendered:
            raise ValueError("formula still contains a bottle block from the prior version")
        rendered = re.sub(
            r'(^  license .+\n)\n+(?=  depends_on)', r'\1\n', rendered, count=1, flags=re.M
        )
    return rendered


def render(
    formula: str,
    lease_formula: str,
    manifest: dict[str, object],
    source_root: Path,
    release_repo: Path,
    version: str,
    tag: str,
    commit: str,
    archive_url: str,
    archive_sha256: str,
    release_floor_commit: str,
) -> tuple[str, str, str]:
    release_floor_pr = manifest.get("release_floor_pr")
    if not isinstance(release_floor_pr, int) or release_floor_pr < 1:
        raise ValueError("SOURCES.json release_floor_pr is missing")
    validate_release(
        source_root,
        release_repo,
        version,
        tag,
        commit,
        archive_url,
        archive_sha256,
        release_floor_commit,
    )
    rendered = _render_formula_release(formula, version, archive_url, archive_sha256)
    rendered_lease = _render_formula_release(
        lease_formula, version, archive_url, archive_sha256
    )
    rendered = re.sub(
        r"\n  # Reviewed setup/model backports; remove when the release includes them\.\n"
        r"  patch :DATA\n",
        "",
        rendered,
        count=1,
    )
    if "\n__END__\n" in rendered:
        rendered = rendered.split("\n__END__\n", 1)[0].rstrip() + "\n"
    if "patch :DATA" in rendered or "\n__END__\n" in rendered:
        raise ValueError("formula still contains an embedded backport")

    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("SOURCES.json files map is missing")
    rendered_files: dict[str, dict[str, str]] = {}
    for relative in sorted(files):
        path = source_root / relative
        if not path.is_file():
            raise ValueError(f"release is missing tracked source: {relative}")
        rendered_files[relative] = {"source": commit, "sha256": sha256(path)}
    rendered_manifest = {
        "package": version,
        "release": tag,
        "release_floor_pr": release_floor_pr,
        "files": rendered_files,
    }
    return rendered, rendered_lease, json.dumps(rendered_manifest, indent=2) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--release-repo", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--archive-url", required=True)
    parser.add_argument("--archive-sha256", required=True)
    parser.add_argument("--release-floor-commit", required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        rendered_formula, rendered_lease_formula, rendered_sources = render(
            FORMULA.read_text(),
            LEASE_FORMULA.read_text(),
            json.loads(SOURCES.read_text()),
            args.source_root.resolve(),
            args.release_repo.resolve(),
            args.version,
            args.tag,
            args.commit,
            args.archive_url,
            args.archive_sha256,
            args.release_floor_commit,
        )
    except ValueError as exc:
        raise SystemExit(str(exc)) from exc
    if args.check:
        if (
            FORMULA.read_text() != rendered_formula
            or LEASE_FORMULA.read_text() != rendered_lease_formula
            or SOURCES.read_text() != rendered_sources
        ):
            raise SystemExit("formulae or source manifest are stale for this release")
        print("formula and source manifest match the release")
        return 0
    FORMULA.write_text(rendered_formula)
    LEASE_FORMULA.write_text(rendered_lease_formula)
    SOURCES.write_text(rendered_sources)
    print(
        f"rendered {FORMULA.relative_to(ROOT)}, {LEASE_FORMULA.relative_to(ROOT)} "
        f"and {SOURCES.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
