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

The current preview package tracks the upstream release recorded in
[SOURCES.json](SOURCES.json). The manifest records the exact source commit and
installed-file hashes, while both release-coupled formulae pin the same
SHA-256-verified release asset. The coordinated native updater is included in
the release itself.

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
See the upstream [MCP client guide](https://github.com/cirwel/unitares/blob/master/docs/integration/MCP_CLIENTS.md)
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
the journal, refreshing the tap target and backup before a retried package
transaction. If the target changed, resume asks again before adopting it:

```sh
unitares update --resume
```

If an interrupted Homebrew link step removes `unitares` from `PATH`, use
`$(brew --prefix)/opt/unitares/bin/unitares update --resume`. The updater repairs
missing managed links without overwriting conflicting prefix files.

An identity-count mismatch keeps writers stopped. Inspect the database and
backup first; if the changed count is expected, continue explicitly with
`unitares update --resume --accept-identity-change`.

If a package build cannot succeed, `unitares update --abort` restores the prior
state while every managed package and the schema still match their recorded
pre-update versions. Dependency changes made by the failed transaction are
retained and recorded. Once a managed package or the schema changed, abort
refuses and `--resume` remains mandatory. Direct `brew services` commands bypass
the journal guard.

Verified database backups are indexed separately from Homebrew kegs. Preview
the conservative retention plan, then apply that exact eligible set explicitly:

```sh
unitares update --cleanup-backups
unitares update --cleanup-backups --retain-backups 3 --older-than-days 30 --yes
```

Cleanup verifies each existing indexed dump again, counts only those verified
files toward the retention floor, protects any dump referenced by an update
journal, and records deletions in its own resumable journal. Missing-file index
records appear in the dry run and are reconciled only with `--yes`. It never
deletes an unindexed file. The dry run records the candidate set and policy
privately, so `--yes` resumes the exact reviewed plan while rechecking newly
protected backups. It never removes Homebrew kegs; `brew cleanup` remains a
separate package-manager decision after the new installation and database have
been independently verified.

Revision `3.5.0_5` predates this command. Upgrade it with the documented stop,
verified backup, and explicit four-package unpin/upgrade/repin procedure:

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

The 3.5.0 revision 6 transition changed the package lifecycle but added no
schema migration. Later upgrades use the coordinated path above. Reinstalling
an older keg does not reverse a database migration. Retain the old kegs and
verified backup until the new installation has passed its checks.

See the upstream [backup, migration and rollback procedure](https://github.com/cirwel/unitares/blob/master/docs/manual/02-install.md#updating-a-bare-metal-or-launchagent-install).
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

## Maintainer release and bottle workflow

Stable upstream releases own a deterministic `unitares-VERSION.tar.gz` asset.
The coordinated upstream
[UNITARES change](https://github.com/cirwel/unitares/pull/3086) adds a guarded
release workflow that builds and SHA-256-pins that tag-named asset, runs this
tap's offline renderer, and opens or updates `auto/homebrew-release-sync` as a
draft PR. The renderer advances both `unitares` and its release-coupled
lease-plane formula. It refuses mutable GitHub source archives, downgrades,
missing tracked sources, or removal of an embedded `DATA` backport before the
release commit contains the manifest's reviewed backport floor. It never marks
the PR ready or merges it. This repository's
manual [draft release sync](.github/workflows/release-sync.yml) is a protected
recovery path using the same renderer and evidence contract.

Apple Silicon bottles are a secondary optimization, not the primary install
contract. A protected manual [build](.github/workflows/bottle-build.yml) spends
a macOS runner only after approval and signs the bottles and evidence with
GitHub artifact attestations. Its token can write attestations but cannot
publish releases or change branches. A separate protected
[publish](.github/workflows/bottle-publish.yml) verifies the successful run,
commit, signing workflow, certificate run/attempt and every signed manifest
checksum before minting its publication token. It publishes non-overwriting
prerelease assets, including the inventory and evidence manifest, and opens a draft formula PR. Publication never authorizes merge; the
installed acceptance job must pass again against the exact bottle formula.
Any later updater backport strips the `unitares` bottle block and increments
the formula revision. When bottle blocks are present, acceptance first requires
every formula without that block to match the exact bottle-tag commit, so an
obsolete bottle cannot silently mask formula changes.
These jobs fail closed until the operator configures their named environments,
adds the matching environment-scoped arming secret
(`UNITARES_HOMEBREW_RELEASE_SYNC_ARMED` or
`UNITARES_HOMEBREW_BOTTLES_ARMED`) with value `true`, and sets
`UNITARES_HOMEBREW_RELEASE_SYNC_ENABLED` or
`UNITARES_HOMEBREW_BOTTLES_ENABLED` to `true` in the relevant repository.


## Verify a downloaded package

A checksum detects a changed download only if the expected checksum is trusted.
A signed attestation additionally identifies the repository, workflow and source
commit responsible for those bytes. Neither proves that the source or a dependency
is benign. Review, restricted runtime privileges and independent rebuilds address
other parts of that risk. These workflows do not establish reproducible builds.

For releases made with the new attesting workflows, use a current
[GitHub CLI](https://cli.github.com/manual/gh_attestation_verify) authenticated for
public-repository reads. Choose the expected full commit from a reviewed release
or tap PR independently of the downloaded metadata. Do not copy an expected commit
from an unverified manifest and treat that as verification.

For a source archive (replace the example version and commit):

```sh
version=3.7.0
commit=REVIEWED_40_CHARACTER_UPSTREAM_COMMIT
gh release download "v$version" --repo cirwel/unitares \
  --pattern "unitares-$version.tar.gz"
gh attestation verify "unitares-$version.tar.gz" --repo cirwel/unitares \
  --signer-workflow cirwel/unitares/.github/workflows/homebrew-release-sync.yml \
  --source-ref "refs/tags/v$version" --source-digest "$commit" \
  --signer-digest "$commit" --deny-self-hosted-runners
```

For a full bottle release, use `scripts/bottle_provenance.py` from a trusted tap
checkout, never a script downloaded alongside an unverified artifact:

```sh
tag=bottles-RELEASE_NAME
commit=REVIEWED_40_CHARACTER_TAP_BUILD_COMMIT
mkdir bottle-evidence
gh release download "$tag" --repo cirwel/homebrew-unitares --dir bottle-evidence
python3 scripts/bottle_provenance.py verify bottle-evidence \
  --tap-commit "$commit" --bottle-tag "$tag"
```

This verifies the manifest's signature against a fixed repository/workflow policy,
binds the declared run and attempt to the signing certificate, then checks all
four bottles and all accompanying evidence. Missing, extra, modified or linked
files fail closed. Publication performs the same checks, and installed acceptance
also verifies the actual cached bottles before installation. Ordinary `brew install`
still uses Homebrew's checksum checks; it does not automatically run this verifier.

Each bottle also has its own attestation. Before installing, fetch it into the
Homebrew cache and verify the bytes (repeat for each of the four tap formulae):

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --force-bottle cirwel/unitares/unitares
gh attestation verify "$(brew --cache --force-bottle cirwel/unitares/unitares)" \
  --repo cirwel/homebrew-unitares \
  --signer-workflow cirwel/homebrew-unitares/.github/workflows/bottle-build.yml \
  --source-ref refs/heads/main --source-digest "$commit" \
  --signer-digest "$commit" --deny-self-hosted-runners
```

The signed `brew-inventory.json` and `brew-config.txt` record installed versions
and the builder environment; `SOURCES.json` records the packaged source hashes.
Python requirements are hash-locked and the lease-plane source carries `mix.lock`,
but Homebrew core dependencies still follow `brew update`. The inventory is an
audit record, not a complete dependency lock or a standard SBOM. A compromised
trusted builder or malicious reviewed source can still produce valid attestations.

Old source assets and old build artifacts have no retrospective guarantee. The
recovery/publish workflows now refuse them if provenance is absent. Cut a new
upstream release containing the attesting workflow, and build bottles from a tap
commit containing it. Upstream manual dispatch must use `--ref "$TAG"`; checking
out an old tag from a run on `master` cannot supply that tag's signing identity.
No bottle publication or billed build is enabled by these changes.
