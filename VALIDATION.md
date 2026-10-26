# Native package validation

The current preview package is server `3.5.0` revision 6. It uses the v3.5.0
archive plus the 15 reviewed installed-file backports recorded with source
provenance and SHA-256 digests in [SOURCES.json](SOURCES.json). Revision 6 adds
the coordinated native updater; the formula remains restricted to Apple Silicon
macOS and builds from source.

Before publication, installed revision 4 passed on an isolated Apple Silicon
macOS VM:

- All 14 then-current backported source hashes, private-venv `pip check`, and
  formula test.
- Read-only setup; private first-run configuration; repeated setup preserving
  configuration; empty default model endpoint, model ID and resident roster.
- Four-service startup and healthy deep health; repeated start preserving
  process IDs; stop preserving PostgreSQL and Redis.
- Explicit model selection and sole-model discovery only after explicit
  endpoint configuration.
- Fresh bootstrap and interruption after migration 062 followed by recovery
  through migration 78; checksum verification and no-op repeated migrations.

The same revision was upgraded and activated on an existing M1 Mac. Installed
hashes, dependency inventory, existing identity and configuration preservation
passed. All four native services ran with healthy deep health; liveness,
tool-listing and dashboard HTTP checks passed. The previous keg and a verified
custom-format database dump were retained. This revision introduced no SQL
migrations. The dump was checked with `pg_restore --list`, not round-trip
restored during that particular rollout.

Revision 6 public CI builds the candidate on an isolated Apple Silicon runner,
verifies all 15 installed-source hashes and Python dependencies, runs formula
tests, provisions dedicated PostgreSQL and Redis instances, and requires fresh
bootstrap plus interrupted-migration recovery. It then publishes an ephemeral
N+1 formula revision and exercises the installed coordinated update with both
writers running: verified backup, new-keg re-exec, journal completion, pin
restoration, preserved database data, deep health, evidence capture and cleanup.
The workflow also exercises updater recovery invariants in the same disposable
database: no-op resume restores every managed pin, safe abort restores the prior
writer state, an unlinked CLI is recovered through the stable `opt` path, and a
newly discovered N+2 target is refused non-interactively until the operator
reconfirms it. Private database dumps remain outside public artifacts.
For an `auto/homebrew-bottles` PR, the same job installs without
`--build-from-source` and requires all four managed formulae to report
`poured_from_bottle` before running the installed lifecycle acceptance.

Local and CI results establish the tested mechanisms, not compatibility beyond
their named host and scenarios. A GitHub run is evidence only when the exact
candidate revision completes successfully; workflow presence alone is not a
passing result.

No Intel/Linux compatibility, dashboard visual inspection,
unattended-before-login service support or prebuilt bottles are claimed.
Database creation and first bootstrap remain explicit. Native migrations run
only inside an explicitly invoked, backed-up `unitares update`; formula hooks
and service startup never migrate. Private host records and database backups are
excluded from this public repository.
