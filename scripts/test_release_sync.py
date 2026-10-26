#!/usr/bin/env python3
"""Offline contract tests for the Homebrew release renderer."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("release_sync.py")
SPEC = importlib.util.spec_from_file_location("release_sync", SCRIPT)
assert SPEC and SPEC.loader
release_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_sync)

BACKPORT_SCRIPT = Path(__file__).with_name("sync-updater-backport.py")
BACKPORT_SPEC = importlib.util.spec_from_file_location(
    "sync_updater_backport", BACKPORT_SCRIPT
)
assert BACKPORT_SPEC and BACKPORT_SPEC.loader
sync_updater_backport = importlib.util.module_from_spec(BACKPORT_SPEC)
BACKPORT_SPEC.loader.exec_module(sync_updater_backport)


class ReleaseSyncTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.source = Path(self.temporary.name)
        self.manifest = {
            "package": "3.5.0_6",
            "release": "v3.5.0",
            "release_floor_pr": 3086,
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
        self.lease_formula = (
            'class UnitaresLeasePlane < Formula\n'
            '  url "https://github.com/cirwel/unitares/archive/refs/tags/v3.5.0.tar.gz"\n'
            f'  sha256 "{"0" * 64}"\n'
            '  license "Apache-2.0"\n'
            '  revision 2\n\n'
            '  bottle do\n    root_url "https://example.invalid/old"\n'
            '    sha256 cellar: :any, arm64_sequoia: "abc"\n  end\n\n'
            '  depends_on "elixir" => :build\n'
            'end\n'
        )
        self.args = (
            self.source,
            self.source,
            "3.6.0",
            "v3.6.0",
            "1" * 40,
            "https://github.com/cirwel/unitares/releases/download/v3.6.0/unitares-3.6.0.tar.gz",
            "2" * 64,
            "1" * 40,
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_release_removes_revision_and_backport(self) -> None:
        formula, lease, sources = release_sync.render(
            self.formula, self.lease_formula, self.manifest, *self.args
        )
        self.assertIn("releases/download/v3.6.0/unitares-3.6.0.tar.gz", formula)
        self.assertNotIn("revision", formula)
        self.assertNotIn("patch :DATA", formula)
        self.assertNotIn("__END__", formula)
        self.assertIn("releases/download/v3.6.0/unitares-3.6.0.tar.gz", lease)
        self.assertIn(f'  sha256 "{"2" * 64}"', lease)
        self.assertNotIn("revision", lease)
        self.assertNotIn("bottle do", lease)
        self.assertIn('"package": "3.6.0"', sources)
        self.assertIn('"source": "1111111111111111111111111111111111111111"', sources)

    def test_version_advance_removes_old_bottle_block(self) -> None:
        formula = (
            'class Unitares < Formula\n'
            '  url "https://github.com/cirwel/unitares/archive/refs/tags/v3.5.0.tar.gz"\n'
            f'  sha256 "{"0" * 64}"\n'
            '  license "Apache-2.0"\n'
            '  revision 6\n\n'
            '  bottle do\n    root_url "https://example.invalid/old"\n'
            '    sha256 cellar: :any, arm64_sequoia: "abc"\n  end\n\n'
            '  depends_on :macos\n\n'
            '  # Reviewed setup/model backports; remove when the release includes them.\n'
            '  patch :DATA\n'
            'end\n\n__END__\n--- a/file\n'
        )
        rendered, _, _ = release_sync.render(
            formula, self.lease_formula, self.manifest, *self.args
        )
        self.assertNotIn("bottle do", rendered)
        self.assertNotIn('license "Apache-2.0"\n\n\n', rendered)

    def test_equal_release_refuses_to_drop_revision(self) -> None:
        args = list(self.args)
        args[2] = "3.5.0"
        args[3] = "v3.5.0"
        args[5] = "https://github.com/cirwel/unitares/releases/download/v3.5.0/unitares-3.5.0.tar.gz"
        with self.assertRaisesRegex(ValueError, "would lower its package version"):
            release_sync.render(self.formula, self.lease_formula, self.manifest, *args)

    def test_release_must_contain_reviewed_backport_floor(self) -> None:
        args = list(self.args)
        args[-1] = "0" * 40
        with mock.patch.object(
            release_sync.subprocess,
            "run",
            return_value=mock.Mock(returncode=1),
        ):
            with self.assertRaisesRegex(ValueError, "reviewed backport floor"):
                release_sync.render(
                    self.formula, self.lease_formula, self.manifest, *args
                )

    def test_missing_updater_refuses_backport_removal(self) -> None:
        (self.source / "scripts/install/homebrew_update.py").unlink()
        with self.assertRaisesRegex(ValueError, "missing required native file"):
            release_sync.render(
                self.formula, self.lease_formula, self.manifest, *self.args
            )

    def test_mutable_source_archive_url_is_refused(self) -> None:
        args = list(self.args)
        args[5] = "https://github.com/cirwel/unitares/archive/refs/tags/v3.6.0.tar.gz"
        with self.assertRaisesRegex(ValueError, "archive URL must be"):
            release_sync.render(self.formula, self.lease_formula, self.manifest, *args)

    def test_downgrade_is_refused(self) -> None:
        args = list(self.args)
        args[2] = "3.4.0"
        args[3] = "v3.4.0"
        args[5] = "https://github.com/cirwel/unitares/releases/download/v3.4.0/unitares-3.4.0.tar.gz"
        with self.assertRaisesRegex(ValueError, "would downgrade"):
            release_sync.render(self.formula, self.lease_formula, self.manifest, *args)

    def test_backport_refresh_strips_bottle_bumps_revision_and_checks_blob(self) -> None:
        repository = self.source / "upstream"
        source = repository / "scripts/install/homebrew_update.py"
        source.parent.mkdir(parents=True)
        source.write_text("print('reviewed updater')\n")
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "config", "user.email", "test@example.com"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(repository), "config", "user.name", "Test"],
            check=True,
        )
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(
            ["git", "-C", str(repository), "commit", "-qm", "source"], check=True
        )
        commit = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        formula_path = self.source / "unitares.rb"
        formula_path.write_text(
            'class Unitares < Formula\n'
            '  license "Apache-2.0"\n'
            '  revision 6\n\n'
            '  bottle do\n    root_url "https://example.invalid/old"\n'
            '    sha256 cellar: :any, arm64_sequoia: "abc"\n  end\n\n'
            '  patch :DATA\nend\n\n__END__\n'
            + sync_updater_backport.PATCH_MARKER
            + "@@ -0,0 +1 @@\n+old\n"
        )
        sources_path = self.source / "sources.json"
        sources_path.write_text(
            json.dumps(
                {
                    "release_floor_pr": 1,
                    "files": {
                        "scripts/install/homebrew_update.py": {
                            "source": "old",
                            "sha256": "0" * 64,
                        }
                    },
                }
            )
        )
        with (
            mock.patch.object(sync_updater_backport, "FORMULA", formula_path),
            mock.patch.object(sync_updater_backport, "SOURCES", sources_path),
        ):
            rendered, rendered_sources = sync_updater_backport.render(source, commit, 3086)
            self.assertNotIn("bottle do", rendered)
            self.assertIn("  revision 7", rendered)
            self.assertNotIn("\n\n\n", rendered)
            self.assertIn(commit, rendered_sources)
            source.write_text("print('uncommitted')\n")
            with self.assertRaisesRegex(SystemExit, "does not match"):
                sync_updater_backport.render(source, commit, 3086)


if __name__ == "__main__":
    unittest.main()
