#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$tmp/bin" "$tmp/log" "$tmp/state" "$tmp/spool"
calls="$tmp/pgbackrest.calls"

cat >"$tmp/bin/pgbackrest" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PGBACKREST_TEST_CALLS"
if [[ "$*" == *" info "* || "$*" == *" info" ]]; then printf '[]\n'; fi
SH

cat >"$tmp/bin/supercronic" <<'SH'
#!/usr/bin/env bash
cat "$1"
SH

chmod 0755 "$tmp/bin/pgbackrest" "$tmp/bin/supercronic"

common_env=(
  env
  PATH="$tmp/bin:$PATH"
  PGBACKREST_TEST_CALLS="$calls"
  PGBACKREST_CONFIG=/dev/null
  PGBACKREST_STANZA=unit
  PGBACKREST_LOG_PATH="$tmp/log"
  PGBACKREST_SPOOL_PATH="$tmp/spool"
  STATE_DIR="$tmp/state"
)

schedule="$("${common_env[@]}" \
  INIT_ON_STARTUP=no \
  RUN_ON_STARTUP=no \
  BACKUP_FULL_SCHEDULE='1 2 * * 0' \
  BACKUP_DIFF_SCHEDULE='2 2 * * 1-6' \
  BACKUP_INCR_SCHEDULE='3 */6 * * *' \
  BACKUP_CHECK_SCHEDULE='4 2 * * *' \
  bash "$ROOT_DIR/src/pgbackrest-sidecar.sh" daemon)"

grep -Fq '1 2 * * 0 /usr/local/bin/pgbackrest-sidecar.sh backup full' <<<"$schedule" ||
  fail "full schedule was not rendered"
grep -Fq '3 */6 * * * /usr/local/bin/pgbackrest-sidecar.sh backup incr' <<<"$schedule" ||
  fail "incremental schedule was not rendered"

restore_target="$tmp/restore"
mkdir -p "$restore_target"
"${common_env[@]}" \
  RESTORE_TARGET_PATH="$restore_target" \
  RESTORE_CONFIRM="$restore_target" \
  bash "$ROOT_DIR/src/pgbackrest-sidecar.sh" restore

grep -Fq -- "--config=/dev/null --stanza=unit --pg1-path=${restore_target} restore" "$calls" ||
  fail "restore did not use the confirmed isolated target"

printf 'occupied\n' >"$restore_target/existing"
if "${common_env[@]}" \
  RESTORE_TARGET_PATH="$restore_target" \
  RESTORE_CONFIRM="$restore_target" \
  bash "$ROOT_DIR/src/pgbackrest-sidecar.sh" restore 2>/dev/null; then
  fail "non-empty restore target was accepted"
fi

if "${common_env[@]}" \
  PGBACKREST_PG1_PATH="$tmp/source" \
  RESTORE_TARGET_PATH="$tmp/source" \
  RESTORE_CONFIRM="$tmp/source" \
  bash "$ROOT_DIR/src/pgbackrest-sidecar.sh" restore 2>/dev/null; then
  fail "source PostgreSQL path was accepted as a restore target"
fi

printf 'pgBackRest unit tests passed\n'
