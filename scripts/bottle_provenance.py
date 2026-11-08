#!/usr/bin/env python3
"""Create/verify bottle evidence. Verification policy comes from this trusted script.

Use a trusted checkout of this script, not a script supplied by a release asset.
GitHub CLI performs signature, identity, source and transparency-log verification.
The signed manifest then binds the entire release payload, including its inventory.
"""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

REPO = "cirwel/homebrew-unitares"
WORKFLOW = f"{REPO}/.github/workflows/bottle-build.yml"
MANIFEST = "provenance.json"
FORMULAE = ("apache-age", "unitares-pgvector", "unitares-lease-plane", "unitares")
FIXED = {"asset-map.json", "formula-bottles.patch", "build-metadata.json",
         "SOURCES.json", "brew-config.txt", "brew-inventory.json"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_name(name):
    require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name),
            f"unsafe filename: {name!r}")
    return name


def files_in(directory):
    require(directory.is_dir() and not directory.is_symlink(), "bundle must be a directory")
    paths = list(directory.iterdir())
    for path in paths:
        safe_name(path.name)
        require(path.is_file() and not path.is_symlink(), f"not a regular file: {path.name}")
    return {p.name for p in paths}


def validate_inputs(commit, tag, run_id=None, attempt=None):
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "expected full lowercase tap commit")
    require(re.fullmatch(r"bottles-[A-Za-z0-9._-]+", tag), "invalid bottle tag")
    for value in (run_id, attempt):
        if value is not None:
            require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*", value),
                    "run ID/attempt must be positive decimal strings")


def validate_payload(directory, names):
    require(FIXED <= names, "missing required evidence")
    bottles = {n for n in names if n.endswith(".bottle.tar.gz")}
    bottle_json = {n for n in names if n.endswith(".bottle.json")}
    require(len(bottles) == len(bottle_json) == 4, "expected four bottles and four bottle JSON files")
    require(names == FIXED | bottles | bottle_json, "unexpected payload files")
    for formula in FORMULAE:
        # Final Homebrew release filenames use one dash before the version.
        require(sum(bool(re.fullmatch(re.escape(formula) + r"-[0-9].*\.bottle\.tar\.gz", n))
                    for n in bottles) == 1, f"missing or duplicate bottle: {formula}")
    mapping = read_json(directory / "asset-map.json")
    require(isinstance(mapping, list) and len(mapping) == 4, "invalid asset map")
    published = []
    local = []
    for entry in mapping:
        require(isinstance(entry, dict) and set(entry) == {"filename", "local_filename"}, "invalid mapping entry")
        published.append(safe_name(entry["filename"]))
        local.append(safe_name(entry["local_filename"]))
    require(set(published) == bottles and len(set(local)) == 4, "asset map does not cover bottles")


def prepare(directory, commit, tag, run_id, attempt):
    validate_inputs(commit, tag, run_id, attempt)
    files_in(directory)  # Reject links before reading or renaming anything.
    require(not (directory / MANIFEST).exists(), "manifest already exists")
    mapping = read_json(directory / "asset-map.json")
    require(isinstance(mapping, list) and len(mapping) == 4, "invalid asset map")
    pairs = [(safe_name(e["local_filename"]), safe_name(e["filename"])) for e in mapping]
    require(len({a for a, _ in pairs}) == len({b for _, b in pairs}) == 4, "duplicate bottle filenames")
    for source, target in pairs:
        require(source.endswith(".bottle.tar.gz") and target.endswith(".bottle.tar.gz"), "invalid bottle name")
        if source != target:
            require(not (directory / target).exists(), "renaming would overwrite a file")
            (directory / source).rename(directory / target)
    names = files_in(directory)
    validate_payload(directory, names)
    metadata = read_json(directory / "build-metadata.json")
    require(metadata == {"schema_version": 1, "tap_ref": commit, "bottle_tag": tag,
                         "build_run_id": run_id, "build_run_attempt": attempt}, "build metadata mismatch")
    write_json(directory / MANIFEST, {**metadata, "files": {n: digest(directory / n) for n in sorted(names)}})


def verify(directory, commit, tag, run_id=None, attempt=None):
    validate_inputs(commit, tag, run_id, attempt)
    names = files_in(directory)
    require(MANIFEST in names, "missing signed manifest")
    # Do not read identity policy, execute code, or extract archives from this bundle.
    result = subprocess.run([
        "gh", "attestation", "verify", str((directory / MANIFEST).resolve()),
        "--repo", REPO, "--signer-workflow", WORKFLOW,
        "--source-ref", "refs/heads/main", "--source-digest", commit,
        "--signer-digest", commit, "--deny-self-hosted-runners", "--format", "json",
    ], check=True, text=True, stdout=subprocess.PIPE)
    verified = json.loads(result.stdout)
    require(isinstance(verified, list) and verified, "no verified attestations")
    manifest = read_json(directory / MANIFEST)
    require(set(manifest) == {"schema_version", "tap_ref", "bottle_tag", "build_run_id",
                              "build_run_attempt", "files"}, "unexpected manifest schema")
    validate_inputs(manifest["tap_ref"], manifest["bottle_tag"],
                    manifest["build_run_id"], manifest["build_run_attempt"])
    require(manifest["schema_version"] == 1 and manifest["tap_ref"] == commit
            and manifest["bottle_tag"] == tag, "manifest source/tag mismatch")
    require(run_id is None or manifest["build_run_id"] == run_id, "manifest run mismatch")
    require(attempt is None or manifest["build_run_attempt"] == attempt, "manifest attempt mismatch")
    invocation = (f"https://github.com/{REPO}/actions/runs/{manifest['build_run_id']}"
                  f"/attempts/{manifest['build_run_attempt']}")
    # This is a certificate extension issued from GitHub OIDC, not the mutable
    # SLSA predicate's runDetails.metadata.invocationId.
    require(any(item.get("verificationResult", {}).get("signature", {}).get("certificate", {})
                .get("runInvocationURI") == invocation for item in verified),
            "verified certificate does not identify the declared build run/attempt")
    hashes = manifest["files"]
    require(isinstance(hashes, dict) and set(hashes) == names - {MANIFEST}, "manifest file coverage mismatch")
    for name, expected in hashes.items():
        safe_name(name)
        require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected), "invalid SHA-256")
        require(digest(directory / name) == expected, f"digest mismatch: {name}")
    validate_payload(directory, set(hashes))
    require(read_json(directory / "build-metadata.json") == {k: v for k, v in manifest.items() if k != "files"},
            "build metadata mismatch")
    print(f"Verified {len(hashes)} payload files from {commit}, run {manifest['build_run_id']}/{manifest['build_run_attempt']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tap-commit", required=True)
    parser.add_argument("--bottle-tag", required=True)
    parser.add_argument("--build-run-id")
    parser.add_argument("--build-run-attempt")
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            require(args.build_run_id is not None and args.build_run_attempt is not None, "prepare requires run and attempt")
        globals()[args.action](args.directory, args.tap_commit, args.bottle_tag,
                               args.build_run_id, args.build_run_attempt)
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Provenance refused: {error}\n")


if __name__ == "__main__":
    main()
