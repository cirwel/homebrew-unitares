#!/bin/sh
# Run the real installed package through fresh install and interrupted recovery.
# Provision dedicated empty databases/Redis namespaces on a clean acceptance host.
set -eu

: "${HOMEBREW_UNITARES_TEST_FRESH_DB_URL:?Set a dedicated empty fresh-install database URL}"
: "${HOMEBREW_UNITARES_TEST_RECOVERY_DB_URL:?Set a different empty recovery database URL}"
: "${HOMEBREW_UNITARES_TEST_FRESH_REDIS_URL:?Set a dedicated acceptance Redis URL}"
: "${HOMEBREW_UNITARES_TEST_RECOVERY_REDIS_URL:?Set a different acceptance Redis URL}"

[ "$HOMEBREW_UNITARES_TEST_FRESH_DB_URL" != "$HOMEBREW_UNITARES_TEST_RECOVERY_DB_URL" ] || {
    echo "Fresh and recovery scenarios require separate empty databases" >&2
    exit 2
}
[ "$HOMEBREW_UNITARES_TEST_FRESH_REDIS_URL" != "$HOMEBREW_UNITARES_TEST_RECOVERY_REDIS_URL" ] || {
    echo "Fresh and recovery scenarios require separate Redis namespaces" >&2
    exit 2
}

tap_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
prefix=$(brew --prefix unitares)
postgres_prefix=$(brew --prefix postgresql@17)
app="$prefix/libexec/app"
python="$prefix/libexec/venv/bin/python3"
harness=${UNITARES_ACCEPTANCE_HARNESS:-$app/scripts/ci/bootstrap_acceptance.py}
evidence=${HOMEBREW_UNITARES_ACCEPTANCE_DIR:-$tap_root/validation/native-$(date +%Y%m%d-%H%M%S)-$$}
[ -f "$harness" ] || {
    echo "Acceptance harness absent from this release; set UNITARES_ACCEPTANCE_HARNESS to the reviewed server harness" >&2
    exit 2
}
export PATH="$prefix/libexec/venv/bin:$postgres_prefix/bin:$PATH"

for scenario in fresh interrupted; do
    case "$scenario" in
        fresh)
            db_url=$HOMEBREW_UNITARES_TEST_FRESH_DB_URL
            database=${HOMEBREW_UNITARES_TEST_FRESH_DB_NAME:-unitares_acceptance_brew_fresh}
            redis_url=$HOMEBREW_UNITARES_TEST_FRESH_REDIS_URL
            ;;
        interrupted)
            db_url=$HOMEBREW_UNITARES_TEST_RECOVERY_DB_URL
            database=${HOMEBREW_UNITARES_TEST_RECOVERY_DB_NAME:-unitares_acceptance_brew_interrupted}
            redis_url=$HOMEBREW_UNITARES_TEST_RECOVERY_REDIS_URL
            ;;
    esac
    "$python" "$harness" --app-root "$app" --work-dir "$evidence/$scenario" \
        --db-url "$db_url" --expected-database "$database" --redis-url "$redis_url" \
        --scenario "$scenario" --server-launcher "$prefix/bin/unitares-server"
done
printf 'Installed Homebrew acceptance passed; evidence: %s\n' "$evidence"
