#!/usr/bin/env python3
"""Regenerate the embedded native updater backport and its source record."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
FORMULA = ROOT / "Formula/unitares.rb"
SOURCES = ROOT / "SOURCES.json"
PATCH_MARKER = "--- /dev/null\n+++ b/scripts/install/homebrew_update.py\n"


def render(source: Path, commit: str, release_floor_pr: int) -> tuple[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit("--source-commit must be a full lowercase Git commit")
    payload = source.read_bytes()
    if not payload.endswith(b"\n"):
        raise SystemExit(f"{source} must end with a newline")
    lines = payload.decode().splitlines(keepends=True)
    formula = FORMULA.read_text()
    try:
        prefix = formula[: formula.index(PATCH_MARKER)]
    except ValueError as exc:
        raise SystemExit("Formula/unitares.rb has no embedded updater patch") from exc
    patch = (
        PATCH_MARKER
        + f"@@ -0,0 +1,{len(lines)} @@\n"
        + "".join(f"+{line}" for line in lines)
    )
    rendered_formula = prefix + patch

    manifest = json.loads(SOURCES.read_text())
    if release_floor_pr < 1:
        raise SystemExit("--release-floor-pr must be a positive pull request number")
    manifest["release_floor_pr"] = release_floor_pr
    record = manifest["files"]["scripts/install/homebrew_update.py"]
    record["source"] = f"cirwel/unitares#3086 @ {commit}"
    record["sha256"] = hashlib.sha256(payload).hexdigest()
    rendered_sources = json.dumps(manifest, indent=2) + "\n"
    return rendered_formula, rendered_sources


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--release-floor-pr", type=int, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    rendered_formula, rendered_sources = render(
        args.source, args.source_commit, args.release_floor_pr
    )
    if args.check:
        if FORMULA.read_text() != rendered_formula or SOURCES.read_text() != rendered_sources:
            raise SystemExit("embedded updater patch or source record is stale")
        print("embedded updater patch and source record are current")
        return 0
    FORMULA.write_text(rendered_formula)
    SOURCES.write_text(rendered_sources)
    print(f"updated {FORMULA.relative_to(ROOT)} and {SOURCES.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
