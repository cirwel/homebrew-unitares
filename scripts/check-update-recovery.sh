#!/bin/sh
# Exercise recovery branches through the installed updater on disposable CI data.
set -eu

: "${HOMEBREW_UNITARES_TEST_UPDATE_DB_URL:?Set a dedicated updater database URL}"

phase=${1:-basic}
prefix=$(brew --prefix unitares)
brew_prefix=$(brew --prefix)
app="$prefix/libexec/app"
python="$prefix/libexec/venv/bin/python3"
evidence=${HOMEBREW_UNITARES_ACCEPTANCE_DIR:-$(pwd)/validation/native-update-recovery-$$}
mkdir -p "$evidence/recovery/$phase/backups"

write_backed_up_journal() {
    backup=$1
    target_mode=$2
    "$python" - "$app" "$backup" "$target_mode" <<'PY'
import hashlib
import sys

app, backup, target_mode = sys.argv[1:]
sys.path.insert(0, app)
from scripts.install.homebrew_services import Homebrew
from scripts.install.homebrew_update import JOURNAL_VERSION, NativeUpdater

brew = Homebrew()
brew.configure()
updater = NativeUpdater(brew)
inventory = updater.inventory()
if target_mode == "installed":
    for item in inventory.values():
        item["target"] = item["installed"]
state = {
    "journal_version": JOURNAL_VERSION,
    "stage": "backed_up",
    "writers_were_running": True,
    "config_sha256": hashlib.sha256(brew.config.read_bytes()).hexdigest(),
    "target": inventory,
    "schema_before": updater.schema_version(),
    "agent_count_before": updater.agent_count(),
    "backup": backup,
}
updater.write_journal(state)
PY
}

assert_recovery_state() {
    expected=$1
    "$python" - "$brew_prefix" "$expected" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

brew_prefix = Path(sys.argv[1])
expected = sys.argv[2]
journal = json.loads((brew_prefix / "var/unitares/native-update.json").read_text())
assert journal["stage"] == expected, journal
formulae = json.loads(
    subprocess.check_output(
        [
            "brew", "info", "--json=v2", "--formula",
            "cirwel/unitares/unitares",
            "cirwel/unitares/unitares-lease-plane",
            "cirwel/unitares/apache-age",
            "cirwel/unitares/unitares-pgvector",
        ],
        text=True,
    )
)["formulae"]
assert all(item["pinned"] for item in formulae), formulae
writers = json.loads(
    subprocess.check_output(
        ["brew", "services", "info", "unitares", "unitares-lease-plane", "--json"],
        text=True,
    )
)
assert all(item.get("running") for item in writers), writers
PY
}

journal="$brew_prefix/var/unitares/native-update.json"
backup=$("$python" - "$journal" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["backup"])
PY
)

case "$phase" in
    basic)
        # A hard interruption can land after package installation but before
        # re-pinning. A no-op resume must restore every managed pin.
        unitares stop
        brew unpin unitares unitares-lease-plane apache-age unitares-pgvector
        write_backed_up_journal "$backup" installed
        UNITARES_BACKUP_DIR="$evidence/recovery/basic/backups" \
            unitares update --resume --yes
        assert_recovery_state complete

        # Safe abort also restores pins and the prior running state.
        unitares stop
        brew unpin unitares unitares-lease-plane apache-age unitares-pgvector
        backup=$("$python" - "$journal" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["backup"])
PY
)
        write_backed_up_journal "$backup" installed
        unitares update --abort
        assert_recovery_state aborted

        # Homebrew unlink removes the PATH link but leaves the opt link. The
        # documented fallback must reach the updater, repair the link without
        # overwrite, and complete a safe abort.
        unitares stop
        write_backed_up_journal "$backup" installed
        brew unlink unitares
        test ! -x "$brew_prefix/bin/unitares"
        "$brew_prefix/opt/unitares/bin/unitares" update --abort
        test -x "$brew_prefix/bin/unitares"
        assert_recovery_state aborted
        ;;
    target-consent)
        # The workflow has moved the tap to another CI-only revision. Preserve
        # the approved target in the journal and require non-interactive resume
        # to refuse it without --yes.
        before=$(brew info --json=v2 --formula cirwel/unitares/unitares | \
            "$python" -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["linked_keg"])')
        unitares stop
        write_backed_up_journal "$backup" installed
        if UNITARES_BACKUP_DIR="$evidence/recovery/target-consent/backups" \
            unitares update --resume >"$evidence/recovery/target-consent/refusal.log" 2>&1; then
            echo "target-changing non-interactive resume unexpectedly succeeded" >&2
            exit 1
        fi
        grep -q 're-run with --yes' "$evidence/recovery/target-consent/refusal.log"
        after=$(brew info --json=v2 --formula cirwel/unitares/unitares | \
            "$python" -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["linked_keg"])')
        test "$after" = "$before"
        "$brew_prefix/opt/unitares/bin/unitares" update --abort
        assert_recovery_state aborted
        ;;
    *)
        echo "usage: $0 basic|target-consent" >&2
        exit 2
        ;;
esac

echo "Installed native update recovery acceptance passed: $phase"
