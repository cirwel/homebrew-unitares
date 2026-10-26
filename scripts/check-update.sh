#!/bin/sh
# Exercise the installed native updater against a dedicated disposable database.
# The workflow publishes a CI-only next managed-package revision after installing
# the candidate, so the installed command must discover and apply a real update.
set -eu

: "${HOMEBREW_UNITARES_TEST_UPDATE_DB_URL:?Set a dedicated updater database URL}"

prefix=$(brew --prefix unitares)
brew_prefix=$(brew --prefix)
postgres_prefix=$(brew --prefix postgresql@17)
app="$prefix/libexec/app"
python="$prefix/libexec/venv/bin/python3"
evidence=${HOMEBREW_UNITARES_ACCEPTANCE_DIR:-$(pwd)/validation/native-update-$(date +%Y%m%d-%H%M%S)-$$}
mkdir -p "$evidence/update"
export PATH="$prefix/libexec/venv/bin:$postgres_prefix/bin:$PATH"

DB_POSTGRES_URL=$HOMEBREW_UNITARES_TEST_UPDATE_DB_URL \
    unitares setup --apply --non-interactive

"$python" - "$app/scripts/install/bootstrap_postgres.sh" <<'PY'
import os
import subprocess
import sys
from urllib.parse import unquote, urlsplit, urlunsplit

url = urlsplit(os.environ["HOMEBREW_UNITARES_TEST_UPDATE_DB_URL"])
env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
env["PGPASSWORD"] = unquote(url.password or "")
authority = url.netloc.split("@", 1)[-1]
if url.username:
    authority = f"{url.username}@{authority}"
env["DB_POSTGRES_URL"] = urlunsplit(
    (url.scheme, authority, url.path, url.query, url.fragment)
)
subprocess.run(["bash", sys.argv[1], "--apply"], env=env, check=True)
subprocess.run(
    [
        "psql",
        "-X",
        "-v",
        "ON_ERROR_STOP=1",
        env["DB_POSTGRES_URL"],
        "-c",
        "CREATE TABLE public.homebrew_update_acceptance "
        "(marker text PRIMARY KEY); "
        "INSERT INTO public.homebrew_update_acceptance VALUES ('preserved');",
    ],
    env=env,
    check=True,
)
PY

brew pin unitares unitares-lease-plane apache-age unitares-pgvector
unitares start
unitares update --check
UNITARES_BACKUP_DIR="$evidence/update/backups" unitares update --yes

brew info --json=v2 --formula \
    cirwel/unitares/unitares \
    cirwel/unitares/unitares-lease-plane \
    cirwel/unitares/apache-age \
    cirwel/unitares/unitares-pgvector > "$evidence/update/formulae.json"
brew services info unitares unitares-lease-plane --json \
    > "$evidence/update/writers.json"
cp "$brew_prefix/var/unitares/native-update.json" "$evidence/update/journal.json"
cp "$brew_prefix/var/unitares/native-update-homebrew.log" \
    "$evidence/update/native-update-homebrew.log"

"$python" - "$evidence/update" <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit, urlunsplit

evidence = Path(sys.argv[1])
journal = json.loads((evidence / "journal.json").read_text())
assert journal["stage"] == "complete", journal
backup = Path(journal["backup"])
assert backup.is_file() and backup.stat().st_size > 0, backup
assert stat.S_IMODE(backup.stat().st_mode) == 0o600, oct(backup.stat().st_mode)

formulae = json.loads((evidence / "formulae.json").read_text())["formulae"]
by_name = {item["name"]: item for item in formulae}
expected = {"unitares", "unitares-lease-plane", "apache-age", "unitares-pgvector"}
assert set(by_name) == expected, by_name
assert all(by_name[name]["pinned"] for name in expected), by_name
server = by_name["unitares"]
assert server["linked_keg"].endswith("_7"), server

writers = json.loads((evidence / "writers.json").read_text())
assert {item["name"] for item in writers} == {"unitares", "unitares-lease-plane"}
assert all(item.get("running") for item in writers), writers

url = urlsplit(os.environ["HOMEBREW_UNITARES_TEST_UPDATE_DB_URL"])
env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
env["PGPASSWORD"] = unquote(url.password or "")
authority = url.netloc.split("@", 1)[-1]
if url.username:
    authority = f"{url.username}@{authority}"
public_url = urlunsplit((url.scheme, authority, url.path, url.query, url.fragment))
marker = subprocess.run(
    [
        "psql",
        "-X",
        "-Atq",
        "-v",
        "ON_ERROR_STOP=1",
        public_url,
        "-c",
        "SELECT marker FROM public.homebrew_update_acceptance",
    ],
    env=env,
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
assert marker == "preserved", marker
with (evidence / "backup-list.txt").open("w") as output:
    brew_prefix = Path(subprocess.check_output(["brew", "--prefix"], text=True).strip())
    subprocess.run(
        [str(brew_prefix / "opt/postgresql@17/bin/pg_restore"), "--list", str(backup)],
        check=True,
        stdout=output,
        text=True,
    )
print("Installed coordinated Homebrew update acceptance passed")
PY
