# UNITARES Homebrew tap

Native macOS packages for [UNITARES](https://github.com/cirwel/unitares): the
server, coordination lease plane, PostgreSQL 17 with Apache AGE and pgvector,
and Redis. This is the recommended installation for an Apple Silicon desktop
Mac; Docker remains the portable choice for servers, CI and non-macOS hosts.

This is a **preview for Apple Silicon Macs**. Installation builds from source;
no bottles are published. Database creation, bootstrap and upgrades run only
when you invoke their CLI commands. The CLI also handles configuration and
service lifecycle.
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
The same applies to `age` or `vector` files that a source install copied by
hand into `$(brew --prefix)/lib/postgresql@17` or
`$(brew --prefix)/share/postgresql@17/extension`.

PostgreSQL 5432, Redis 6379 and the server 8767 are fixed on this route, and
first-time setup also needs the lease plane's 8788. Setup and start refuse if
another program listens on one of them, and there is no alternative-port
option for the first three. Check first
with `lsof -nP -iTCP:5432 -sTCP:LISTEN` (repeat for 6379, 8767 and 8788).
Redis database 0 on 127.0.0.1:6379 is used too. First-time provisioning refuses
it if it already holds keys, for example another installation's sessions, and
never clears it.

## First-time setup

This route needs UNITARES 4.1.0 or later; `brew info cirwel/unitares/unitares`
shows the installed version. For older kegs, see
[Kegs before 4.1.0](#kegs-before-410) below. For an existing UNITARES database,
follow the backed-up upgrade procedure below instead. The following is only for
a **new machine with no UNITARES database**.

Provisioning connects to 127.0.0.1:5432 as your macOS user without a password,
and that user must be a PostgreSQL superuser. Homebrew's default
`postgresql@17` cluster is set up this way. A cluster that asks for a local
password, or whose data directory is not `$(brew --prefix)/var/postgresql@17`,
is refused. Show the plan, then provision:

```sh
unitares setup --provision-db
unitares setup --provision-db --apply
```

The first command changes nothing. The second starts Homebrew PostgreSQL 17 and
Redis if needed, creates a dedicated `unitares` login and `unitares` database
(the login is not a superuser), bootstraps that database, checks its migrations
and an AGE query, and only then writes `$(brew --prefix)/etc/unitares/native.env`
(mode 600) with a generated password, installation ID and lease bearer. Both
UNITARES writers stay stopped. The `governance` name in the package's
`native.env.example` template is a placeholder that this route does not use.

Provisioning refuses an existing `native.env`, a `DB_POSTGRES_URL` set in your
shell, an existing `unitares` role or database, running writers, a nonempty
Redis database 0, and a running Docker `postgres-age`. If the `docker` command is
installed, Docker must be running so its containers can be listed. It never
adopts, drops or resets existing data. Investigate a refusal instead of deleting
what it found. While PostgreSQL is stopped, the plan cannot inspect it, so a
refusal for an existing role or database can first appear at `--apply`. It then
comes before any role, database or configuration is created, though PostgreSQL
and Redis may already have been started.

`$(brew --prefix)/var/unitares/native-setup.json` holds the credentials and the
setup stage; keep it private. While it is unfinished, `unitares start`, `setup`
and `update` refuse. Resume an interrupted setup with:

```sh
unitares setup --provision-db --apply --resume
```

Never run fresh bootstrap over an existing database or use absence of a
migration registry as proof that it is empty. A bootstrap interrupted after its
SQL began is not replayed: preserve the database and journal and inspect them
before selecting recovery steps. To use an existing, already bootstrapped
UNITARES database instead, run `unitares setup --apply` and enter its URL at the
hidden prompt; that command never creates or migrates a database.

Then start. `unitares start --check` only checks the configuration, services
and ports and prints the startup plan; it does not inspect the database:

```sh
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

### Kegs before 4.1.0

Releases before 4.1.0 (including 3.6.0) have no `--provision-db`. Their
first-time setup is the manual route in
[this README at 84dd3e1](https://github.com/cirwel/homebrew-unitares/blob/84dd3e193367d450d61dff9ba0b93c11490b2c2c/README.md#first-time-setup).
In short: `brew services start postgresql@17`; create a dedicated superuser role
and its database with `createuser --superuser --pwprompt` and `createdb --owner`
(both fail if the names exist; investigate rather than drop); run
`unitares setup --apply` and enter that database's URL at the hidden prompt;
then, with both writers stopped and only for that new empty database, run the
installed `libexec/app/scripts/install/bootstrap_postgres.sh --apply` with the
password in `PGPASSWORD` rather than in the URL. Start with the commands above.
At 4.1.0 and later that bootstrap refuses a database that provisioning did not
prepare.

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
