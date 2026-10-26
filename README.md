# UNITARES Homebrew tap

Native macOS packages for [UNITARES](https://github.com/cirwel/unitares): the
server, coordination lease plane, PostgreSQL 17 with Apache AGE and pgvector,
and Redis. This is the recommended installation for an Apple Silicon desktop
Mac; Docker remains the portable choice for servers, CI and non-macOS hosts.

This is a **preview for Apple Silicon Macs**. Installation builds from source;
no bottles are published. Database creation, bootstrap and upgrades remain
explicit operator steps. The CLI handles configuration and service lifecycle.
Intel macOS and Linux are not supported by this preview.

## Install

Install [Homebrew](https://brew.sh/) and Apple's Command Line Tools first.
Use a regular logged-in macOS account, without `sudo`:

```sh
brew update
brew tap cirwel/unitares
brew trust cirwel/unitares
brew install cirwel/unitares/unitares
brew pin unitares unitares-lease-plane apache-age unitares-pgvector
```

The server package is **3.5.0 revision 6** (`3.5.0_6`); its upstream runtime
version still reports `3.5.0`. Revision 6 adds the coordinated native updater
to the validated setup and optional-model backports.
[SOURCES.json](SOURCES.json) records the backports and installed file hashes.

Choose one primary installation per Mac. A Docker/Colima deployment already
using the standard ports must be migrated deliberately before native startup.
Installation does not copy its data or switch clients. The PostgreSQL-17-only
vector formula conflicts with Homebrew's `pgvector`; reconcile existing
extension ownership before installing, rather than overwrite-linking files.

## First-time setup

For an existing UNITARES database, follow the backed-up upgrade procedure below.
The following example is only for a **new, dedicated local database**.

Start the selected PostgreSQL service and create a dedicated role/database.
The password prompt does not put the password in shell history. AGE bootstrap
requires PostgreSQL superuser privileges; this example uses a dedicated local
superuser role, not a restricted production database account. Keep PostgreSQL
bound to loopback.

```sh
brew services start postgresql@17
env -i PATH="$PATH" HOME="$HOME" \
  "$(brew --prefix postgresql@17)/bin/createuser" --host=127.0.0.1 --port=5432 \
  --username="$(id -un)" --superuser --pwprompt unitares_local
env -i PATH="$PATH" HOME="$HOME" \
  "$(brew --prefix postgresql@17)/bin/createdb" --host=127.0.0.1 --port=5432 \
  --username="$(id -un)" --owner=unitares_local unitares_local
```

These commands intentionally fail if those names already exist. Investigate
existing data instead of dropping or recreating it. Then configure UNITARES:

```sh
unitares setup --apply
```

At its private prompt, enter
`postgresql://unitares_local:YOUR_URL_ENCODED_PASSWORD@127.0.0.1:5432/unitares_local`.
URL-encode special characters in the password. Setup creates
`$(brew --prefix)/etc/unitares/native.env` with mode 600 and a generated shared
lease bearer. Existing configuration is preserved. Setup does not create or
migrate a database; a successful setup command alone does not mean ready.

Only for the new empty database above, run the installed bootstrap. This block
loads the private configuration and keeps the password out of database command
arguments. Both UNITARES writers must remain stopped.

```sh
(
  set -a
  . "$(brew --prefix)/etc/unitares/native.env"
  set +a
  export PATH="$(brew --prefix unitares)/libexec/venv/bin:$(brew --prefix postgresql@17)/bin:$PATH"
  python - "$(brew --prefix unitares)/libexec/app/scripts/install/bootstrap_postgres.sh" <<'PY'
import os, subprocess, sys
from urllib.parse import urlsplit, urlunsplit, unquote
env = {key: value for key, value in os.environ.items() if not key.startswith("PG")}
url = urlsplit(env["DB_POSTGRES_URL"])
env["PGPASSWORD"] = unquote(url.password or "")
authority = url.netloc.split("@", 1)[-1]
if url.username:
    authority = url.username + "@" + authority
env["DB_POSTGRES_URL"] = urlunsplit((url.scheme, authority, url.path, url.query, url.fragment))
subprocess.run(["bash", sys.argv[1], "--apply"], env=env, check=True)
PY
)
```

Never run fresh bootstrap over an existing database or use absence of a
migration registry as proof that it is empty. Preserve and inspect an
interrupted installation before selecting recovery steps. Verify and start:

```sh
unitares setup
unitares start --check
unitares start
unitares health
```

Startup checks the schema, starts missing native dependencies, then starts both
writers and waits for deep health. It never applies migrations.

MCP endpoint: `http://127.0.0.1:8767/mcp/`.
Dashboard: `http://127.0.0.1:8767/dashboard/`.
See the upstream [MCP client guide](https://github.com/cirwel/unitares/blob/v3.5.0/docs/integration/MCP_CLIENTS.md)
to connect a client. These endpoints bind to loopback; Tailscale is not required
for local use. User services need the Homebrew owner's logged-in session.

## Daily use

```sh
unitares status
unitares logs server --no-follow
unitares logs lease-plane --no-follow
unitares stop
unitares start
```

Stop shuts down the two writers and retains PostgreSQL/Redis. Default native
ports are 5432, 6379, 8767 and 8788. Both writers use the same database and private
configuration. Custom service environments require their own operator procedure;
the preview deliberately refuses ambiguous ownership.

## Optional models and search

No model endpoint, model ID or resident roster is configured by default.
Ollama is optional; neither automatic model discovery nor an implicit fallback
is enabled. Configure a model endpoint deliberately before using consultation.

The package includes the core runtime and database-backed text search.
`torch` and `sentence-transformers` are omitted. Semantic embeddings require a
separately managed optional installation; do not modify this formula's private
Python environment, since upgrades replace it.

## Upgrades and recovery

Keep all four managed packages pinned between explicit UNITARES updates. A
bare `brew upgrade` is not a database upgrade procedure. Check the locally
cached plan without changing the host, or perform the coordinated update:

```sh
unitares update --check
unitares update
```

The apply command refreshes the tap, stops both writers, verifies quiescence,
makes and validates a private PostgreSQL backup, temporarily unpins and upgrades
the managed set and any dependencies Homebrew requires, records the complete
installed-formula inventory before and after, reapplies the managed pins, runs
migrations from the new keg and restores prior service state. If interrupted,
an unfinished journal blocks a separate `unitares start`; the new keg resumes
the journal, refreshing the backup before a retried package transaction:

```sh
unitares update --resume
```

An identity-count mismatch keeps writers stopped. Inspect the database and
backup first; if the changed count is expected, continue explicitly with
`unitares update --resume --accept-identity-change`.

If a package build cannot succeed, `unitares update --abort` restores the prior
state only while every managed package and the schema still match their recorded
pre-update versions. Once either changed, abort refuses and `--resume` remains
mandatory. Direct `brew services` commands bypass the journal guard.

Revision `3.5.0_5` predates this command. Its one-time transition to revision 6
still requires the documented stop, verified backup, explicit four-package
unpin/upgrade/repin procedure:

```sh
unitares stop
# Take and verify the PostgreSQL backup described in the linked procedure.
brew unpin unitares unitares-lease-plane apache-age unitares-pgvector
HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade --formula cirwel/unitares/unitares \
  cirwel/unitares/unitares-lease-plane cirwel/unitares/apache-age \
  cirwel/unitares/unitares-pgvector
brew pin unitares unitares-lease-plane apache-age unitares-pgvector
unitares update --check
# If both writers were running before the transition: unitares start
```

Revision 6 changes the package lifecycle but adds no schema migration. Later
upgrades use the coordinated path above. Reinstalling an older keg does not
reverse a database migration. Retain the old kegs and verified backup until the
new installation has passed its checks.

See the upstream [backup, migration and rollback procedure](https://github.com/cirwel/unitares/blob/v3.5.0/docs/manual/02-install.md#updating-a-bare-metal-or-launchagent-install).
Use scripts from `$(brew --prefix unitares)/libexec/app` and its sibling
`venv/bin/python`; do not run source-checkout Git or pip update commands in a
Homebrew keg. Reinstalling an older keg does not reverse a database migration.

## Validation

[Installed acceptance](.github/workflows/native-acceptance.yml) builds the
candidate tap on an isolated Apple Silicon macOS runner, checks installed source
hashes and Python dependencies, requires fresh bootstrap plus interrupted
recovery, and exercises a real coordinated managed-package update with backup,
pin, journal and data-preservation checks. See [VALIDATION.md](VALIDATION.md) for
prior VM/M1 evidence and its limits.
