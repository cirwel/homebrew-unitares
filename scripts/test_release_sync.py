#!/usr/bin/env python3
"""Offline contract tests for the Homebrew release renderer."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release_sync.py")
SPEC = importlib.util.spec_from_file_location("release_sync", SCRIPT)
assert SPEC and SPEC.loader
release_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_sync)


class ReleaseSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.source = Path(self.temporary.name)
        self.manifest = {
            "package": "3.5.0_6",
            "release": "v3.5.0",
            "files": {},
        }
        for relative, marker in release_sync.REQUIRED_NATIVE_FILES.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"{marker}\nrelease content\n")
            self.manifest["files"][relative] = {"source": "old", "sha256": "0" * 64}
        self.formula = (
            'class Unitares < Formula\n'
            '  url "https://github.com/cirwel/unitares/archive/refs/tags/v3.5.0.tar.gz"\n'
            f'  sha256 "{"0" * 64}"\n'
            '  revision 6\n\n'
            '  # Reviewed setup/model backports; remove when the release includes them.\n'
            '  patch :DATA\n'
            'end\n\n__END__\n--- a/file\n'
        )
        self.args = (
            self.source,
            "3.6.0",
            "v3.6.0",
            "1" * 40,
            "https://github.com/cirwel/unitares/releases/download/v3.6.0/unitares-3.6.0.tar.gz",
            "2" * 64,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_release_removes_revision_and_backport(self) -> None:
        formula, sources = release_sync.render(self.formula, self.manifest, *self.args)
        self.assertIn("releases/download/v3.6.0/unitares-3.6.0.tar.gz", formula)
        self.assertNotIn("revision", formula)
        self.assertNotIn("patch :DATA", formula)
        self.assertNotIn("__END__", formula)
        self.assertIn('"package": "3.6.0"', sources)
        self.assertIn('"source": "1111111111111111111111111111111111111111"', sources)

    def test_missing_updater_refuses_backport_removal(self) -> None:
        (self.source / "scripts/install/homebrew_update.py").unlink()
        with self.assertRaisesRegex(ValueError, "missing required native file"):
            release_sync.render(self.formula, self.manifest, *self.args)

    def test_mutable_source_archive_url_is_refused(self) -> None:
        args = list(self.args)
        args[-2] = "https://github.com/cirwel/unitares/archive/refs/tags/v3.6.0.tar.gz"
        with self.assertRaisesRegex(ValueError, "archive URL must be"):
            release_sync.render(self.formula, self.manifest, *args)

    def test_downgrade_is_refused(self) -> None:
        args = list(self.args)
        args[1] = "3.4.0"
        args[2] = "v3.4.0"
        args[4] = "https://github.com/cirwel/unitares/releases/download/v3.4.0/unitares-3.4.0.tar.gz"
        with self.assertRaisesRegex(ValueError, "would downgrade"):
            release_sync.render(self.formula, self.manifest, *args)


if __name__ == "__main__":
    unittest.main()
