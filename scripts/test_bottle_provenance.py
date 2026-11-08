"""Offline policy tests; mocked gh is not a live signature-verification test."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import bottle_provenance as bp

COMMIT = "a" * 40
TAG = "bottles-test"
RUN = "123"
ATTEMPT = "2"


class BottleProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        mapping = []
        for formula in bp.FORMULAE:
            local = f"{formula}--1.0.arm64_tahoe.bottle.tar.gz"
            final = local.replace("--", "-")
            (self.root / local).write_bytes(formula.encode())
            (self.root / f"{formula}--1.0.arm64_tahoe.bottle.json").write_text("{}")
            mapping.append({"local_filename": local, "filename": final})
        bp.write_json(self.root / "asset-map.json", mapping)
        bp.write_json(self.root / "build-metadata.json", {
            "schema_version": 1, "tap_ref": COMMIT, "bottle_tag": TAG,
            "build_run_id": RUN, "build_run_attempt": ATTEMPT,
        })
        for name in bp.FIXED - {"asset-map.json", "build-metadata.json"}:
            (self.root / name).write_text("{}")
        bp.prepare(self.root, COMMIT, TAG, RUN, ATTEMPT)
        self.result = [{"verificationResult": {"signature": {"certificate": {
            "runInvocationURI": f"https://github.com/{bp.REPO}/actions/runs/{RUN}/attempts/{ATTEMPT}"
        }}}}]
        self.gh = self.enterContext(patch.object(bp.subprocess, "run"))
        self.gh.return_value = subprocess.CompletedProcess([], 0, json.dumps(self.result))

    def verify(self, **kwargs):
        bp.verify(self.root, kwargs.get("commit", COMMIT), kwargs.get("tag", TAG),
                  kwargs.get("run", RUN), kwargs.get("attempt", ATTEMPT))

    def edit_manifest(self, edit):
        path = self.root / bp.MANIFEST
        value = bp.read_json(path)
        edit(value)
        bp.write_json(path, value)

    def test_success_and_fixed_identity_policy(self):
        self.verify()
        args = self.gh.call_args.args[0]
        for flag, expected in (("--repo", bp.REPO), ("--signer-workflow", bp.WORKFLOW),
                               ("--source-ref", "refs/heads/main"),
                               ("--source-digest", COMMIT), ("--signer-digest", COMMIT)):
            self.assertEqual(args[args.index(flag) + 1], expected)
        self.assertIn("--deny-self-hosted-runners", args)
        self.assertTrue(self.gh.call_args.kwargs["check"])

    def test_failed_signature_never_parses_manifest(self):
        self.gh.side_effect = subprocess.CalledProcessError(1, "gh")
        (self.root / bp.MANIFEST).write_text("not JSON")
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_empty_verification_refused(self):
        self.gh.return_value.stdout = "[]"
        with self.assertRaisesRegex(ValueError, "no verified"):
            self.verify()

    def test_run_must_come_from_certificate_not_predicate(self):
        self.result[0]["verificationResult"] = {
            "statement": {"predicate": {"runDetails": {"metadata": {
                "invocationId": f"https://github.com/{bp.REPO}/actions/runs/{RUN}/attempts/{ATTEMPT}"
            }}}}}
        self.gh.return_value.stdout = json.dumps(self.result)
        with self.assertRaisesRegex(ValueError, "certificate"):
            self.verify()

    def test_expected_source_tag_run_and_attempt(self):
        for arg, value in (("commit", "b" * 40), ("tag", "bottles-other"), ("run", "124"), ("attempt", "3")):
            with self.subTest(arg=arg), self.assertRaises(ValueError):
                self.verify(**{arg: value})

    def test_tampered_payload(self):
        (self.root / "formula-bottles.patch").write_text("malicious patch")
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.verify()

    def test_unsigned_extra_file(self):
        (self.root / "unexpected.sh").write_text("exit 0")
        with self.assertRaisesRegex(ValueError, "coverage"):
            self.verify()

    def test_missing_payload(self):
        (self.root / "brew-inventory.json").unlink()
        with self.assertRaisesRegex(ValueError, "coverage"):
            self.verify()

    def test_symlink_refused_before_gh(self):
        target = self.root / "brew-inventory.json"
        target.unlink()
        target.symlink_to("SOURCES.json")
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.verify()
        self.gh.assert_not_called()

    def test_nested_directory_refused_before_gh(self):
        (self.root / "nested").mkdir()
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.verify()
        self.gh.assert_not_called()

    def test_path_traversal_refused(self):
        self.edit_manifest(lambda m: m["files"].update({"../outside": "a" * 64}))
        with self.assertRaisesRegex(ValueError, "coverage"):
            self.verify()

    def test_duplicate_json_key_refused(self):
        path = self.root / bp.MANIFEST
        path.write_text(path.read_text().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1'))
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            self.verify()

    def test_preparer_cannot_overwrite_manifest(self):
        with self.assertRaisesRegex(ValueError, "manifest already exists"):
            bp.prepare(self.root, COMMIT, TAG, RUN, ATTEMPT)

    def test_false_inventory_claim_does_not_skip_hashing(self):
        self.edit_manifest(lambda m: m["files"].update({"brew-inventory.json": "0" * 64}))
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
