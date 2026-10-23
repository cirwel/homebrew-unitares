# UNITARES Homebrew tap

Native macOS packages for [UNITARES](https://github.com/cirwel/unitares): the
server, coordination lease plane, PostgreSQL 17 with Apache AGE and pgvector,
and Redis. Docker is not required.

This is a **preview for Apple Silicon Macs**. Installation builds from source;
no bottles are published. Database creation, bootstrap and upgrades remain
explicit operator steps. The CLI handles configuration and service lifecycle.
Intel macOS and Linux are not supported by this preview.

## Install

Install [Homebrew](https://brew.sh/) and Apple's Command Line Tools first.
Use a regular logged-in macOS account, without `sudo`:

```sh
brew tap cirwel/unitares
brew trust cirwel/unitares
brew install cirwel/unitares/unitares
brew pin unitares unitares-lease-plane
```

The server package is **3.5.0 revision 5** (`3.5.0_5`); its upstream runtime
version still reports `3.5.0`. Revision 5 publishes the validated native setup
and optional-model backports with public tap names and documentation.
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
unitares logs lease-plane
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

Keep the server and lease-plane packages pinned until you have selected and
reviewed a target revision. `unitares update` is Compose-only and refuses this
native installation. A bare `brew upgrade` is not a database upgrade procedure.

Stop both writers with `unitares stop` and verify they exited. Take and verify
a PostgreSQL backup and preserve the private configuration. Retain the old kegs
while installing the chosen target. Apply any required migrations explicitly
with the installed package's Python and `scripts/dev/apply_migrations.py`,
including `--dialectic-writers-quiesced`, then restart and verify deep health
and existing identities before moving clients or deleting backups.

See the upstream [backup, migration and rollback procedure](https://github.com/cirwel/unitares/blob/v3.5.0/docs/manual/02-install.md#updating-a-bare-metal-or-launchagent-install).
Use scripts from `$(brew --prefix unitares)/libexec/app` and its sibling
`venv/bin/python`; do not run source-checkout Git or pip update commands in a
Homebrew keg. Reinstalling an older keg does not reverse a database migration.

## Validation

[Installed acceptance](.github/workflows/native-acceptance.yml) builds the
candidate tap on an isolated Apple Silicon macOS runner, checks installed source
hashes and Python dependencies, and requires fresh bootstrap plus interrupted
recovery against the installed package. See [VALIDATION.md](VALIDATION.md) for
prior VM/M1 evidence and its limits.
