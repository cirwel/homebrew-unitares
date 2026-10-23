# Native package validation

The initial public package uses the v3.5.0 archive and reviewed backports in
[SOURCES.json](SOURCES.json). Public revision 5 changes the tap namespace,
restricts the server formula to macOS ARM, and adapts two packaged installation
documents. Runtime, SDK, migrations and dependency-lock bytes match the locally
validated revision 4 package.

Before publication, installed revision 4 passed on an isolated Apple Silicon
macOS VM:

- All 14 backported source hashes, private-venv `pip check`, and formula test.
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

These local results establish runtime behavior, not the outcome of public
revision 5's GitHub checks. Public CI builds the candidate formula and records
installed-artifact evidence on each PR and main update. A GitHub run is complete
only when its checks pass; the workflow's presence alone is not a passing result.

No Intel/Linux compatibility, dashboard visual inspection, automatic database
creation, unattended-before-login service support, automatic native migration,
or prebuilt bottles are claimed. Private host records and database backups
are excluded from this public repository.
